import Foundation
import BuildKitCore

/// Drives `docker buildx` from the GUI app.
///
/// Locates the `docker` binary (GUI processes don't inherit the user's
/// shell `$PATH`, so we search a small set of well-known prefixes plus
/// whatever a login shell reports), then invokes `docker buildx ...`
/// with explicit argv to avoid quoting bugs around the host socket path,
/// which contains a space.
actor BuildxIntegration {
    enum InstallResult: Sendable {
        case created(builderName: String)
        case alreadyExists(builderName: String)
        case dockerNotFound
        case failed(stderr: String, exitCode: Int32)
    }

    /// Cached docker binary path; nil means "not yet probed".
    private var cachedDockerPath: String?

    /// Find the `docker` binary or return nil. Searches in priority order:
    ///   1. `$PATH` of the current process (set; usually minimal in a GUI).
    ///   2. Well-known prefixes used by Docker Desktop / Homebrew.
    ///   3. `command -v docker` via a login shell.
    func locateDocker() async -> String? {
        if let cached = cachedDockerPath { return cached }

        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedDockerPath = path
                return path
            }
        }

        // Fall back to asking the user's login shell. We use `$SHELL`
        // rather than hardcoding zsh so that users who switched shells
        // (bash, fish, nu) get their own PATH discovery rules.
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if FileManager.default.isExecutableFile(atPath: loginShell),
           let shellAnswer = await runCapturing(
            executable: loginShell,
            arguments: ["-l", "-c", "command -v docker"]
           ),
           shellAnswer.exitCode == 0
        {
            let trimmed = shellAnswer.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
                cachedDockerPath = trimmed
                return trimmed
            }
        }

        return nil
    }

    /// Register the given endpoint with docker buildx as a remote builder.
    func install(
        endpoint: BuildKitEndpoint,
        builderName: String = BuildxCommands.defaultBuilderName,
        useAsDefault: Bool = true
    ) async -> InstallResult {
        guard let docker = await locateDocker() else { return .dockerNotFound }

        // Detect existing builder of the same name. `docker buildx inspect`
        // exits 0 if it exists, non-zero otherwise.
        let inspect = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerBuildxInspectArguments(builderName: builderName)
        )
        if inspect?.exitCode == 0 {
            // Optionally make it the default; the existing builder is left in place.
            if useAsDefault {
                _ = await runCapturing(executable: docker, arguments: ["buildx", "use", builderName])
            }
            return .alreadyExists(builderName: builderName)
        }

        let create = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerBuildxCreateArguments(
                for: endpoint, builderName: builderName
            )
        )
        guard let create, create.exitCode == 0 else {
            return .failed(
                stderr: create?.stderr ?? "no output",
                exitCode: create?.exitCode ?? -1
            )
        }

        if useAsDefault {
            _ = await runCapturing(executable: docker, arguments: ["buildx", "use", builderName])
        }
        return .created(builderName: builderName)
    }

    // MARK: - Process exec helper

    private struct ExecOutput: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private func runCapturing(executable: String, arguments: [String]) async -> ExecOutput? {
        await withCheckedContinuation { (cont: CheckedContinuation<ExecOutput?, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.terminationHandler = { p in
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: ExecOutput(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: p.terminationStatus
                ))
            }
            do {
                try proc.run()
            } catch {
                cont.resume(returning: nil)
            }
        }
    }
}

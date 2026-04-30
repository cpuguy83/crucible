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
    enum BuilderStatus: Sendable, Equatable {
        case unknown
        case dockerNotFound
        case notRegistered
        case running(version: String?, platforms: String?)
        case inactive
        case failed(String)

        var displayText: String {
            switch self {
            case .unknown:
                return "Unknown"
            case .dockerNotFound:
                return "Docker not found"
            case .notRegistered:
                return "Not registered"
            case .running(let version, let platforms):
                var parts = ["Connected"]
                if let version, !version.isEmpty { parts.append(version) }
                if let platforms, !platforms.isEmpty { parts.append(platforms) }
                return parts.joined(separator: " · ")
            case .inactive:
                return "Registered, unreachable"
            case .failed(let message):
                return "Failed: \(message)"
            }
        }
    }

    enum InstallResult: Sendable {
        case created(builderName: String)
        case alreadyExists(builderName: String)
        case dockerNotFound
        case failed(stderr: String, exitCode: Int32)
        case useFailed(stderr: String, exitCode: Int32)
    }

    enum RemoveResult: Sendable {
        case removed(builderName: String)
        case notRegistered(builderName: String)
        case dockerNotFound
        case failed(stderr: String, exitCode: Int32)
    }

    enum PruneResult: Sendable {
        case pruned(output: String)
        case dockerNotFound
        case failed(stderr: String, exitCode: Int32)
    }

    enum ContextResult: Sendable {
        case created(contextName: String)
        case alreadyExists(contextName: String)
        case removed(contextName: String)
        case notRegistered(contextName: String)
        case dockerNotFound
        case failed(stderr: String, exitCode: Int32)
        case useFailed(stderr: String, exitCode: Int32)
    }

    enum ContextStatus: Sendable, Equatable {
        case unknown
        case dockerNotFound
        case notRegistered
        case available
        case current
        case failed(String)

        var displayText: String {
            switch self {
            case .unknown:
                return "Unknown"
            case .dockerNotFound:
                return "Docker not found"
            case .notRegistered:
                return "Not registered"
            case .available:
                return "Registered"
            case .current:
                return "Current"
            case .failed(let message):
                return "Failed: \(message)"
            }
        }
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
                if let use = await runCapturing(executable: docker, arguments: ["buildx", "use", builderName]),
                   use.exitCode != 0
                {
                    return .useFailed(stderr: use.stdout + use.stderr, exitCode: use.exitCode)
                }
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
            if let use = await runCapturing(executable: docker, arguments: ["buildx", "use", builderName]),
               use.exitCode != 0
            {
                return .useFailed(stderr: use.stdout + use.stderr, exitCode: use.exitCode)
            }
        }
        return .created(builderName: builderName)
    }

    func status(builderName: String = BuildxCommands.defaultBuilderName) async -> BuilderStatus {
        guard let docker = await locateDocker() else { return .dockerNotFound }
        guard let inspect = await runCapturing(
            executable: docker,
            arguments: ["buildx", "inspect", "--bootstrap", builderName]
        ) else { return .failed("failed to run docker buildx inspect") }

        let output = inspect.stdout + inspect.stderr
        if inspect.exitCode != 0 {
            if output.contains("no builder") || output.contains("not found") {
                return .notRegistered
            }
            if output.localizedCaseInsensitiveContains("context deadline") {
                return .inactive
            }
            return .failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let statusLine = Self.value(after: "Status:", in: output)
        let version = Self.value(after: "BuildKit version:", in: output)
        let platforms = Self.value(after: "Platforms:", in: output)
        if statusLine?.localizedCaseInsensitiveContains("running") == true {
            return .running(version: version, platforms: platforms)
        }
        if statusLine?.localizedCaseInsensitiveContains("inactive") == true {
            return .inactive
        }
        return .unknown
    }

    func remove(builderName: String = BuildxCommands.defaultBuilderName) async -> RemoveResult {
        guard let docker = await locateDocker() else { return .dockerNotFound }
        guard let output = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerBuildxRemoveArguments(builderName: builderName)
        ) else { return .failed(stderr: "failed to run docker buildx rm", exitCode: -1) }
        let combined = output.stdout + output.stderr
        if output.exitCode == 0 {
            return .removed(builderName: builderName)
        }
        if combined.contains("no builder") || combined.contains("not found") {
            return .notRegistered(builderName: builderName)
        }
        return .failed(stderr: combined, exitCode: output.exitCode)
    }

    func installDockerContext(
        endpoint: BuildKitEndpoint,
        contextName: String = BuildxCommands.defaultBuilderName,
        useAsDefault: Bool = true
    ) async -> ContextResult {
        guard let docker = await locateDocker() else { return .dockerNotFound }

        let inspect = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerContextInspectArguments(contextName: contextName)
        )
        if inspect?.exitCode == 0 {
            if useAsDefault {
                if let use = await runCapturing(executable: docker, arguments: BuildxCommands.dockerContextUseArguments(contextName: contextName)),
                   use.exitCode != 0
                {
                    return .useFailed(stderr: use.stdout + use.stderr, exitCode: use.exitCode)
                }
            }
            return .alreadyExists(contextName: contextName)
        }

        let create = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerContextCreateArguments(for: endpoint, contextName: contextName)
        )
        guard let create, create.exitCode == 0 else {
            return .failed(stderr: create?.stderr ?? "no output", exitCode: create?.exitCode ?? -1)
        }

        if useAsDefault {
            if let use = await runCapturing(executable: docker, arguments: BuildxCommands.dockerContextUseArguments(contextName: contextName)),
               use.exitCode != 0
            {
                return .useFailed(stderr: use.stdout + use.stderr, exitCode: use.exitCode)
            }
        }
        return .created(contextName: contextName)
    }

    func dockerContextStatus(contextName: String = BuildxCommands.defaultBuilderName) async -> ContextStatus {
        guard let docker = await locateDocker() else { return .dockerNotFound }
        guard let inspect = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerContextInspectArguments(contextName: contextName)
        ) else { return .failed("failed to run docker context inspect") }

        let output = inspect.stdout + inspect.stderr
        if inspect.exitCode != 0 {
            if output.contains("not found") || output.contains("does not exist") || output.contains("No context") {
                return .notRegistered
            }
            return .failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let current = await runCapturing(executable: docker, arguments: ["context", "show"]),
              current.exitCode == 0 else { return .available }
        return current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == contextName ? .current : .available
    }

    func removeDockerContext(contextName: String = BuildxCommands.defaultBuilderName) async -> ContextResult {
        guard let docker = await locateDocker() else { return .dockerNotFound }
        if let current = await runCapturing(executable: docker, arguments: ["context", "show"]),
           current.exitCode == 0,
           current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == contextName
        {
            guard let useDefault = await runCapturing(executable: docker, arguments: BuildxCommands.dockerContextUseArguments(contextName: "default")) else {
                return .useFailed(stderr: "failed to run docker context use default", exitCode: -1)
            }
            if useDefault.exitCode != 0 {
                return .useFailed(stderr: useDefault.stdout + useDefault.stderr, exitCode: useDefault.exitCode)
            }
        }
        guard let output = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerContextRemoveArguments(contextName: contextName)
        ) else { return .failed(stderr: "failed to run docker context rm", exitCode: -1) }
        let combined = output.stdout + output.stderr
        if output.exitCode == 0 {
            return .removed(contextName: contextName)
        }
        if combined.contains("not found") || combined.contains("does not exist") || combined.contains("No context") {
            return .notRegistered(contextName: contextName)
        }
        return .failed(stderr: combined, exitCode: output.exitCode)
    }

    func installDockerBackedBuildx(
        endpoint: BuildKitEndpoint,
        builderName: String = BuildxCommands.defaultBuilderName,
        useAsDefault: Bool = true
    ) async -> InstallResult {
        guard let docker = await locateDocker() else { return .dockerNotFound }
        let inspect = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerBuildxInspectArguments(builderName: builderName)
        )
        if inspect?.exitCode == 0 {
            if useAsDefault {
                if let use = await runCapturing(executable: docker, arguments: ["buildx", "use", builderName]),
                   use.exitCode != 0
                {
                    return .useFailed(stderr: use.stdout + use.stderr, exitCode: use.exitCode)
                }
            }
            return .alreadyExists(builderName: builderName)
        }

        let create = await runCapturing(
            executable: docker,
            arguments: BuildxCommands.dockerBuildxCreateArguments(for: endpoint, builderName: builderName)
        )
        guard let create, create.exitCode == 0 else {
            return .failed(stderr: create?.stderr ?? "no output", exitCode: create?.exitCode ?? -1)
        }

        if useAsDefault {
            if let use = await runCapturing(executable: docker, arguments: ["buildx", "use", builderName]),
               use.exitCode != 0
            {
                return .useFailed(stderr: use.stdout + use.stderr, exitCode: use.exitCode)
            }
        }
        return .created(builderName: builderName)
    }

    func recreate(
        endpoint: BuildKitEndpoint,
        builderName: String = BuildxCommands.defaultBuilderName
    ) async -> InstallResult {
        _ = await remove(builderName: builderName)
        return await install(endpoint: endpoint, builderName: builderName, useAsDefault: true)
    }

    func prune(builderName: String = BuildxCommands.defaultBuilderName) async -> PruneResult {
        guard let docker = await locateDocker() else { return .dockerNotFound }
        guard let output = await runCapturing(
            executable: docker,
            arguments: ["buildx", "prune", "--builder", builderName, "--force"]
        ) else { return .failed(stderr: "failed to run docker buildx prune", exitCode: -1) }
        let combined = output.stdout + output.stderr
        if output.exitCode == 0 {
            return .pruned(output: combined)
        }
        return .failed(stderr: combined, exitCode: output.exitCode)
    }

    // MARK: - Process exec helper

    private struct ExecOutput: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    private static func value(after prefix: String, in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            return trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
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

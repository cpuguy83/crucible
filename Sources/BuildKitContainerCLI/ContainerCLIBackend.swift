import Foundation
import BuildKitCore

/// Opt-in backend that drives buildkitd by shelling out to the
/// `container` CLI from apple/container.
public actor ContainerCLIBackend: BuildKitBackend {
    static let containerID = "crucible-buildkitd"
    static let daemonConfigGuestPath = "/etc/buildkit/buildkitd.toml"

    private let settings: BuildKitSettings
    private let containerBinaryPath: String
    private let appRoot: URL
    private var state: BuildKitState = .stopped
    private var logsTask: Task<Void, Never>?

    private let stateContinuation: AsyncStream<BuildKitState>.Continuation
    public nonisolated let stateStream: AsyncStream<BuildKitState>

    private let progressContinuation: AsyncStream<BuildKitProgress>.Continuation
    public nonisolated let progressStream: AsyncStream<BuildKitProgress>

    private let logContinuation: AsyncStream<String>.Continuation
    public nonisolated let logStream: AsyncStream<String>

    public init(
        settings: BuildKitSettings,
        containerBinaryPath: String = ContainerCLICommands.defaultBinaryPath(),
        appRoot: URL = ContainerCLIBackend.defaultAppRoot()
    ) {
        self.settings = settings
        self.containerBinaryPath = containerBinaryPath
        self.appRoot = appRoot
        (stateStream, stateContinuation) = AsyncStream<BuildKitState>.makeStream()
        (progressStream, progressContinuation) = AsyncStream<BuildKitProgress>.makeStream()
        (logStream, logContinuation) = AsyncStream<String>.makeStream()
    }

    public func currentState() -> BuildKitState { state }

    public func start() async throws {
        switch state {
        case .running, .starting:
            return
        default:
            break
        }
        transition(to: .starting)

        do {
            try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
            let hostSocketURL = URL(fileURLWithPath: settings.hostSocketPath)
            try FileManager.default.createDirectory(at: hostSocketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: hostSocketURL)

            progressContinuation.yield(.init(phase: .pullingImage, message: "Ensuring container system service is running"))
            _ = try await runProcess(ContainerCLICommands.systemStart(binary: containerBinaryPath))

            progressContinuation.yield(.init(phase: .pullingImage, message: "Removing stale CLI container"))
            _ = try? await runContainerCLI(["rm", Self.containerID])

            progressContinuation.yield(.init(phase: .pullingImage, message: "Starting container CLI backend"))
            let configDirectory = try writeDaemonConfigIfNeeded()
            try FileManager.default.createDirectory(at: cliStateDirectory, withIntermediateDirectories: true)
            let command = ContainerCLICommands.runDetachedBuildKit(
                binary: containerBinaryPath,
                containerID: Self.containerID,
                settings: settings,
                statePath: cliStateDirectory.path,
                configDirectoryPath: configDirectory?.path
            )
            _ = try await runProcess(command)

            logsTask?.cancel()
            logsTask = Task { [containerBinaryPath, logContinuation] in
                let stream = ContainerCLICommands.logsFollow(binary: containerBinaryPath, containerID: Self.containerID)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: stream.executable)
                process.arguments = stream.arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    for try await line in pipe.fileHandleForReading.bytes.lines {
                        logContinuation.yield("[container] \(line)")
                    }
                } catch {
                    logContinuation.yield("[container!] logs failed: \(error)")
                }
                if process.isRunning { process.terminate() }
            }

            progressContinuation.yield(.init(phase: .healthCheck, message: "Waiting for buildkitd"))
            try await runHealthCheck(hostSocketPath: settings.hostSocketPath)

            transition(to: .running(endpoint: BuildKitEndpoint(socketPath: settings.hostSocketPath)))
        } catch {
            transition(to: .error(String(describing: error)))
            throw error as? BuildKitBackendError ?? BuildKitBackendError.daemonStartFailed(String(describing: error))
        }
    }

    public func stop() async throws {
        switch state {
        case .stopped, .stopping:
            return
        case .starting:
            throw BuildKitBackendError.invalidState(current: String(describing: state), attempted: "stop")
        default:
            break
        }
        transition(to: .stopping)
        logsTask?.cancel()
        logsTask = nil
        _ = try? await runContainerCLI(["stop", Self.containerID])
        _ = try? await runContainerCLI(["rm", Self.containerID])
        transition(to: .stopped)
    }

    public func restart() async throws {
        try await stop()
        try await start()
    }

    public func pullImage() async throws {
        progressContinuation.yield(.init(phase: .pullingImage, message: "Pulling \(settings.imageReference)"))
        do {
            _ = try await runProcess(ContainerCLICommands.pullImage(binary: containerBinaryPath, image: settings.imageReference))
        } catch {
            throw BuildKitBackendError.imagePullFailed(String(describing: error))
        }
    }

    public func resetState() async throws {
        switch state {
        case .stopped, .error:
            let stateDir = appRoot.appendingPathComponent("cli-state", isDirectory: true)
            try? FileManager.default.removeItem(at: stateDir)
        default:
            throw BuildKitBackendError.invalidState(current: String(describing: state), attempted: "resetState")
        }
    }

    public static func defaultAppRoot() -> URL {
        BuilderStoragePaths.defaultAppSupportRoot()
    }

    private func runContainerCLI(_ arguments: [String]) async throws -> String {
        try await runProcess(.init(executable: containerBinaryPath, arguments: arguments))
    }

    private var cliStateDirectory: URL {
        appRoot.appendingPathComponent("cli-state", isDirectory: true)
    }

    private func runProcess(_ command: ContainerCLICommands.Command) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw BuildKitBackendError.configurationInvalid("container CLI not found or not executable at \(command.executable)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: BuildKitBackendError.daemonStartFailed(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func writeDaemonConfigIfNeeded() throws -> URL? {
        let config = settings.effectiveDaemonConfigTOML().trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = appRoot.appendingPathComponent("buildkitd-config", isDirectory: true)
        let url = dir.appendingPathComponent("buildkitd.toml")
        if config.isEmpty {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try config.write(to: url, atomically: true, encoding: .utf8)
        return dir
    }

    private func runHealthCheck(hostSocketPath: String, timeoutSeconds: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError = "no attempt completed"
        while Date() < deadline {
            if let err = Self.tryConnectUnixSocket(path: hostSocketPath) {
                lastError = err
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            return
        }
        throw BuildKitBackendError.healthCheckFailed("buildkitd did not become reachable on \(hostSocketPath): \(lastError)")
    }

    private static func tryConnectUnixSocket(path: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return "socket(): errno=\(errno)" }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { return "socket path too long" }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: CChar.self, repeating: 0)
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
        }

        let len = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        return rc == 0 ? nil : "connect(): errno=\(errno)"
    }

    private func transition(to newState: BuildKitState) {
        state = newState
        stateContinuation.yield(newState)
    }
}

public enum ContainerCLICommands {
    public struct Command: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
    }

    public static func defaultBinaryPath() -> String {
        for path in ["/opt/homebrew/bin/container", "/usr/local/bin/container", "/usr/bin/container"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/local/bin/container"
    }

    public static func runDetachedBuildKit(
        binary: String,
        containerID: String,
        settings: BuildKitSettings,
        statePath: String,
        configDirectoryPath: String?
    ) -> Command {
        var args = [
            "run",
            "--detach",
            "--name", containerID,
            "--init",
            "--cpus", "\(settings.cpuCount)",
            "--memory", "\(settings.memoryMiB)M",
            "--publish-socket", "\(settings.hostSocketPath):/run/buildkit/buildkitd.sock",
            "--mount", "type=bind,source=\(statePath),target=/var/lib/buildkit",
        ]

        if let kernelOverridePath = settings.kernelOverridePath, !kernelOverridePath.isEmpty {
            args.append(contentsOf: ["--kernel", kernelOverridePath])
        }
        args.append("--rosetta")
        if let configDirectoryPath {
            args.append(contentsOf: [
                "--mount", "type=bind,source=\(configDirectoryPath),target=/etc/buildkit,readonly",
            ])
        }

        args.append(settings.imageReference)
        args.append(contentsOf: ["/usr/bin/buildkitd", "--addr", "unix:///run/buildkit/buildkitd.sock"])
        if configDirectoryPath != nil {
            args.append(contentsOf: ["--config", ContainerCLIBackend.daemonConfigGuestPath])
        }
        return .init(executable: binary, arguments: args)
    }

    public static func pullImage(binary: String, image: String) -> Command {
        .init(executable: binary, arguments: ["image", "pull", image])
    }

    public static func logsFollow(binary: String, containerID: String) -> Command {
        .init(executable: binary, arguments: ["logs", "--follow", containerID])
    }

    public static func systemStart(binary: String) -> Command {
        .init(executable: binary, arguments: ["system", "start", "--disable-kernel-install", "--timeout", "30"])
    }
}

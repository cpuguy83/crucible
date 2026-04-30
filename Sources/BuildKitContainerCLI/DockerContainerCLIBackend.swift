import Foundation
import BuildKitCore

public actor DockerContainerCLIBackend {
    static let containerID = "crucible-docker"

    private let settings: DockerSettings
    private let containerBinaryPath: String
    private let paths: BuilderStoragePaths
    private var state: DockerDaemonState = .stopped
    private var logsTask: Task<Void, Never>?

    private let stateContinuation: AsyncStream<DockerDaemonState>.Continuation
    public nonisolated let stateStream: AsyncStream<DockerDaemonState>

    private let progressContinuation: AsyncStream<BuildKitProgress>.Continuation
    public nonisolated let progressStream: AsyncStream<BuildKitProgress>

    private let logContinuation: AsyncStream<String>.Continuation
    public nonisolated let logStream: AsyncStream<String>

    public init(
        settings: DockerSettings,
        containerBinaryPath: String = ContainerCLICommands.defaultBinaryPath(),
        paths: BuilderStoragePaths
    ) {
        self.settings = settings
        self.containerBinaryPath = containerBinaryPath
        self.paths = paths
        (stateStream, stateContinuation) = AsyncStream<DockerDaemonState>.makeStream()
        (progressStream, progressContinuation) = AsyncStream<BuildKitProgress>.makeStream()
        (logStream, logContinuation) = AsyncStream<String>.makeStream()
    }

    public func currentState() -> DockerDaemonState { state }

    public func commandForStart() -> ContainerCLICommands.Command {
        ContainerCLICommands.runDetachedDocker(
            binary: containerBinaryPath,
            containerID: Self.containerID,
            settings: settings,
            socketPath: paths.dockerSocketURL.path,
            dataRootPath: paths.dockerDataRootURL.path
        )
    }

    public func start() async throws {
        switch state {
        case .running, .starting:
            return
        default:
            break
        }
        transition(to: .starting)

        do {
            let validationIssues = BuilderConfigValidator.validate(settings)
            guard validationIssues.isEmpty else {
                throw BuildKitBackendError.configurationInvalid(String(describing: validationIssues))
            }

            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.dockerSocketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.dockerDataRootURL, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: paths.dockerSocketURL)

            progressContinuation.yield(.init(phase: .pullingImage, message: "Ensuring container system service is running"))
            _ = try await runProcess(ContainerCLICommands.systemStart(binary: containerBinaryPath))

            progressContinuation.yield(.init(phase: .pullingImage, message: "Removing stale Docker container"))
            _ = try? await runContainerCLI(["rm", Self.containerID])

            progressContinuation.yield(.init(phase: .startingDaemon, message: "Starting Docker daemon"))
            _ = try await runProcess(commandForStart())

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
                        logContinuation.yield("[docker] \(line)")
                    }
                } catch {
                    logContinuation.yield("[docker!] logs failed: \(error)")
                }
                if process.isRunning { process.terminate() }
            }

            progressContinuation.yield(.init(phase: .healthCheck, message: "Waiting for Docker daemon"))
            try await runHealthCheck(socketPath: paths.dockerSocketURL.path)

            transition(to: .running(endpoint: DockerDaemonEndpoint(socketPath: paths.dockerSocketURL.path)))
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
            try? FileManager.default.removeItem(at: paths.dockerDataRootURL)
            try? FileManager.default.removeItem(at: paths.dockerSocketURL)
        default:
            throw BuildKitBackendError.invalidState(current: String(describing: state), attempted: "resetState")
        }
    }

    private func runContainerCLI(_ arguments: [String]) async throws -> String {
        try await runProcess(.init(executable: containerBinaryPath, arguments: arguments))
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

    private func runHealthCheck(socketPath: String, timeoutSeconds: Double = 60) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError = "no attempt completed"
        while Date() < deadline {
            if let err = Self.tryConnectUnixSocket(path: socketPath) {
                lastError = err
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            return
        }
        throw BuildKitBackendError.healthCheckFailed("Docker daemon did not become reachable on \(socketPath): \(lastError)")
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

    private func transition(to newState: DockerDaemonState) {
        state = newState
        stateContinuation.yield(newState)
    }
}

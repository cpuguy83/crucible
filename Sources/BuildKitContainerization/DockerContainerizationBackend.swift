import Foundation
import BuildKitCore
@preconcurrency import Containerization
import ContainerizationOCI
import ContainerizationEXT4
import ContainerizationExtras
import SystemPackage

public actor DockerContainerizationBackend {
    static let containerID = "crucible-docker"
    static let stateImageVersion = "1-journaled-ext4-8g-uncached-fullsync"
    static let daemonConfigGuestPath = "/etc/docker/daemon.json"

    private let settings: DockerSettings
    private let paths: BuilderStoragePaths

    private var state: DockerDaemonState = .stopped
    private var manager: ContainerManager?
    private var container: LinuxContainer?
    private var lifecycleLockFD: Int32 = -1
    private var waitTask: Task<Void, Never>?

    private let stateContinuation: AsyncStream<DockerDaemonState>.Continuation
    public nonisolated let stateStream: AsyncStream<DockerDaemonState>

    private let progressContinuation: AsyncStream<BuildKitProgress>.Continuation
    public nonisolated let progressStream: AsyncStream<BuildKitProgress>

    private let logContinuation: AsyncStream<String>.Continuation
    public nonisolated let logStream: AsyncStream<String>

    public init(settings: DockerSettings, paths: BuilderStoragePaths) {
        self.settings = settings
        self.paths = paths
        (stateStream, stateContinuation) = AsyncStream<DockerDaemonState>.makeStream()
        (progressStream, progressContinuation) = AsyncStream<BuildKitProgress>.makeStream()
        (logStream, logContinuation) = AsyncStream<String>.makeStream()
    }

    public func currentState() -> DockerDaemonState { state }

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

            try await ensureAppRoot()
            try acquireLifecycleLock()
            try removeStaleContainerDirIfPresent()

            progressContinuation.yield(.init(phase: .downloadingKernel, message: "Locating kernel"))
            let progressSink = self.progressContinuation
            let kernelURL = try await KernelLocator.locateOrDownload(settings: settings.kernelSettings) { p in
                let msg: String
                switch p.phase {
                case .downloading:
                    if let total = p.bytesExpected, total > 0 {
                        let mb = Double(p.bytesReceived) / 1_048_576.0
                        let totalMB = Double(total) / 1_048_576.0
                        msg = String(format: "Downloading kernel: %.1f / %.1f MiB", mb, totalMB)
                    } else {
                        let mb = Double(p.bytesReceived) / 1_048_576.0
                        msg = String(format: "Downloading kernel: %.1f MiB", mb)
                    }
                case .extracting:
                    msg = "Extracting kernel"
                case .done:
                    msg = "Kernel ready"
                }
                let fraction: Double? = {
                    guard p.phase == .downloading,
                          let total = p.bytesExpected, total > 0 else { return nil }
                    return min(1.0, Double(p.bytesReceived) / Double(total))
                }()
                progressSink.yield(.init(phase: .downloadingKernel, message: msg, fraction: fraction))
            }

            try FileManager.default.createDirectory(
                at: paths.dockerSocketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: paths.dockerSocketURL)

            let kernel = Kernel(path: kernelURL, platform: .linuxArm)

            progressContinuation.yield(.init(phase: .pullingImage, message: "Preparing image store"))
            let contentStore = try LocalContentStore(path: paths.appSupportRoot.appendingPathComponent("content"))
            let imageStore = try ImageStore(path: paths.appSupportRoot, contentStore: contentStore)

            progressContinuation.yield(.init(phase: .pullingImage, message: "Pulling init filesystem"))
            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: settings.initfsReference,
                imageStore: imageStore,
                network: try VmnetNetwork(),
                rosetta: true
            )

            progressContinuation.yield(.init(phase: .preparingRootfs, message: "Preparing Docker rootfs"))
            let stdoutWriter = LineWriter(prefix: "[dockerd]", continuation: logContinuation)
            let stderrWriter = LineWriter(prefix: "[dockerd!]", continuation: logContinuation)

            let socket = UnixSocketConfiguration(
                source: URL(fileURLWithPath: "/var/run/docker.sock"),
                destination: paths.dockerSocketURL,
                permissions: FilePermissions(rawValue: 0o600),
                direction: .outOf
            )

            let dataImageURL = paths.dockerDataImageURL
            try ContainerizationBackend.ensureExt4StateImage(
                at: dataImageURL,
                versionURL: paths.dockerDataImageVersionURL,
                version: Self.stateImageVersion,
                sizeInBytes: 8.gib()
            )
            let dataMount = Mount.block(
                format: "ext4",
                source: dataImageURL.path,
                destination: "/var/lib/docker",
                runtimeOptions: [
                    "vzDiskImageCachingMode=uncached",
                    "vzDiskImageSynchronizationMode=full",
                ]
            )
            var extraMounts: [Containerization.Mount] = []
            if let daemonConfigURL = try writeDaemonConfigIfNeeded() {
                extraMounts.append(Containerization.Mount.share(
                    source: daemonConfigURL.path,
                    destination: Self.daemonConfigGuestPath,
                    options: ["ro"]
                ))
            }

            let cpuCount = settings.cpuCount
            let memoryBytes = UInt64(settings.memoryMiB).mib()

            let container = try await manager.create(
                Self.containerID,
                reference: settings.imageReference,
                rootfsSizeInBytes: 8.gib(),
                writableLayerSizeInBytes: 32.gib(),
                networking: true
            ) { config in
                config.cpus = cpuCount
                config.memoryInBytes = memoryBytes
                config.useInit = true
                config.sockets = [socket]
                config.mounts.append(dataMount)
                config.mounts.append(contentsOf: extraMounts)
                config.process.stdout = stdoutWriter
                config.process.stderr = stderrWriter
            }

            self.manager = manager
            self.container = container

            progressContinuation.yield(.init(phase: .bootingVM, message: "Booting VM"))
            try await container.create()

            progressContinuation.yield(.init(phase: .startingDaemon, message: "Starting Docker daemon"))
            try await container.start()

            progressContinuation.yield(.init(phase: .healthCheck, message: "Waiting for Docker daemon"))
            try await ContainerizationBackend.runHealthCheck(
                hostSocketPath: paths.dockerSocketURL.path,
                serviceName: "Docker daemon"
            )

            waitTask = Task { [weak self] in
                let exit = try? await container.wait()
                await self?.handleProcessExit(status: exit)
            }

            transition(to: .running(endpoint: DockerDaemonEndpoint(socketPath: paths.dockerSocketURL.path)))
        } catch {
            await teardown()
            let msg = String(describing: error)
            transition(to: .error(msg))
            if let e = error as? BuildKitBackendError {
                throw e
            }
            throw BuildKitBackendError.daemonStartFailed(msg)
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
        progressContinuation.yield(.init(phase: .shuttingDown, message: "Stopping Docker daemon"))
        await teardown()
        transition(to: .stopped)
    }

    public func restart() async throws {
        try await stop()
        try await start()
    }

    public func pullImage() async throws {
        try await ensureAppRoot()
        let contentStore = try LocalContentStore(path: paths.appSupportRoot.appendingPathComponent("content"))
        let imageStore = try ImageStore(path: paths.appSupportRoot, contentStore: contentStore)
        progressContinuation.yield(.init(phase: .pullingImage, message: "Pulling \(settings.imageReference)"))
        do {
            _ = try await imageStore.pull(reference: settings.imageReference)
        } catch {
            throw BuildKitBackendError.imagePullFailed(String(describing: error))
        }
    }

    public func resetState() async throws {
        switch state {
        case .stopped, .error:
            try? FileManager.default.removeItem(at: paths.dockerDataImageURL)
            try? FileManager.default.removeItem(at: paths.dockerDataImageVersionURL)
            try? FileManager.default.removeItem(at: paths.dockerSocketURL)
        default:
            throw BuildKitBackendError.invalidState(current: String(describing: state), attempted: "resetState")
        }
    }

    private func ensureAppRoot() async throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.appSupportRoot, withIntermediateDirectories: true)
    }

    private func acquireLifecycleLock() throws {
        if lifecycleLockFD >= 0 { return }
        let lockURL = paths.root.appendingPathComponent("crucible.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw BuildKitBackendError.daemonStartFailed("failed to open lifecycle lock: errno=\(errno)")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw BuildKitBackendError.alreadyRunning(
                "another Crucible process is already running this builder; stop it before starting a second instance"
            )
        }
        lifecycleLockFD = fd
    }

    private func writeDaemonConfigIfNeeded() throws -> URL? {
        let config = settings.daemonConfigJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = paths.dockerDaemonConfigURL
        if config.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try config.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func releaseLifecycleLock() {
        guard lifecycleLockFD >= 0 else { return }
        flock(lifecycleLockFD, LOCK_UN)
        close(lifecycleLockFD)
        lifecycleLockFD = -1
    }

    private func removeStaleContainerDirIfPresent() throws {
        let dir = paths.appSupportRoot
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(Self.containerID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    private func handleProcessExit(status: ExitStatus?) {
        if case .stopping = state { return }
        if case .stopped = state { return }
        let reason = status.map { "Docker daemon exited (status=\($0))" } ?? "Docker daemon exited unexpectedly"
        transition(to: .error(reason))
    }

    private func teardown() async {
        waitTask?.cancel()
        waitTask = nil
        if let container {
            try? await container.stop()
        }
        if var manager {
            try? manager.delete(Self.containerID)
            self.manager = manager
        }
        container = nil
        manager = nil
        releaseLifecycleLock()
        try? FileManager.default.removeItem(at: paths.dockerSocketURL)
    }

    private func transition(to newState: DockerDaemonState) {
        state = newState
        stateContinuation.yield(newState)
    }
}

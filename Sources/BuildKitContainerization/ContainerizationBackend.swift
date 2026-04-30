import Foundation
import BuildKitCore
@preconcurrency import Containerization
import ContainerizationOCI
import ContainerizationEXT4
import ContainerizationExtras
import SystemPackage

/// Default backend that drives buildkitd via apple/containerization directly.
///
/// Lifecycle:
///   1. Resolve a Linux kernel via ``KernelLocator``.
///   2. Construct an `ImageStore` rooted at our app-support directory.
///   3. Build a `ContainerManager` with the user's chosen initfs reference.
///   4. `manager.create(...)` pulls the buildkitd image (if needed) and
///      unpacks it into an ext4 rootfs block, cached by container id.
///   5. `container.create()` boots the VM and wires the host<->guest unix
///      socket relay so buildkitd's `/run/buildkit/buildkitd.sock` shows up
///      at the host path from settings.
///   6. `container.start()` launches buildkitd as the container's init
///      process; stdout/stderr are forwarded into ``logStream``.
///
/// All state mutation is serialized by virtue of being an `actor`.
public actor ContainerizationBackend: BuildKitBackend {
    /// Stable container id; we run a single long-lived buildkitd container.
    static let containerID = "crucible-buildkitd"
    static let stateImageVersion = "2-journaled-ext4-8g-uncached-fullsync"
    static let daemonConfigGuestPath = "/etc/buildkit/buildkitd.toml"

    private let settings: BuildKitSettings
    private let appRoot: URL

    private var state: BuildKitState = .stopped
    private var manager: ContainerManager?
    private var container: LinuxContainer?
    private var lifecycleLockFD: Int32 = -1

    /// Background task running `container.wait()`. We keep a handle so
    /// `stop()` can cancel cleanly.
    private var waitTask: Task<Void, Never>?

    private let stateContinuation: AsyncStream<BuildKitState>.Continuation
    public nonisolated let stateStream: AsyncStream<BuildKitState>

    private let progressContinuation: AsyncStream<BuildKitProgress>.Continuation
    public nonisolated let progressStream: AsyncStream<BuildKitProgress>

    private let logContinuation: AsyncStream<String>.Continuation
    public nonisolated let logStream: AsyncStream<String>

    public init(settings: BuildKitSettings) {
        self.settings = settings
        self.appRoot = BuilderStoragePaths().root
        (stateStream, stateContinuation) = AsyncStream<BuildKitState>.makeStream()
        (progressStream, progressContinuation) = AsyncStream<BuildKitProgress>.makeStream()
        (logStream, logContinuation) = AsyncStream<String>.makeStream()
    }

    /// `~/Library/Application Support/Crucible/` — image store, content
    /// store, container rootfs files all live under here.
    static func defaultAppRoot() -> URL {
        BuilderStoragePaths.defaultAppSupportRoot()
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
            try await ensureAppRoot()
            try acquireLifecycleLock()

            // Defensive: if a previous run was killed without graceful
            // teardown, the per-container directory may still exist and
            // ContainerManager.create() will fail trying to mkdir it.
            // The contents (rootfs.ext4, writable.ext4, bootlog.log) are
            // not worth preserving across crashes — image content store
            // and kernel cache live elsewhere — so blow it away.
            try removeStaleContainerDirIfPresent()

            // Locate kernel: override -> local cache -> apple/container CLI
            // install -> Kata download. Last path requires network on first
            // run; cached thereafter.
            progressContinuation.yield(.init(phase: .downloadingKernel, message: "Locating kernel"))
            let progressSink = self.progressContinuation
            let kernelURL = try await KernelLocator.locateOrDownload(settings: settings) { p in
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
                let frac: Double? = {
                    guard p.phase == .downloading,
                          let total = p.bytesExpected, total > 0 else { return nil }
                    return min(1.0, Double(p.bytesReceived) / Double(total))
                }()
                progressSink.yield(.init(phase: .downloadingKernel, message: msg, fraction: frac))
            }

            // Ensure the host socket parent directory exists, and that no
            // stale socket file from a prior crash blocks the relay.
            let hostSocketURL = URL(fileURLWithPath: settings.hostSocketPath)
            try FileManager.default.createDirectory(
                at: hostSocketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: hostSocketURL)

            let kernel = Kernel(path: kernelURL, platform: .linuxArm)

            // Local OCI content + image stores rooted under app support.
            progressContinuation.yield(.init(phase: .pullingImage, message: "Preparing image store"))
            let contentStore = try LocalContentStore(path: appRoot.appendingPathComponent("content"))
            let imageStore = try ImageStore(path: appRoot, contentStore: contentStore)

            // Build the container manager. This pulls the initfs image if
            // not already cached. We pass a VmnetNetwork so the framework
            // can give buildkitd's container an outbound interface (needed
            // for image pulls during builds). Matches what the upstream
            // cctl example does.
            progressContinuation.yield(.init(phase: .pullingImage, message: "Pulling init filesystem"))
            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: settings.initfsReference,
                imageStore: imageStore,
                network: try VmnetNetwork(),
                rosetta: true
            )

            // Pull / unpack the buildkitd image into a per-container ext4
            // rootfs. Cached by container id; reused across restarts.
            progressContinuation.yield(.init(phase: .preparingRootfs, message: "Preparing buildkitd rootfs"))
            let stdoutWriter = LineWriter(prefix: "[buildkitd]", continuation: logContinuation)
            let stderrWriter = LineWriter(prefix: "[buildkitd!]", continuation: logContinuation)

            let socket = UnixSocketConfiguration(
                source: URL(fileURLWithPath: "/run/buildkit/buildkitd.sock"),
                destination: hostSocketURL,
                permissions: FilePermissions(rawValue: 0o600),
                direction: .outOf
            )

            // Persist buildkitd's state (cache, content, metadata) on the
            // host so it survives container restarts. We use a virtio-block
            // ext4 image (single sparse file on the host) rather than a
            // virtiofs share because buildkitd's overlayfs snapshotter
            // writes whiteout character devices that virtiofs rejects with
            // EPERM ("failed to convert whiteout file ... operation not
            // permitted"). A real Linux ext4 filesystem handles whiteouts
            // natively.
            let stateImageURL = BuilderStoragePaths(appSupportRoot: appRoot).buildKitStateImageURL
            try ensureBuildKitStateImage(at: stateImageURL, sizeInBytes: 8.gib())
            // Force VZ to durably persist guest writes:
            //   - vzDiskImageCachingMode=uncached: avoids host page-cache
            //     incoherency for a guest filesystem doing its own caching.
            //   - vzDiskImageSynchronizationMode=full: full barrier semantics
            //     so the guest's fsync()s actually hit stable storage.
            // Without these, killing Crucible (or even a guest crash) can
            // leave the state image in a half-written state that buildkitd
            // then reads as corrupt bbolt ("structure needs cleaning").
            let stateMount = Mount.block(
                format: "ext4",
                source: stateImageURL.path,
                destination: "/var/lib/buildkit",
                runtimeOptions: [
                    "vzDiskImageCachingMode=uncached",
                    "vzDiskImageSynchronizationMode=full",
                ]
            )

            var extraMounts: [Containerization.Mount] = []
            var buildkitArgs = [
                "/usr/bin/buildkitd",
                "--addr", "unix:///run/buildkit/buildkitd.sock",
            ]
            if let daemonConfigURL = try writeDaemonConfigIfNeeded() {
                extraMounts.append(Containerization.Mount.share(
                    source: daemonConfigURL.path,
                    destination: Self.daemonConfigGuestPath,
                    options: ["ro"]
                ))
                buildkitArgs.append(contentsOf: ["--config", Self.daemonConfigGuestPath])
            }

            let cpuCount = self.settings.cpuCount
            let memoryBytes = UInt64(self.settings.memoryMiB).mib()

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
                config.mounts.append(stateMount)
                config.mounts.append(contentsOf: extraMounts)
                config.process.arguments = buildkitArgs
                config.process.stdout = stdoutWriter
                config.process.stderr = stderrWriter
            }

            // Stash before create() so teardown can clean up if the VM
            // boot or buildkitd launch fails.
            self.manager = manager
            self.container = container

            // Boot the VM, wire mounts/relays.
            progressContinuation.yield(.init(phase: .bootingVM, message: "Booting VM"))
            try await container.create()

            // Launch buildkitd.
            progressContinuation.yield(.init(phase: .startingDaemon, message: "Starting buildkitd"))
            try await container.start()

            // Wait for buildkitd's gRPC endpoint to come up.
            progressContinuation.yield(.init(phase: .healthCheck, message: "Waiting for buildkitd"))
            try await Self.runHealthCheck(hostSocketPath: settings.hostSocketPath)

            // Background wait; if buildkitd exits unexpectedly we transition
            // to `.degraded`. (Health-check based recovery is a later concern.)
            self.waitTask = Task { [weak self] in
                let exit = try? await container.wait()
                await self?.handleProcessExit(status: exit)
            }

            let endpoint = BuildKitEndpoint(socketPath: settings.hostSocketPath)
            transition(to: .running(endpoint: endpoint))
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
            throw BuildKitBackendError.invalidState(
                current: String(describing: state),
                attempted: "stop"
            )
        default:
            break
        }
        transition(to: .stopping)
        progressContinuation.yield(.init(phase: .shuttingDown, message: "Stopping buildkitd"))
        await teardown()
        transition(to: .stopped)
    }

    public func restart() async throws {
        try await stop()
        try await start()
    }

    public func pullImage() async throws {
        // Force a pull through the image store, bypassing the running
        // container. Safe to call regardless of running state since the
        // pull is an out-of-band operation; the next start() will pick up
        // the refreshed image when it rebuilds the rootfs (subject to
        // ext4 cache invalidation in a later iteration).
        try await ensureAppRoot()
        let contentStore = try LocalContentStore(path: appRoot.appendingPathComponent("content"))
        let imageStore = try ImageStore(path: appRoot, contentStore: contentStore)
        progressContinuation.yield(.init(phase: .pullingImage, message: "Pulling \(settings.imageReference)"))
        do {
            _ = try await imageStore.pull(reference: settings.imageReference)
        } catch {
            throw BuildKitBackendError.imagePullFailed(String(describing: error))
        }
    }

    /// Wipe the persistent buildkitd state image. Useful when the bbolt
    /// metadata gets corrupted (e.g. after a host crash that lost dirty
    /// writes). The daemon must be stopped first; the caller is
    /// responsible for that ordering.
    public func resetState() async throws {
        guard case .stopped = state else {
            throw BuildKitBackendError.invalidState(
                current: String(describing: state),
                attempted: "resetState"
            )
        }
        let url = BuilderStoragePaths(appSupportRoot: appRoot).buildKitStateImageURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Internals

    /// Wait for buildkitd to start serving on the host-side unix socket.
    /// We probe by attempting to `connect()` to the host UDS that the
    /// framework's vsock relay sets up; the relay only accepts when the
    /// guest side is listening on the corresponding vsock port, which in
    /// turn only happens once buildkitd has bound `/run/buildkit/buildkitd.sock`.
    ///
    /// This avoids `container.exec(...)` entirely, which adds a dependency
    /// on vminitd's exec subsystem being ready and a working `buildctl` in
    /// the image at the path we guess.
    public static func runHealthCheck(
        hostSocketPath: String,
        timeoutSeconds: Double = 60,
        serviceName: String = "buildkitd"
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: String = "no attempt completed"
        while Date() < deadline {
            if let err = await Self.tryConnect(socketPath: hostSocketPath) {
                lastError = err
            } else {
                return  // success
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw BuildKitBackendError.healthCheckFailed(
            "\(serviceName) did not become reachable on \(hostSocketPath) within \(Int(timeoutSeconds))s: \(lastError)"
        )
    }

    /// Returns nil on success, or an error string on failure.
    private static func tryConnect(socketPath: String) async -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return "socket() failed: errno=\(errno)"
        }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        if pathBytes.count > maxLen {
            return "socket path too long (\(pathBytes.count) > \(maxLen))"
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: maxLen) { cp in
                for (i, b) in pathBytes.enumerated() {
                    cp[i] = CChar(bitPattern: b)
                }
                cp[pathBytes.count] = 0
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(fd, sp, addrLen)
            }
        }
        if rc != 0 {
            return "connect() errno=\(errno)"
        }
        return nil
    }

    private func ensureAppRoot() async throws {
        try FileManager.default.createDirectory(at: appRoot, withIntermediateDirectories: true)
    }

    private func writeDaemonConfigIfNeeded() throws -> URL? {
        let config = settings.effectiveDaemonConfigTOML().trimmingCharacters(in: .whitespacesAndNewlines)
        let url = BuilderStoragePaths(appSupportRoot: appRoot).buildKitDaemonConfigURL
        if config.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try config.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Prevent multiple Crucible processes (e.g. the GUI app and the
    /// `crucibled` smoke driver) from attaching the same ext4 state image
    /// at once. VZ reports that case as an opaque "storage device
    /// attachment is invalid" error, so fail earlier with a clear message.
    private func acquireLifecycleLock() throws {
        if lifecycleLockFD >= 0 { return }
        let lockURL = appRoot.appendingPathComponent("crucible.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw BuildKitBackendError.daemonStartFailed("failed to open lifecycle lock: errno=\(errno)")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            throw BuildKitBackendError.alreadyRunning(
                "another Crucible process is already running; stop it before starting a second instance"
            )
        }
        lifecycleLockFD = fd
    }

    private func releaseLifecycleLock() {
        guard lifecycleLockFD >= 0 else { return }
        flock(lifecycleLockFD, LOCK_UN)
        close(lifecycleLockFD)
        lifecycleLockFD = -1
    }

    /// Create and format an ext4 image at `url` if it doesn't already
    /// exist. The file is sparse — `sizeInBytes` is the maximum capacity
    /// the guest sees, not the on-disk footprint, which grows lazily as
    /// buildkitd writes data.
    public static func ensureExt4StateImage(
        at url: URL,
        versionURL: URL,
        version: String,
        sizeInBytes: UInt64
    ) throws {
        let existingVersion = try? String(contentsOf: versionURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if existingVersion != version {
            try? FileManager.default.removeItem(at: url)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        // EXT4.Formatter creates and formats; we just need to call close()
        // to flush the superblock and group descriptors.
        let formatter = try EXT4.Formatter(
            FilePath(url.path),
            minDiskSize: sizeInBytes,
            journal: .default
        )
        try formatter.close()

        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()

        try version.write(to: versionURL, atomically: true, encoding: .utf8)
    }

    private func ensureBuildKitStateImage(at url: URL, sizeInBytes: UInt64) throws {
        try Self.ensureExt4StateImage(
            at: url,
            versionURL: url.deletingLastPathComponent().appendingPathComponent("buildkit-state.version"),
            version: Self.stateImageVersion,
            sizeInBytes: sizeInBytes
        )
    }

    /// Removes `containers/<id>/` if it exists. Used at the start of every
    /// `start()` to recover from prior crashes where `teardown()` couldn't
    /// run (e.g. the host process was SIGKILLed).
    private func removeStaleContainerDirIfPresent() throws {
        let dir = appRoot
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(Self.containerID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    private func handleProcessExit(status: ExitStatus?) {
        // If we already initiated a stop this fires as part of normal
        // shutdown and is uninteresting.
        if case .stopping = state { return }
        if case .stopped = state { return }
        let reason: String
        if let status {
            reason = "buildkitd exited (status=\(status))"
        } else {
            reason = "buildkitd exited unexpectedly"
        }
        let endpoint: BuildKitEndpoint? = {
            if case .running(let ep) = state { return ep }
            return nil
        }()
        transition(to: .degraded(reason: reason, endpoint: endpoint))
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

        // Remove the host socket file the relay leaves behind.
        try? FileManager.default.removeItem(atPath: settings.hostSocketPath)
    }

    private func transition(to new: BuildKitState) {
        state = new
        stateContinuation.yield(new)
    }
}

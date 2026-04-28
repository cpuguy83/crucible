import Foundation
import BuildKitCore

/// Opt-in backend that drives buildkitd by shelling out to the
/// `container` CLI from apple/container.
///
/// **Status:** scaffold only (M1). Real implementation lands in M5.
public actor ContainerCLIBackend: BuildKitBackend {
    private let settings: BuildKitSettings
    private let containerBinaryPath: String
    private var state: BuildKitState = .stopped

    private let stateContinuation: AsyncStream<BuildKitState>.Continuation
    public nonisolated let stateStream: AsyncStream<BuildKitState>

    private let progressContinuation: AsyncStream<BuildKitProgress>.Continuation
    public nonisolated let progressStream: AsyncStream<BuildKitProgress>

    private let logContinuation: AsyncStream<String>.Continuation
    public nonisolated let logStream: AsyncStream<String>

    public init(settings: BuildKitSettings, containerBinaryPath: String = "/usr/local/bin/container") {
        self.settings = settings
        self.containerBinaryPath = containerBinaryPath
        (stateStream, stateContinuation) = AsyncStream<BuildKitState>.makeStream()
        (progressStream, progressContinuation) = AsyncStream<BuildKitProgress>.makeStream()
        (logStream, logContinuation) = AsyncStream<String>.makeStream()
    }

    public func currentState() -> BuildKitState { state }

    public func start() async throws {
        throw BuildKitBackendError.notImplemented("ContainerCLIBackend.start (M5)")
    }

    public func stop() async throws {
        throw BuildKitBackendError.notImplemented("ContainerCLIBackend.stop (M5)")
    }

    public func restart() async throws {
        try await stop()
        try await start()
    }

    public func pullImage() async throws {
        throw BuildKitBackendError.notImplemented("ContainerCLIBackend.pullImage (M5)")
    }
}

import Foundation

/// Trivial backend used by tests and by the UI when no real backend has been
/// wired yet. Honors the state machine but performs no I/O.
public actor StubBackend: BuildKitBackend {
    private let settings: BuildKitSettings
    private var state: BuildKitState = .stopped

    private let stateContinuation: AsyncStream<BuildKitState>.Continuation
    public nonisolated let stateStream: AsyncStream<BuildKitState>

    private let progressContinuation: AsyncStream<BuildKitProgress>.Continuation
    public nonisolated let progressStream: AsyncStream<BuildKitProgress>

    private let logContinuation: AsyncStream<String>.Continuation
    public nonisolated let logStream: AsyncStream<String>

    public init(settings: BuildKitSettings) {
        self.settings = settings
        (stateStream, stateContinuation) = AsyncStream<BuildKitState>.makeStream()
        (progressStream, progressContinuation) = AsyncStream<BuildKitProgress>.makeStream()
        (logStream, logContinuation) = AsyncStream<String>.makeStream()
    }

    public func currentState() -> BuildKitState { state }

    public func start() async throws {
        transition(to: .starting)
        progressContinuation.yield(.init(phase: .startingDaemon, message: "stub start"))
        let endpoint = BuildKitEndpoint(socketPath: settings.hostSocketPath)
        transition(to: .running(endpoint: endpoint))
    }

    public func stop() async throws {
        transition(to: .stopping)
        transition(to: .stopped)
    }

    public func restart() async throws {
        try await stop()
        try await start()
    }

    public func pullImage() async throws {
        progressContinuation.yield(.init(phase: .pullingImage, message: "stub pull"))
    }

    private func transition(to new: BuildKitState) {
        state = new
        stateContinuation.yield(new)
    }
}

import Foundation

/// Abstract interface every BuildKit backend implements.
///
/// Implementations are expected to be thread-safe; state-mutating methods
/// should be serialized internally (typically by being an `actor`).
public protocol BuildKitBackend: Sendable {
    /// Start the daemon. Idempotent when already running. Long-running;
    /// callers should observe ``stateStream`` for transitions and
    /// ``progressStream`` for fine-grained progress.
    func start() async throws

    /// Stop the daemon gracefully. Idempotent when already stopped.
    func stop() async throws

    /// Stop then start. Implementations may optimize this.
    func restart() async throws

    /// Force a re-pull of the configured image.
    func pullImage() async throws

    /// Wipe persistent daemon state (cache, metadata). The caller must
    /// have called `stop()` first; backends throw `.invalidState`
    /// otherwise. Default implementation is a no-op for backends that
    /// don't persist anything.
    func resetState() async throws

    /// Current state snapshot.
    func currentState() async -> BuildKitState

    /// Hot stream of state transitions. Multiple subscribers must each
    /// receive the current state on subscription.
    var stateStream: AsyncStream<BuildKitState> { get }

    /// Hot stream of advisory progress events.
    var progressStream: AsyncStream<BuildKitProgress> { get }

    /// Hot stream of stdout/stderr lines from buildkitd.
    var logStream: AsyncStream<String> { get }
}

/// Errors a backend may surface.
public enum BuildKitBackendError: Error, Sendable, Equatable {
    case notImplemented(String)
    case invalidState(current: String, attempted: String)
    case imagePullFailed(String)
    case daemonStartFailed(String)
    case healthCheckFailed(String)
    case configurationInvalid(String)
    case alreadyRunning(String)
}

/// Default `resetState` for backends without persistent state.
extension BuildKitBackend {
    public func resetState() async throws { /* no-op */ }
}

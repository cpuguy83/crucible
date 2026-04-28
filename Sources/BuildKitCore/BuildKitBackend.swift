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

extension BuildKitBackendError: LocalizedError {
    public var errorDescription: String? { userMessage }

    public var userMessage: String {
        switch self {
        case .notImplemented(let operation):
            return "This backend operation is not implemented yet: \(operation)."
        case .invalidState(let current, let attempted):
            return "Cannot \(attempted) while BuildKit is \(current)."
        case .imagePullFailed(let detail):
            return "Failed to pull the BuildKit image. \(detail)"
        case .daemonStartFailed(let detail):
            return "Failed to start BuildKit. \(detail)"
        case .healthCheckFailed(let detail):
            return "BuildKit started but did not become ready. \(detail)"
        case .configurationInvalid(let detail):
            return "Settings are invalid. \(detail)"
        case .alreadyRunning(let detail):
            return "BuildKit is already running. \(detail)"
        }
    }
}

public func buildKitUserMessage(for error: Error) -> String {
    if let backendError = error as? BuildKitBackendError {
        return backendError.userMessage
    }
    return error.localizedDescription
}

/// Default `resetState` for backends without persistent state.
extension BuildKitBackend {
    public func resetState() async throws { /* no-op */ }
}

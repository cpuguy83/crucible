import Foundation

/// High-level entry point used by the UI. Owns the active backend and the
/// current settings; exposes a stable interface regardless of which backend
/// is selected.
///
/// The supervisor is intentionally backend-agnostic. Backend instantiation is
/// injected via a factory so `BuildKitCore` does not import either backend
/// module (avoids a dependency cycle and keeps `BuildKitCore` headless).
public actor BuildKitSupervisor {
    public typealias BackendFactory = @Sendable (BuildKitSettings) throws -> any BuildKitBackend

    private var settings: BuildKitSettings
    private var backend: (any BuildKitBackend)?
    private let factory: BackendFactory

    public init(settings: BuildKitSettings, factory: @escaping BackendFactory) {
        self.settings = settings
        self.factory = factory
    }

    public func currentSettings() -> BuildKitSettings { settings }

    /// Replace settings. If the backend kind changed and a backend is
    /// currently instantiated, it is torn down; the next `start()` will
    /// create a new one matching the new kind.
    public func updateSettings(_ new: BuildKitSettings) async throws {
        let issues = BuildKitSettingsValidator.validate(new)
        guard issues.isEmpty else {
            throw BuildKitBackendError.configurationInvalid(
                issues.map { String(describing: $0) }.joined(separator: ", ")
            )
        }

        let backendChanged = new.backend != settings.backend
        settings = new

        if backendChanged, let b = backend {
            try? await b.stop()
            backend = nil
        }
    }

    public func start() async throws {
        let b = try ensureBackend()
        try await b.start()
    }

    public func stop() async throws {
        guard let b = backend else { return }
        try await b.stop()
    }

    public func restart() async throws {
        let b = try ensureBackend()
        try await b.restart()
    }

    public func pullImage() async throws {
        let b = try ensureBackend()
        try await b.pullImage()
    }

    /// Stop the daemon (if running) and wipe its persistent state. Useful
    /// for recovery when bbolt or other on-disk state gets corrupted.
    public func resetState() async throws {
        if let b = backend {
            try? await b.stop()
        }
        let b = try ensureBackend()
        try await b.resetState()
    }

    public func currentState() async -> BuildKitState {
        guard let b = backend else { return .stopped }
        return await b.currentState()
    }

    /// Materialize the active backend if needed and return its streams.
    /// UI callers use this before `start()` so they don't miss early
    /// transitions emitted during image pull / VM boot.
    public func streams() throws -> (
        state: AsyncStream<BuildKitState>,
        progress: AsyncStream<BuildKitProgress>,
        logs: AsyncStream<String>
    ) {
        let b = try ensureBackend()
        return (b.stateStream, b.progressStream, b.logStream)
    }

    /// Returns the active backend's state stream. Callers should subscribe
    /// after calling `start()` (or any method that materializes the backend).
    public func stateStream() -> AsyncStream<BuildKitState>? {
        backend?.stateStream
    }

    public func progressStream() -> AsyncStream<BuildKitProgress>? {
        backend?.progressStream
    }

    public func logStream() -> AsyncStream<String>? {
        backend?.logStream
    }

    private func ensureBackend() throws -> any BuildKitBackend {
        if let b = backend { return b }
        let b = try factory(settings)
        backend = b
        return b
    }
}

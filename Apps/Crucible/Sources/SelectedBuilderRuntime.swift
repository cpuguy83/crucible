import Foundation
import BuildKitCore

struct SelectedBuilderRuntime {
    typealias BackendFactory = BuildKitSupervisor.BackendFactory

    private enum Implementation {
        case buildKit(BuildKitSupervisor)
        case unsupported(String)
    }

    private let implementation: Implementation

    init(appSettings: AppSettings, backendFactory: @escaping BackendFactory) {
        switch appSettings.selectedBuilder.kind {
        case .buildKit(let settings):
            self.implementation = .buildKit(BuildKitSupervisor(settings: settings, factory: backendFactory))
        case .docker:
            self.implementation = .unsupported("Docker builders are not implemented yet.")
        }
    }

    var supportsLifecycle: Bool {
        switch implementation {
        case .buildKit: return true
        case .unsupported: return false
        }
    }

    var supportsBuildKitOperations: Bool { supportsLifecycle }

    var initialState: BuildKitState {
        switch implementation {
        case .buildKit:
            return .stopped
        case .unsupported(let message):
            return .error(message)
        }
    }

    func currentState() async -> BuildKitState {
        switch implementation {
        case .buildKit(let supervisor):
            return await supervisor.currentState()
        case .unsupported(let message):
            return .error(message)
        }
    }

    func streams() async throws -> (
        state: AsyncStream<BuildKitState>,
        progress: AsyncStream<BuildKitProgress>,
        logs: AsyncStream<String>
    ) {
        switch implementation {
        case .buildKit(let supervisor):
            return try await supervisor.streams()
        case .unsupported(let message):
            throw BuildKitBackendError.configurationInvalid(message)
        }
    }

    func start() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.start()
        case .unsupported(let message):
            throw BuildKitBackendError.configurationInvalid(message)
        }
    }

    func stop() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.stop()
        case .unsupported:
            return
        }
    }

    func restart() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.restart()
        case .unsupported(let message):
            throw BuildKitBackendError.configurationInvalid(message)
        }
    }

    func pullImage() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.pullImage()
        case .unsupported(let message):
            throw BuildKitBackendError.configurationInvalid(message)
        }
    }

    func resetState() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.resetState()
        case .unsupported(let message):
            throw BuildKitBackendError.configurationInvalid(message)
        }
    }
}

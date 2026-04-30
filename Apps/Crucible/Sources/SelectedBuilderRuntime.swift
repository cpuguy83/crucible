import Foundation
import BuildKitCore
import BuildKitContainerization
import BuildKitContainerCLI

struct SelectedBuilderRuntime {
    typealias BackendFactory = @Sendable (BuildKitSettings, BuilderStoragePaths) throws -> any BuildKitBackend

    private enum Implementation {
        case buildKit(BuildKitSupervisor)
        case docker(DockerContainerizationBackend)
    }

    private let implementation: Implementation

    init(appSettings: AppSettings, backendFactory: @escaping BackendFactory) {
        switch appSettings.selectedBuilder.kind {
        case .buildKit(let settings):
            let paths = BuilderStoragePaths(builderID: appSettings.selectedBuilder.id)
            self.implementation = .buildKit(BuildKitSupervisor(settings: settings) { settings in
                try backendFactory(settings, paths)
            })
        case .docker(let settings):
            self.implementation = .docker(DockerContainerizationBackend(
                settings: settings,
                paths: BuilderStoragePaths(builderID: appSettings.selectedBuilder.id)
            ))
        }
    }

    var supportsLifecycle: Bool { true }

    var supportsBuildKitOperations: Bool {
        true
    }

    var supportsRawBuildKitEndpoint: Bool {
        if case .buildKit = implementation { return true }
        return false
    }

    var supportsImagePull: Bool { true }

    var imageReference: String {
        switch implementation {
        case .buildKit:
            return "BuildKit image"
        case .docker:
            return "Docker image"
        }
    }

    var initialState: BuildKitState {
        switch implementation {
        case .buildKit:
            return .stopped
        case .docker:
            return .stopped
        }
    }

    func currentState() async -> BuildKitState {
        switch implementation {
        case .buildKit(let supervisor):
            return await supervisor.currentState()
        case .docker(let backend):
            return Self.mapDockerState(await backend.currentState())
        }
    }

    func currentDockerEndpoint() async -> DockerDaemonEndpoint? {
        guard case .docker(let backend) = implementation else { return nil }
        if case .running(let endpoint) = await backend.currentState() {
            return endpoint
        }
        return nil
    }

    func currentBuildHistorySocketPath() async -> String? {
        switch implementation {
        case .buildKit(let supervisor):
            return Self.buildKitSocketPath(from: await supervisor.currentState())
        case .docker(let backend):
            if case .running(let endpoint) = await backend.currentState() {
                return endpoint.socketPath
            }
            return nil
        }
    }

    var buildHistoryTransportMode: BuildHistoryClient.TransportMode {
        switch implementation {
        case .buildKit:
            return .buildKitUnixSocket
        case .docker:
            return .dockerDirectH2C
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
        case .docker(let backend):
            return (
                state: Self.mapDockerStateStream(backend.stateStream),
                progress: backend.progressStream,
                logs: backend.logStream
            )
        }
    }

    func start() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.start()
        case .docker(let backend):
            try await backend.start()
        }
    }

    func stop() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.stop()
        case .docker(let backend):
            try await backend.stop()
        }
    }

    func restart() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.restart()
        case .docker(let backend):
            try await backend.restart()
        }
    }

    func pullImage() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.pullImage()
        case .docker(let backend):
            try await backend.pullImage()
        }
    }

    func resetState() async throws {
        switch implementation {
        case .buildKit(let supervisor):
            try await supervisor.resetState()
        case .docker(let backend):
            try await backend.resetState()
        }
    }

    func isRunning(_ state: BuildKitState) -> Bool {
        switch state {
        case .running, .degraded:
            return true
        default:
            return false
        }
    }

    private static func mapDockerState(_ state: DockerDaemonState) -> BuildKitState {
        switch state {
        case .stopped:
            return .stopped
        case .starting:
            return .starting
        case .running(let endpoint):
            return .running(endpoint: BuildKitEndpoint(socketPath: endpoint.socketPath))
        case .stopping:
            return .stopping
        case .error(let message):
            return .error(message)
        }
    }

    private static func buildKitSocketPath(from state: BuildKitState) -> String? {
        switch state {
        case .running(let endpoint):
            return endpoint.socketPath
        case .degraded(_, let endpoint):
            return endpoint?.socketPath
        default:
            return nil
        }
    }

    private static func mapDockerStateStream(_ stream: AsyncStream<DockerDaemonState>) -> AsyncStream<BuildKitState> {
        AsyncStream { continuation in
            let task = Task {
                for await state in stream {
                    continuation.yield(mapDockerState(state))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

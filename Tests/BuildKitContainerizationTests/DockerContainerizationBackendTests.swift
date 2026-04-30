import Foundation
import Testing
@testable import BuildKitCore
@testable import BuildKitContainerization

struct DockerContainerizationBackendTests {
    @Test func startsStopped() async {
        let backend = DockerContainerizationBackend(
            settings: DockerSettings(),
            paths: BuilderStoragePaths(appSupportRoot: URL(fileURLWithPath: "/tmp/Crucible", isDirectory: true), builderID: "docker")
        )

        #expect(await backend.currentState() == .stopped)
    }
}

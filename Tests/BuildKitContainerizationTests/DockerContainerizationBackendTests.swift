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

    @Test func hostMountSharesMapToVirtiofsAtIdenticalPath() {
        let settings = DockerSettings(hostMounts: [
            HostMount(path: "/Users/me/proj"),
            HostMount(path: "/Users/me/data", readOnly: true),
        ])

        let mounts = DockerContainerizationBackend.hostMountShares(for: settings)

        #expect(mounts.count == 2)

        #expect(mounts[0].source == "/Users/me/proj")
        #expect(mounts[0].destination == "/Users/me/proj")
        #expect(mounts[0].type == "virtiofs")
        #expect(mounts[0].options == [])

        #expect(mounts[1].source == "/Users/me/data")
        #expect(mounts[1].destination == "/Users/me/data")
        #expect(mounts[1].options == ["ro"])
    }

    @Test func hostMountSharesEmptyWhenNoneConfigured() {
        #expect(DockerContainerizationBackend.hostMountShares(for: DockerSettings()).isEmpty)
    }
}

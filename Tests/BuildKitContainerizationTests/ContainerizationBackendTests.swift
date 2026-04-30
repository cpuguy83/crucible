import Foundation
import Testing
@testable import BuildKitCore
@testable import BuildKitContainerization

struct ContainerizationBackendTests {
    @Test func acceptsCustomAppRootForBuilderScopedStorage() async {
        let root = URL(fileURLWithPath: "/tmp/Crucible/builders/buildkit", isDirectory: true)
        let backend = ContainerizationBackend(settings: BuildKitSettings(), appRoot: root)

        #expect(await backend.currentState() == .stopped)
    }
}

@preconcurrency import Containerization
import ContainerizationError
import ContainerizationOCI

enum ImagePullAuthenticator {
    static func authentication(for reference: String) async throws -> Authentication? {
        try await DockerCredentialResolver().authentication(for: reference)
    }

    static func pull(reference: String, imageStore: ImageStore) async throws {
        let auth = try await authentication(for: reference)
        do {
            _ = try await imageStore.get(reference: reference)
        } catch let error as ContainerizationError where error.code == .notFound {
            _ = try await imageStore.pull(reference: reference, auth: auth)
        }
    }
}

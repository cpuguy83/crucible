@preconcurrency import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

enum ImagePrefetcher {
    static func prefetch(reference: String, imageStore: ImageStore, auth: Authentication? = nil) async -> String? {
        do {
            do {
                _ = try await imageStore.get(reference: reference)
            } catch let error as ContainerizationError where error.code == .notFound {
                _ = try await imageStore.pull(reference: reference, auth: auth)
            }
            return nil
        } catch {
            return String(describing: error)
        }
    }
}

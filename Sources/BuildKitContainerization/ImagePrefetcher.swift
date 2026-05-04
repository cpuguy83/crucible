@preconcurrency import Containerization
import ContainerizationOCI
import Foundation

enum ImagePrefetcher {
    static func prefetch(reference: String, imageStore: ImageStore) async -> String? {
        do {
            _ = try await imageStore.pull(reference: reference)
            return nil
        } catch {
            return String(describing: error)
        }
    }
}

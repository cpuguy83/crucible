@preconcurrency import Containerization
import ContainerizationError
import ContainerizationOCI

enum ImagePullAuthenticator {
    static func authentication(for reference: String) async throws -> Authentication? {
        let lookup = await DockerCredentialResolver().lookup(forReference: reference)
        if case .failed = lookup.status {
            throw ImagePullError.credentialLookupFailed(reference: reference, lookup: lookup)
        }
        return lookup.authentication
    }

    static func prefetch(reference: String, imageStore: ImageStore) async -> String? {
        let lookup = await DockerCredentialResolver().lookup(forReference: reference)
        if case .failed = lookup.status {
            return ImagePullError.credentialLookupFailed(reference: reference, lookup: lookup).description
        }
        do {
            try await pullIfMissing(reference: reference, imageStore: imageStore, auth: lookup.authentication)
            return nil
        } catch {
            return ImagePullError.pullFailed(reference: reference, lookup: lookup, underlying: String(describing: error)).description
        }
    }

    static func pull(reference: String, imageStore: ImageStore) async throws {
        let lookup = await DockerCredentialResolver().lookup(forReference: reference)
        if case .failed = lookup.status {
            throw ImagePullError.credentialLookupFailed(reference: reference, lookup: lookup)
        }
        do {
            try await pullIfMissing(reference: reference, imageStore: imageStore, auth: lookup.authentication)
        } catch {
            throw ImagePullError.pullFailed(reference: reference, lookup: lookup, underlying: String(describing: error))
        }
    }

    private static func pullIfMissing(reference: String, imageStore: ImageStore, auth: Authentication?) async throws {
        do {
            _ = try await imageStore.get(reference: reference)
        } catch let error as ContainerizationError where error.code == .notFound {
            _ = try await imageStore.pull(reference: reference, auth: auth)
        }
    }
}

enum ImagePullError: Error, CustomStringConvertible, Equatable {
    case credentialLookupFailed(reference: String, lookup: DockerCredentialLookup)
    case pullFailed(reference: String, lookup: DockerCredentialLookup, underlying: String)

    var description: String {
        switch self {
        case .credentialLookupFailed(_, let lookup):
            return lookup.actionableMessage
        case .pullFailed(let reference, let lookup, let underlying):
            if isAuthenticationFailure(underlying) {
                return authenticationFailureMessage(reference: reference, lookup: lookup, underlying: underlying)
            }
            return underlying
        }
    }

    private func authenticationFailureMessage(reference: String, lookup: DockerCredentialLookup, underlying: String) -> String {
        let host = lookup.resolvedRegistryHost ?? lookup.registryHost ?? "the registry"
        switch lookup.status {
        case .found(_, let source):
            return "Authentication failed for \(host) while pulling \(reference). Refresh Docker credentials from \(source.description) with docker login \(host) and try again. \(underlying)"
        case .notFound(let reason):
            if case .helperNotFound(let helper)? = reason {
                return "Authentication required for \(host) while pulling \(reference). Install \(helper) or run docker login \(host) and try again. \(underlying)"
            }
            return "Authentication required for \(host) while pulling \(reference). Run docker login \(host) and try again. \(underlying)"
        case .failed:
            return lookup.actionableMessage
        case .notRequired:
            return underlying
        }
    }

    private func isAuthenticationFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("401")
            || lower.contains("403")
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("access denied")
            || lower.contains("authentication required")
            || lower.contains("wrong credentials")
    }
}

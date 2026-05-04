import ContainerizationOCI
import Foundation

struct DockerCredentialResolver: Sendable {
    var configURL: URL?
    var environment: [String: String]
    var helperTimeout: TimeInterval

    init(
        configURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        helperTimeout: TimeInterval = 5
    ) {
        self.configURL = configURL
        self.environment = environment
        self.helperTimeout = helperTimeout
    }

    func authentication(for reference: String) async throws -> Authentication? {
        let lookup = await lookup(forReference: reference)
        if case .failed = lookup.status {
            throw Error.lookupFailed(lookup)
        }
        return lookup.authentication
    }

    func lookup(forReference reference: String) async -> DockerCredentialLookup {
        let host: String?
        do {
            host = try registryHost(forReference: reference)
        } catch {
            return .init(reference: reference, registryHost: nil, resolvedRegistryHost: nil, status: .failed(.invalidReference(String(describing: error))))
        }
        guard let host else {
            return .init(reference: reference, registryHost: nil, resolvedRegistryHost: nil, status: .notRequired)
        }
        return await lookup(forRegistryHost: host, reference: reference)
    }

    func credentials(forReference reference: String) async throws -> DockerRegistryCredentials? {
        let lookup = await lookup(forReference: reference)
        if case .failed = lookup.status {
            throw Error.lookupFailed(lookup)
        }
        return lookup.credentials
    }

    func credentials(forRegistryHost host: String) async throws -> DockerRegistryCredentials? {
        let lookup = await lookup(forRegistryHost: host, reference: nil)
        if case .failed = lookup.status {
            throw Error.lookupFailed(lookup)
        }
        return lookup.credentials
    }

    func lookup(forRegistryHost host: String, reference: String? = nil) async -> DockerCredentialLookup {
        let resolvedHost = Self.resolveRegistryHost(host)
        let config: DockerConfig?
        do {
            config = try loadConfig()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            config = nil
        } catch let error as POSIXError where error.code == .ENOENT {
            config = nil
        } catch {
            return .init(reference: reference, registryHost: host, resolvedRegistryHost: resolvedHost, status: .failed(.configLoadFailed(String(describing: error))))
        }

        if let config {
            if let helper = config.credentialHelpers?[resolvedHost] {
                return await lookupFromHelper(helper, host: resolvedHost, registryHost: host, reference: reference, source: .credentialHelper(helper))
            }

            if let store = config.credentialsStore, !store.isEmpty {
                let storeLookup = await lookupFromHelper(store, host: resolvedHost, registryHost: host, reference: reference, source: .credentialsStore(store))
                switch storeLookup.status {
                case .found, .failed:
                    return storeLookup
                case .notFound, .notRequired:
                    break
                }
            }

            if let auth = config.authConfigs?[resolvedHost] {
                do {
                    if let credentials = try Self.credentials(from: auth) {
                        return .init(reference: reference, registryHost: host, resolvedRegistryHost: resolvedHost, status: .found(credentials, .inlineAuth))
                    }
                } catch {
                    return .init(reference: reference, registryHost: host, resolvedRegistryHost: resolvedHost, status: .failed(.invalidDockerAuth(String(describing: error))))
                }
            }
        }

        guard let defaultHelper = Self.defaultCredentialHelper() else {
            return .init(reference: reference, registryHost: host, resolvedRegistryHost: resolvedHost, status: .notFound(nil))
        }
        return await lookupFromHelper(defaultHelper, host: resolvedHost, registryHost: host, reference: reference, source: .defaultCredentialHelper(defaultHelper))
    }

    func lookupFromHelper(
        _ helper: String,
        host: String,
        registryHost: String,
        reference: String?,
        source: DockerCredentialSource
    ) async -> DockerCredentialLookup {
        let executableName = "docker-credential-\(helper)"
        guard let executable = findExecutable(named: executableName) else {
            return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .notFound(.helperNotFound(executableName)))
        }

        do {
            let output = try await runHelper(executable: executable, host: host)
            if output.exitCode != 0 {
                let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if stdout == Self.credentialsNotFoundMessage {
                    return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .notFound(.credentialsNotFound))
                }
                if stdout == Self.credentialsMissingServerURLMessage {
                    return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .failed(.credentialsMissingServerURL))
                }
                return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .failed(.helperFailed(helper: executableName, stdout: stdout, stderr: stderr, exitCode: output.exitCode)))
            }

            let response = try JSONDecoder().decode(CredentialHelperResponse.self, from: Data(output.stdout.utf8))
            guard !response.username.isEmpty || !response.secret.isEmpty else {
                return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .notFound(.credentialsNotFound))
            }
            let credentials = DockerRegistryCredentials(
                username: response.username == Self.tokenUsername ? "" : response.username,
                secret: response.secret,
                isIdentityToken: response.username == Self.tokenUsername
            )
            return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .found(credentials, source))
        } catch let error as Error {
            return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .failed(.helperTimedOut(String(describing: error))))
        } catch {
            return .init(reference: reference, registryHost: registryHost, resolvedRegistryHost: host, status: .failed(.helperFailed(helper: executableName, stdout: "", stderr: String(describing: error), exitCode: -1)))
        }
    }

    func registryHost(forReference reference: String) throws -> String? {
        let ref = try Reference.parse(reference)
        return ref.resolvedDomain
    }

    func loadConfig() throws -> DockerConfig {
        let url = configURL ?? defaultConfigURL()
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(DockerConfig.self, from: data)
    }

    func defaultConfigURL() -> URL {
        if let dockerConfig = environment["DOCKER_CONFIG"], !dockerConfig.isEmpty {
            return URL(fileURLWithPath: dockerConfig, isDirectory: true).appendingPathComponent("config.json")
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".docker", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    func credentialsFromHelper(_ helper: String, host: String) async throws -> DockerRegistryCredentials? {
        let helperName: String
        if helper.isEmpty {
            guard let defaultHelper = Self.defaultCredentialHelper() else { return nil }
            helperName = defaultHelper
        } else {
            helperName = helper
        }

        let executableName = "docker-credential-\(helperName)"
        guard let executable = findExecutable(named: executableName) else { return nil }

        let output = try await runHelper(executable: executable, host: host)
        if output.exitCode != 0 {
            let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if stdout == Self.credentialsNotFoundMessage { return nil }
            if stdout == Self.credentialsMissingServerURLMessage { throw Error.credentialsMissingServerURL }
            throw Error.helperFailed(helper: executableName, stdout: stdout, stderr: stderr, exitCode: output.exitCode)
        }

        let response = try JSONDecoder().decode(CredentialHelperResponse.self, from: Data(output.stdout.utf8))
        guard !response.username.isEmpty || !response.secret.isEmpty else { return nil }
        return DockerRegistryCredentials(
            username: response.username == Self.tokenUsername ? "" : response.username,
            secret: response.secret,
            isIdentityToken: response.username == Self.tokenUsername
        )
    }

    func findExecutable(named name: String) -> String? {
        for directory in helperSearchPaths() {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func helperSearchPaths() -> [String] {
        var paths = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !paths.contains(path) {
            paths.append(path)
        }
        return paths
    }

    func runHelper(executable: String, host: String) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["get"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            let box = ProcessContinuationBox(continuation)
            process.terminationHandler = { process in
                let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                box.resume(.success(ProcessOutput(
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus
                )))
            }

            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(host.utf8))
                try? stdin.fileHandleForWriting.close()
            } catch {
                box.resume(.failure(error))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + helperTimeout) {
                guard process.isRunning else { return }
                process.terminate()
                box.resume(.failure(Error.helperTimedOut(URL(fileURLWithPath: executable).lastPathComponent)))
            }
        }
    }
}

public struct ImageAuthDiagnostic: Identifiable, Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case initfs = "Init filesystem"
        case daemon = "Daemon image"
    }

    public enum Status: String, Sendable, Equatable {
        case available = "Credentials available"
        case missing = "No credentials found"
        case notRequired = "No registry credentials required"
        case failed = "Credential lookup failed"
    }

    public var id: String { "\(role.rawValue):\(reference)" }
    public var role: Role
    public var reference: String
    public var registryHost: String
    public var status: Status
    public var source: String?
    public var detail: String

    public init(role: Role, reference: String, registryHost: String, status: Status, source: String?, detail: String) {
        self.role = role
        self.reference = reference
        self.registryHost = registryHost
        self.status = status
        self.source = source
        self.detail = detail
    }
}

public enum ImageAuthDiagnostics {
    public static func diagnostics(initfsReference: String, imageReference: String) async -> [ImageAuthDiagnostic] {
        let resolver = DockerCredentialResolver()
        async let initfs = diagnostic(role: .initfs, reference: initfsReference, resolver: resolver)
        async let daemon = diagnostic(role: .daemon, reference: imageReference, resolver: resolver)
        return await [initfs, daemon]
    }

    static func diagnostic(
        role: ImageAuthDiagnostic.Role,
        reference: String,
        resolver: DockerCredentialResolver
    ) async -> ImageAuthDiagnostic {
        let lookup = await resolver.lookup(forReference: reference)
        let registryHost = lookup.resolvedRegistryHost ?? lookup.registryHost ?? "none"
        let status: ImageAuthDiagnostic.Status
        let source: String?
        switch lookup.status {
        case .found(_, let credentialSource):
            status = .available
            source = credentialSource.description
        case .notFound:
            status = .missing
            source = nil
        case .notRequired:
            status = .notRequired
            source = nil
        case .failed:
            status = .failed
            source = nil
        }
        return ImageAuthDiagnostic(
            role: role,
            reference: reference,
            registryHost: registryHost,
            status: status,
            source: source,
            detail: lookup.actionableMessage
        )
    }
}

extension DockerCredentialResolver {
    static let tokenUsername = "<token>"
    static let credentialsNotFoundMessage = "credentials not found in native keychain"
    static let credentialsMissingServerURLMessage = "no credentials server URL"

    static func resolveRegistryHost(_ host: String) -> String {
        switch host {
        case "index.docker.io", "docker.io", "https://index.docker.io/v1/", "registry-1.docker.io":
            return "https://index.docker.io/v1/"
        default:
            return host
        }
    }

    static func defaultCredentialHelper() -> String? {
        #if os(macOS)
        return "osxkeychain"
        #elseif os(Windows)
        return "wincred"
        #else
        return nil
        #endif
    }

    static func credentials(from auth: DockerAuthConfig) throws -> DockerRegistryCredentials? {
        if let token = auth.identityToken, !token.isEmpty {
            return DockerRegistryCredentials(username: "", secret: token, isIdentityToken: true)
        }
        if let username = auth.username, let password = auth.password,
           !username.isEmpty || !password.isEmpty {
            return DockerRegistryCredentials(username: username, secret: password, isIdentityToken: false)
        }
        guard let encoded = auth.auth, !encoded.isEmpty else { return nil }
        guard let data = Data(base64Encoded: encoded), let decoded = String(data: data, encoding: .utf8) else {
            throw Error.invalidBase64Auth
        }
        guard let separator = decoded.firstIndex(of: ":") else {
            throw Error.invalidBase64Auth
        }
        return DockerRegistryCredentials(
            username: String(decoded[..<separator]),
            secret: String(decoded[decoded.index(after: separator)...]),
            isIdentityToken: false
        )
    }

    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case missingRegistryHost(String)
        case loadConfig(String)
        case invalidBase64Auth
        case credentialsMissingServerURL
        case helperFailed(helper: String, stdout: String, stderr: String, exitCode: Int32)
        case helperTimedOut(String)
        case lookupFailed(DockerCredentialLookup)

        var description: String {
            switch self {
            case .missingRegistryHost(let reference):
                return "image reference has no registry host: \(reference)"
            case .loadConfig(let message):
                return "load Docker config: \(message)"
            case .invalidBase64Auth:
                return "invalid Docker auth entry"
            case .credentialsMissingServerURL:
                return DockerCredentialResolver.credentialsMissingServerURLMessage
            case .helperFailed(let helper, let stdout, let stderr, let exitCode):
                return "execute \(helper) failed with exit code \(exitCode), stdout: \(stdout), stderr: \(stderr)"
            case .helperTimedOut(let helper):
                return "execute \(helper) timed out"
            case .lookupFailed(let lookup):
                return lookup.actionableMessage
            }
        }
    }
}

struct DockerConfig: Decodable, Equatable {
    var authConfigs: [String: DockerAuthConfig]?
    var credentialsStore: String?
    var credentialHelpers: [String: String]?

    enum CodingKeys: String, CodingKey {
        case authConfigs = "auths"
        case credentialsStore = "credsStore"
        case credentialHelpers = "credHelpers"
    }
}

struct DockerAuthConfig: Decodable, Equatable {
    var username: String?
    var password: String?
    var auth: String?
    var identityToken: String?

    enum CodingKeys: String, CodingKey {
        case username
        case password
        case auth
        case identityToken = "identitytoken"
    }
}

struct DockerRegistryCredentials: Equatable, Sendable {
    var username: String
    var secret: String
    var isIdentityToken: Bool
}

struct DockerCredentialLookup: Equatable, Sendable, CustomStringConvertible {
    var reference: String?
    var registryHost: String?
    var resolvedRegistryHost: String?
    var status: DockerCredentialLookupStatus

    var credentials: DockerRegistryCredentials? {
        if case .found(let credentials, _) = status { return credentials }
        return nil
    }

    var authentication: Authentication? {
        guard let credentials else { return nil }
        return DockerCredentialAuthentication(credentials: credentials)
    }

    var actionableMessage: String {
        let host = resolvedRegistryHost ?? registryHost ?? "the registry"
        switch status {
        case .found(_, let source):
            return "Using Docker credentials for \(host) from \(source.description)."
        case .notRequired:
            return "No registry credentials are required for \(reference ?? "this image")."
        case .notFound(let reason):
            if case .helperNotFound(let helper)? = reason {
                return "No Docker credentials found for \(host). Install \(helper) or run docker login \(host) and try again."
            }
            return "No Docker credentials found for \(host). Run docker login \(host) and try again."
        case .failed(let reason):
            return "Could not read Docker credentials for \(host): \(reason.description). Run docker login \(host) and try again."
        }
    }

    var description: String { actionableMessage }
}

enum DockerCredentialLookupStatus: Equatable, Sendable {
    case found(DockerRegistryCredentials, DockerCredentialSource)
    case notFound(DockerCredentialNotFoundReason?)
    case notRequired
    case failed(DockerCredentialFailure)
}

enum DockerCredentialSource: Equatable, Sendable, CustomStringConvertible {
    case credentialHelper(String)
    case credentialsStore(String)
    case defaultCredentialHelper(String)
    case inlineAuth

    var description: String {
        switch self {
        case .credentialHelper(let helper): return "credHelpers entry docker-credential-\(helper)"
        case .credentialsStore(let store): return "credsStore docker-credential-\(store)"
        case .defaultCredentialHelper(let helper): return "default helper docker-credential-\(helper)"
        case .inlineAuth: return "Docker config auths"
        }
    }
}

enum DockerCredentialNotFoundReason: Equatable, Sendable {
    case helperNotFound(String)
    case credentialsNotFound
}

enum DockerCredentialFailure: Equatable, Sendable, CustomStringConvertible {
    case invalidReference(String)
    case configLoadFailed(String)
    case invalidDockerAuth(String)
    case credentialsMissingServerURL
    case helperFailed(helper: String, stdout: String, stderr: String, exitCode: Int32)
    case helperTimedOut(String)

    var description: String {
        switch self {
        case .invalidReference(let message):
            return "invalid image reference (\(message))"
        case .configLoadFailed(let message):
            return "load Docker config: \(message)"
        case .invalidDockerAuth(let message):
            return "invalid Docker auth entry (\(message))"
        case .credentialsMissingServerURL:
            return DockerCredentialResolver.credentialsMissingServerURLMessage
        case .helperFailed(let helper, let stdout, let stderr, let exitCode):
            return "execute \(helper) failed with exit code \(exitCode), stdout: \(stdout), stderr: \(stderr)"
        case .helperTimedOut(let helper):
            return "execute \(helper) timed out"
        }
    }
}

struct DockerCredentialAuthentication: Authentication {
    var credentials: DockerRegistryCredentials

    func token() async throws -> String {
        if credentials.isIdentityToken || credentials.username.isEmpty {
            return "Bearer \(credentials.secret)"
        }
        return try await BasicAuthentication(username: credentials.username, password: credentials.secret).token()
    }
}

private struct CredentialHelperResponse: Decodable {
    var username: String
    var secret: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case secret = "Secret"
    }
}

struct ProcessOutput: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

private final class ProcessContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<ProcessOutput, Swift.Error>

    init(_ continuation: CheckedContinuation<ProcessOutput, Swift.Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<ProcessOutput, Swift.Error>) {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()

        switch result {
        case .success(let output): continuation.resume(returning: output)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

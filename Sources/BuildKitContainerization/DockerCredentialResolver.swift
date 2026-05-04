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
        guard let credentials = try await credentials(forReference: reference) else { return nil }
        return DockerCredentialAuthentication(credentials: credentials)
    }

    func credentials(forReference reference: String) async throws -> DockerRegistryCredentials? {
        guard let host = try registryHost(forReference: reference) else { return nil }
        return try await credentials(forRegistryHost: host)
    }

    func credentials(forRegistryHost host: String) async throws -> DockerRegistryCredentials? {
        let resolvedHost = Self.resolveRegistryHost(host)
        let config: DockerConfig?
        do {
            config = try loadConfig()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            config = nil
        } catch let error as POSIXError where error.code == .ENOENT {
            config = nil
        } catch {
            throw Error.loadConfig(String(describing: error))
        }

        if let config {
            if let helper = config.credentialHelpers?[resolvedHost] {
                return try await credentialsFromHelper(helper, host: resolvedHost)
            }

            if let store = config.credentialsStore, !store.isEmpty,
               let credentials = try await credentialsFromHelper(store, host: resolvedHost) {
                return credentials
            }

            if let auth = config.authConfigs?[resolvedHost] {
                return try Self.credentials(from: auth)
            }
        }

        return try await credentialsFromHelper("", host: resolvedHost)
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

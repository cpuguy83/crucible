import Foundation
import Testing
@testable import BuildKitContainerization

@Suite("DockerCredentialResolver")
struct DockerCredentialResolverTests {
    @Test func resolvesDockerHubCredentialHost() {
        #expect(DockerCredentialResolver.resolveRegistryHost("docker.io") == "https://index.docker.io/v1/")
        #expect(DockerCredentialResolver.resolveRegistryHost("registry-1.docker.io") == "https://index.docker.io/v1/")
        #expect(DockerCredentialResolver.resolveRegistryHost("ghcr.io") == "ghcr.io")
    }

    @Test func defaultConfigURLUsesDockerConfig() {
        let resolver = DockerCredentialResolver(environment: ["DOCKER_CONFIG": "/tmp/docker-config", "HOME": "/tmp/home"])
        #expect(resolver.defaultConfigURL().path == "/tmp/docker-config/config.json")
    }

    @Test func decodesInlineBase64Auth() throws {
        let auth = DockerAuthConfig(
            username: nil,
            password: nil,
            auth: Data("user:pass".utf8).base64EncodedString(),
            identityToken: nil
        )

        let credentials = try DockerCredentialResolver.credentials(from: auth)
        #expect(credentials == DockerRegistryCredentials(username: "user", secret: "pass", isIdentityToken: false))
    }

    @Test func identityTokenUsesEmptyUsername() throws {
        let auth = DockerAuthConfig(username: nil, password: nil, auth: nil, identityToken: "token")

        let credentials = try DockerCredentialResolver.credentials(from: auth)
        #expect(credentials == DockerRegistryCredentials(username: "", secret: "token", isIdentityToken: true))
    }

    @Test func inlineAuthsAreReadFromConfig() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.json")
        try writeJSON(
            """
            {"auths":{"ghcr.io":{"username":"octo","password":"secret"}}}
            """,
            to: config
        )
        let resolver = DockerCredentialResolver(configURL: config, environment: ["PATH": dir.path])

        let credentials = try await resolver.credentials(forRegistryHost: "ghcr.io")
        #expect(credentials == DockerRegistryCredentials(username: "octo", secret: "secret", isIdentityToken: false))
    }

    @Test func credentialHelperOverridesInlineAuth() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeHelper(name: "docker-credential-test", output: #"{"Username":"helper","Secret":"helper-secret"}"#, in: dir)
        let config = dir.appendingPathComponent("config.json")
        try writeJSON(
            """
            {
              "credHelpers":{"ghcr.io":"test"},
              "auths":{"ghcr.io":{"username":"inline","password":"inline-secret"}}
            }
            """,
            to: config
        )
        let resolver = DockerCredentialResolver(configURL: config, environment: ["PATH": dir.path])

        let credentials = try await resolver.credentials(forRegistryHost: "ghcr.io")
        #expect(credentials == DockerRegistryCredentials(username: "helper", secret: "helper-secret", isIdentityToken: false))
    }

    @Test func helperTokenUsernameBecomesIdentityToken() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeHelper(name: "docker-credential-test", output: #"{"Username":"<token>","Secret":"id-token"}"#, in: dir)
        let resolver = DockerCredentialResolver(environment: ["PATH": dir.path])

        let credentials = try await resolver.credentialsFromHelper("test", host: "ghcr.io")
        #expect(credentials == DockerRegistryCredentials(username: "", secret: "id-token", isIdentityToken: true))
    }

    @Test func helperCredentialsNotFoundReturnsNil() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeHelper(
            name: "docker-credential-test",
            output: DockerCredentialResolver.credentialsNotFoundMessage,
            exitCode: 1,
            in: dir
        )
        let resolver = DockerCredentialResolver(environment: ["PATH": dir.path])

        let credentials = try await resolver.credentialsFromHelper("test", host: "ghcr.io")
        #expect(credentials == nil)
    }

    @Test func registryHostForReferenceUsesContainerizationNormalization() throws {
        let resolver = DockerCredentialResolver(environment: [:])
        #expect(try resolver.registryHost(forReference: "docker.io/library/alpine:latest") == "registry-1.docker.io")
        #expect(try resolver.registryHost(forReference: "ghcr.io/example/image:latest") == "ghcr.io")
        #expect(try resolver.registryHost(forReference: "alpine:latest") == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crucible-docker-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeJSON(_ json: String, to url: URL) throws {
        try json.data(using: .utf8)!.write(to: url)
    }

    private func writeHelper(name: String, output: String, exitCode: Int = 0, in directory: URL) throws {
        let script = directory.appendingPathComponent(name)
        let body = """
        #!/bin/sh
        cat >/dev/null
        printf '%s' '\(output.replacingOccurrences(of: "'", with: "'\\''"))'
        exit \(exitCode)
        """
        try body.data(using: .utf8)!.write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
}

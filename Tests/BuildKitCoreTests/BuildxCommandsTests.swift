import Testing
@testable import BuildKitCore

@Suite("BuildxCommands")
struct BuildxCommandsTests {
    let endpoint = BuildKitEndpoint(
        socketPath: "/Users/me/Library/Application Support/Crucible/buildkitd.sock"
    )

    @Test func unixURLPercentEncodesSpaces() {
        let url = BuildxCommands.unixURL(for: endpoint)
        #expect(url == "unix:///Users/me/Library/Application%20Support/Crucible/buildkitd.sock")
    }

    @Test func buildKitHostEnvIsSingleQuoted() {
        let line = BuildxCommands.buildKitHostEnv(for: endpoint)
        #expect(line.hasPrefix("BUILDKIT_HOST='unix://"))
        #expect(line.hasSuffix(".sock'"))
    }

    @Test func dockerBuildxCreateCommandIncludesUseByDefault() {
        let cmd = BuildxCommands.dockerBuildxCreateCommand(for: endpoint)
        #expect(cmd.contains("--name crucible"))
        #expect(cmd.contains("--driver remote"))
        #expect(cmd.contains("'unix:///Users/me/Library/Application%20Support/Crucible/buildkitd.sock'"))
        #expect(cmd.hasSuffix("&& docker buildx use crucible"))
    }

    @Test func dockerBuildxCreateCommandCanOmitUse() {
        let cmd = BuildxCommands.dockerBuildxCreateCommand(
            for: endpoint, useAfterCreate: false
        )
        #expect(!cmd.contains("buildx use"))
    }

    @Test func argumentsKeepRawPathAndExposeBuilderName() {
        let args = BuildxCommands.dockerBuildxCreateArguments(
            for: endpoint, builderName: "test-builder"
        )
        #expect(args == [
            "buildx", "create",
            "--name", "test-builder",
            "--driver", "remote",
            "unix:///Users/me/Library/Application Support/Crucible/buildkitd.sock",
        ])
    }

    @Test func removeAndInspectArgumentsAreSimple() {
        #expect(BuildxCommands.dockerBuildxRemoveArguments() == ["buildx", "rm", "crucible"])
        #expect(BuildxCommands.dockerBuildxInspectArguments(builderName: "x") == ["buildx", "inspect", "x"])
    }
}

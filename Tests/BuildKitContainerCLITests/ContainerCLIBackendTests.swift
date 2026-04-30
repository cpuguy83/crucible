import Foundation
import Testing
@testable import BuildKitCore
@testable import BuildKitContainerCLI

struct ContainerCLICommandsTests {
    @Test func runCommandPublishesSocketAndPersistsState() {
        var settings = BuildKitSettings()
        settings.hostSocketPath = "/tmp/crucible.sock"
        settings.cpuCount = 6
        settings.memoryMiB = 8192

        let command = ContainerCLICommands.runDetachedBuildKit(
            binary: "/opt/homebrew/bin/container",
            containerID: "crucible-buildkitd",
            settings: settings,
            statePath: "/tmp/crucible-state",
            configDirectoryPath: nil
        )

        #expect(command.executable == "/opt/homebrew/bin/container")
        #expect(command.arguments.contains("--detach"))
        #expect(command.arguments.contains("--publish-socket"))
        #expect(command.arguments.contains("/tmp/crucible.sock:/run/buildkit/buildkitd.sock"))
        #expect(command.arguments.contains("type=bind,source=/tmp/crucible-state,target=/var/lib/buildkit"))
        #expect(command.arguments.suffix(3) == ["/usr/bin/buildkitd", "--addr", "unix:///run/buildkit/buildkitd.sock"])
    }

    @Test func runCommandMountsDaemonConfigWhenSet() {
        let settings = BuildKitSettings()
        let command = ContainerCLICommands.runDetachedBuildKit(
            binary: "/opt/homebrew/bin/container",
            containerID: "crucible-buildkitd",
            settings: settings,
            statePath: "/tmp/crucible-state",
            configDirectoryPath: "/tmp/buildkitd-config"
        )

        #expect(command.arguments.contains("type=bind,source=/tmp/buildkitd-config,target=/etc/buildkit,readonly"))
        #expect(command.arguments.suffix(5) == ["/usr/bin/buildkitd", "--addr", "unix:///run/buildkit/buildkitd.sock", "--config", "/etc/buildkit/buildkitd.toml"])
    }

    @Test func runCommandAlwaysEnablesRosetta() {
        let settings = BuildKitSettings()
        let command = ContainerCLICommands.runDetachedBuildKit(
            binary: "/opt/homebrew/bin/container",
            containerID: "crucible-buildkitd",
            settings: settings,
            statePath: "/tmp/crucible-state",
            configDirectoryPath: nil
        )

        #expect(command.arguments.contains("--rosetta"))
    }

    @Test func dockerRunCommandStartsDindAndPublishesDockerSocket() {
        let command = ContainerCLICommands.runDetachedDocker(
            binary: "/opt/homebrew/bin/container",
            containerID: "crucible-docker",
            settings: DockerSettings(imageReference: "docker.io/library/docker:27-dind"),
            socketPath: "/tmp/crucible-docker.sock",
            dataRootPath: "/tmp/crucible-docker-data"
        )

        #expect(command.executable == "/opt/homebrew/bin/container")
        #expect(command.arguments.contains("--detach"))
        #expect(command.arguments.contains("--privileged"))
        #expect(command.arguments.contains("DOCKER_TLS_CERTDIR="))
        #expect(command.arguments.contains("/tmp/crucible-docker.sock:/var/run/docker.sock"))
        #expect(command.arguments.contains("type=bind,source=/tmp/crucible-docker-data,target=/var/lib/docker"))
        #expect(command.arguments.suffix(6) == ["docker.io/library/docker:27-dind", "dockerd", "--host", "unix:///var/run/docker.sock", "--data-root", "/var/lib/docker"])
    }

    @Test func dockerRunCommandAlwaysEnablesRosetta() {
        let command = ContainerCLICommands.runDetachedDocker(
            binary: "/opt/homebrew/bin/container",
            containerID: "crucible-docker",
            settings: DockerSettings(),
            socketPath: "/tmp/crucible-docker.sock",
            dataRootPath: "/tmp/crucible-docker-data"
        )

        #expect(command.arguments.contains("--rosetta"))
    }

    @Test func pullCommandUsesImageSubcommand() {
        let command = ContainerCLICommands.pullImage(binary: "/opt/homebrew/bin/container", image: "docker.io/moby/buildkit:buildx-stable-1")
        #expect(command.arguments == ["image", "pull", "docker.io/moby/buildkit:buildx-stable-1"])
    }

    @Test func systemStartDisablesInteractiveKernelInstall() {
        let command = ContainerCLICommands.systemStart(binary: "/opt/homebrew/bin/container")
        #expect(command.arguments == ["system", "start", "--disable-kernel-install", "--timeout", "30"])
    }
}

struct DockerContainerCLIBackendTests {
    @Test func commandForStartUsesBuilderScopedDockerPaths() async {
        let paths = BuilderStoragePaths(
            appSupportRoot: URL(fileURLWithPath: "/tmp/Crucible", isDirectory: true),
            builderID: "docker"
        )
        let backend = DockerContainerCLIBackend(
            settings: DockerSettings(imageReference: "docker.io/library/docker:27-dind"),
            containerBinaryPath: "/opt/homebrew/bin/container",
            paths: paths
        )

        let command = await backend.commandForStart()

        #expect(command.arguments.contains("/tmp/Crucible/builders/docker/docker.sock:/var/run/docker.sock"))
        #expect(command.arguments.contains("type=bind,source=/tmp/Crucible/builders/docker/docker-data,target=/var/lib/docker"))
    }

    @Test func startsStopped() async {
        let backend = DockerContainerCLIBackend(
            settings: DockerSettings(),
            paths: BuilderStoragePaths(appSupportRoot: URL(fileURLWithPath: "/tmp/Crucible", isDirectory: true), builderID: "docker")
        )

        #expect(await backend.currentState() == .stopped)
    }

    @Test func startValidatesDockerSettingsBeforeRunningContainerCLI() async {
        let backend = DockerContainerCLIBackend(
            settings: DockerSettings(imageReference: ""),
            paths: BuilderStoragePaths(appSupportRoot: URL(fileURLWithPath: "/tmp/Crucible", isDirectory: true), builderID: "docker")
        )

        await #expect(throws: BuildKitBackendError.configurationInvalid(String(describing: [BuilderConfigValidator.Issue.dockerImageReferenceEmpty]))) {
            try await backend.start()
        }
    }

    @Test func pullImageFailsWhenContainerCLIIsMissing() async {
        let backend = DockerContainerCLIBackend(
            settings: DockerSettings(),
            containerBinaryPath: "/missing/container",
            paths: BuilderStoragePaths(appSupportRoot: URL(fileURLWithPath: "/tmp/Crucible", isDirectory: true), builderID: "docker")
        )

        await #expect(throws: BuildKitBackendError.imagePullFailed("configurationInvalid(\"container CLI not found or not executable at /missing/container\")")) {
            try await backend.pullImage()
        }
    }
}

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

    @Test func pullCommandUsesImageSubcommand() {
        let command = ContainerCLICommands.pullImage(binary: "/opt/homebrew/bin/container", image: "docker.io/moby/buildkit:buildx-stable-1")
        #expect(command.arguments == ["image", "pull", "docker.io/moby/buildkit:buildx-stable-1"])
    }

    @Test func systemStartDisablesInteractiveKernelInstall() {
        let command = ContainerCLICommands.systemStart(binary: "/opt/homebrew/bin/container")
        #expect(command.arguments == ["system", "start", "--disable-kernel-install", "--timeout", "30"])
    }
}

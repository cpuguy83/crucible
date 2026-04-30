import Foundation
import GRPCCore
import Testing
@testable import BuildKitCore

@Suite("BuildKitSettingsValidator")
struct SettingsValidatorTests {
    @Test func defaultsAreValid() {
        let s = BuildKitSettings()
        #expect(BuildKitSettingsValidator.validate(s).isEmpty)
    }

    @Test func defaultsEncodeAsEmptyConfiguration() throws {
        let data = try JSONEncoder().encode(BuildKitSettings())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.isEmpty)
    }

    @Test func missingConfigurationKeysDecodeToCurrentDefaults() throws {
        let settings = try JSONDecoder().decode(BuildKitSettings.self, from: Data("{}".utf8))
        #expect(settings == BuildKitSettings())
    }

    @Test func legacyLatestDefaultMigratesToBuildxStableDefault() throws {
        let json = #"{"imageReference":"docker.io/moby/buildkit:latest"}"#
        let settings = try JSONDecoder().decode(BuildKitSettings.self, from: Data(json.utf8))
        #expect(settings.imageReference == BuildKitSettings.defaultImageReference)
    }

    @Test func customImageReferenceStillEncodes() throws {
        var settings = BuildKitSettings()
        settings.imageReference = "docker.io/moby/buildkit:v0.13.2"

        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["imageReference"] as? String == "docker.io/moby/buildkit:v0.13.2")
        #expect(object["cpuCount"] == nil)
    }

    @Test func daemonConfigStillEncodes() throws {
        var settings = BuildKitSettings()
        settings.daemonConfigTOML = "[worker.oci]\n  max-parallelism = 4\n"

        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["daemonConfigTOML"] as? String == "[worker.oci]\n  max-parallelism = 4\n")
    }

    @Test func effectiveDaemonConfigDefaultsToRosettaPlatforms() {
        let config = BuildKitSettings().effectiveDaemonConfigTOML()
        #expect(config.contains(#"platforms = ["linux/arm64", "linux/amd64"]"#))
    }

    @Test func effectiveDaemonConfigInjectsRosettaPlatformsIntoWorkerOCI() {
        var settings = BuildKitSettings()
        settings.daemonConfigTOML = "[worker.oci]\n  max-parallelism = 4\n"

        let config = settings.effectiveDaemonConfigTOML()
        #expect(config.contains("[worker.oci]\n  platforms = [\"linux/arm64\", \"linux/amd64\"]\n  max-parallelism = 4"))
    }

    @Test func effectiveDaemonConfigPreservesExplicitPlatforms() {
        var settings = BuildKitSettings()
        settings.daemonConfigTOML = "[worker.oci]\n  platforms = [\"linux/arm64\"]\n"

        let config = settings.effectiveDaemonConfigTOML()
        #expect(config == settings.daemonConfigTOML)
    }

    @Test func oversizedDaemonConfigRejected() {
        var settings = BuildKitSettings()
        settings.daemonConfigTOML = String(repeating: "x", count: 256 * 1024 + 1)
        #expect(BuildKitSettingsValidator.validate(settings).contains(.daemonConfigTooLarge(256 * 1024 + 1)))
    }

    @Test func malformedDaemonConfigRejected() {
        var settings = BuildKitSettings()
        settings.daemonConfigTOML = "[worker.oci\n  max-parallelism = 4\n"
        #expect(BuildKitSettingsValidator.validate(settings).contains(.daemonConfigMalformed("line 1: section header is missing closing ]")))
    }

    @Test func plausibleDaemonConfigAccepted() {
        var settings = BuildKitSettings()
        settings.daemonConfigTOML = """
        debug = true

        [worker.oci]
          max-parallelism = 4
        """
        #expect(BuildKitSettingsValidator.validate(settings).isEmpty)
    }

    @Test func disabledAutoStartEncodes() throws {
        var settings = BuildKitSettings()
        settings.autoStart = false

        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let autoStart = try #require(object["autoStart"] as? Bool)
        #expect(autoStart == false)
    }

    @Test func containerCLIBackendAccepted() {
        var s = BuildKitSettings()
        s.backend = .containerCLI
        #expect(BuildKitSettingsValidator.validate(s).isEmpty)
    }

    @Test func backendErrorsHaveUserMessages() {
        let message = buildKitUserMessage(for: BuildKitBackendError.daemonStartFailed("mount failed"))
        #expect(message == "Failed to start BuildKit. mount failed")
    }

    @Test func activeBuildMapsBuildHistoryRecord() {
        var record = Moby_Buildkit_V1_BuildHistoryRecord()
        record.ref = "build-123"
        record.frontend = "dockerfile.v0"
        record.frontendAttrs["target"] = "release"
        record.numCompletedSteps = 3
        record.numTotalSteps = 5
        record.numCachedSteps = 2
        record.numWarnings = 1

        let build = ActiveBuild(record: record)

        #expect(build.ref == "build-123")
        #expect(build.frontend == "dockerfile.v0")
        #expect(build.target == "release")
        #expect(build.completedSteps == 3)
        #expect(build.totalSteps == 5)
        #expect(build.cachedSteps == 2)
        #expect(build.warnings == 1)
        #expect(build.frontendAttrs["target"] == "release")
    }

    @Test func recentBuildMapsBuildHistoryRecord() {
        var record = Moby_Buildkit_V1_BuildHistoryRecord()
        record.ref = "build-456"
        record.frontend = "dockerfile.v0"
        record.frontendAttrs["target"] = "debug"
        record.numCompletedSteps = 4
        record.numTotalSteps = 4
        record.numCachedSteps = 1
        record.numWarnings = 2
        record.error.code = 2
        record.error.message = "compile failed"
        record.trace.mediaType = "application/vnd.buildkit.otlp.json.v0"
        record.trace.digest = "sha256:abc123"
        record.trace.size = 42
        record.pinned = true

        let build = RecentBuild(record: record)

        #expect(build.ref == "build-456")
        #expect(build.frontend == "dockerfile.v0")
        #expect(build.target == "debug")
        #expect(build.completedSteps == 4)
        #expect(build.totalSteps == 4)
        #expect(build.cachedSteps == 1)
        #expect(build.warnings == 2)
        #expect(build.errorMessage == "compile failed")
        #expect(build.errorCode == 2)
        #expect(build.frontendAttrs["target"] == "debug")
        #expect(build.trace?.mediaType == "application/vnd.buildkit.otlp.json.v0")
        #expect(build.trace?.digest == "sha256:abc123")
        #expect(build.trace?.size == 42)
        #expect(build.pinned)
        #expect(!build.succeeded)
    }

    @Test func activeBuildStatusDisplayText() {
        #expect(ActiveBuildStatus.notChecked.displayText == "Not checked")
        #expect(ActiveBuildStatus.checking.displayText == "Checking...")
        #expect(ActiveBuildStatus.reconnecting("connection refused").displayText == "Reconnecting: connection refused")
        #expect(ActiveBuildStatus.stopped.displayText == "BuildKit is not running")
        #expect(ActiveBuildStatus.ready(0).displayText == "No active builds")
        #expect(ActiveBuildStatus.ready(2).displayText == "2 active")
        #expect(ActiveBuildStatus.unavailable("socket closed").displayText == "Unavailable: socket closed")
    }

    @Test func recentBuildStatusDisplayText() {
        #expect(RecentBuildsStatus.notChecked.displayText == "Not checked")
        #expect(RecentBuildsStatus.checking.displayText == "Checking...")
        #expect(RecentBuildsStatus.reconnecting("connection refused").displayText == "Reconnecting: connection refused")
        #expect(RecentBuildsStatus.stopped.displayText == "BuildKit is not running")
        #expect(RecentBuildsStatus.ready(0).displayText == "No recent builds")
        #expect(RecentBuildsStatus.ready(3).displayText == "3 recent")
        #expect(RecentBuildsStatus.unavailable("socket closed").displayText == "Unavailable: socket closed")
    }

    @Test func unavailableActiveBuildErrorsAreTransient() {
        #expect(isTransientActiveBuildError(RPCError(code: .unavailable, message: "starting")))
        #expect(!isTransientActiveBuildError(RPCError(code: .unimplemented, message: "missing")))
        #expect(!isTransientActiveBuildError(BuildKitBackendError.daemonStartFailed("boom")))
    }

    @Test func buildStatusMapsToLogLines() {
        var update = Moby_Buildkit_V1_StatusResponse()
        var vertex = Moby_Buildkit_V1_Vertex()
        vertex.name = "load build definition"
        update.vertexes = [vertex]

        var log = Moby_Buildkit_V1_VertexLog()
        log.msg = Data("hello\n".utf8)
        update.logs = [log]

        var warning = Moby_Buildkit_V1_VertexWarning()
        warning.short = Data("deprecated syntax".utf8)
        warning.url = "https://example.invalid/warning"
        update.warnings = [warning]

        let lines = buildLogLines(from: update)

        #expect(lines.map(\.kind) == [.vertex, .log, .warning])
        #expect(lines.map(\.message) == [
            "started: load build definition",
            "hello",
            "warning: deprecated syntax (https://example.invalid/warning)",
        ])
    }

    @Test func emptyImageReferenceRejected() {
        var s = BuildKitSettings()
        s.imageReference = ""
        #expect(BuildKitSettingsValidator.validate(s).contains(.imageReferenceEmpty))
    }

    @Test func imageReferenceWithoutTagOrDigestRejected() {
        var s = BuildKitSettings()
        s.imageReference = "moby/buildkit"
        let issues = BuildKitSettingsValidator.validate(s)
        #expect(issues.contains(.imageReferenceMalformed("moby/buildkit")))
    }

    @Test func digestImageReferenceAccepted() {
        var s = BuildKitSettings()
        s.imageReference = "moby/buildkit@sha256:" + String(repeating: "a", count: 64)
        #expect(BuildKitSettingsValidator.validate(s).isEmpty)
    }

    @Test func relativeSocketPathRejected() {
        var s = BuildKitSettings()
        s.hostSocketPath = "buildkitd.sock"
        let issues = BuildKitSettingsValidator.validate(s)
        #expect(issues.contains(.socketPathNotAbsolute("buildkitd.sock")))
    }

    @Test func cpuCountBoundsEnforced() {
        var s = BuildKitSettings()
        s.cpuCount = 0
        #expect(BuildKitSettingsValidator.validate(s).contains(.cpuCountOutOfRange(0)))
        s.cpuCount = 128
        #expect(BuildKitSettingsValidator.validate(s).contains(.cpuCountOutOfRange(128)))
    }

    @Test func memoryBoundsEnforced() {
        var s = BuildKitSettings()
        s.memoryMiB = 256
        #expect(BuildKitSettingsValidator.validate(s).contains(.memoryOutOfRange(256)))
    }
}

@Suite("AppSettings")
struct AppSettingsTests {
    @Test func defaultsUseSingleCrucibleBuildKitBuilder() {
        let settings = AppSettings()

        #expect(settings.selectedBuilderID == BuilderConfig.defaultBuildKitID)
        #expect(settings.builders.count == 1)
        #expect(settings.selectedBuilder.name == "Crucible")
        #expect(settings.buildxName == BuildxCommands.defaultBuilderName)
        #expect(settings.selectedBuildKitSettings == BuildKitSettings())
    }

    @Test func emptyBuildersFallBackToDefaultBuildKitBuilder() {
        let settings = AppSettings(selectedBuilderID: "missing", builders: [])

        #expect(settings.selectedBuilderID == BuilderConfig.defaultBuildKitID)
        #expect(settings.builders == [.defaultBuildKit])
    }

    @Test func missingSelectedBuilderFallsBackToFirstBuilder() {
        let settings = AppSettings(
            selectedBuilderID: "missing",
            builders: [BuilderConfig.buildKit(id: "custom", name: "Custom", settings: BuildKitSettings())]
        )

        #expect(settings.selectedBuilderID == "custom")
        #expect(settings.selectedBuilder.name == "Custom")
    }

    @Test func migratingLegacySettingsPreservesBuildKitFields() {
        var legacy = BuildKitSettings()
        legacy.backend = .containerCLI
        legacy.imageReference = "docker.io/moby/buildkit:v0.13.2"
        legacy.cpuCount = 8
        legacy.memoryMiB = 8192
        legacy.autoStart = false
        legacy.daemonConfigTOML = "debug = true\n"

        let settings = AppSettings.migrating(legacy)

        #expect(settings.selectedBuilderID == BuilderConfig.defaultBuildKitID)
        #expect(settings.builders.count == 1)
        #expect(settings.selectedBuilder.name == "Crucible")
        #expect(settings.buildxName == BuildxCommands.defaultBuilderName)
        #expect(settings.selectedBuildKitSettings == legacy)
    }

    @Test func buildxNameBelongsToAppSettingsNotSavedBuilders() {
        let settings = AppSettings(buildxName: "crucible-active")

        #expect(settings.buildxName == "crucible-active")
        #expect(settings.selectedBuilder.name == "Crucible")
    }

    @Test func missingBuildxNameDecodesToStableDefault() throws {
        let json = #"{"selectedBuilderID":"crucible","builders":[{"id":"crucible","name":"Crucible","kind":{"type":"buildKit","buildKit":{}}}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(settings.buildxName == BuildxCommands.defaultBuilderName)
    }

    @Test func legacyManagedBuilderKindNamesDecode() throws {
        let json = #"{"selectedBuilderID":"docker","builders":[{"id":"crucible","name":"Crucible","kind":{"type":"managedBuildKit","managedBuildKit":{}}},{"id":"docker","name":"Docker","kind":{"type":"managedDocker","managedDocker":{"imageReference":"docker.io/library/docker:dind"}}}]}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        #expect(settings.selectedBuilder.kind == .docker(DockerSettings()))
    }

    @Test func invalidBuildxNameFallsBackToStableDefault() {
        let settings = AppSettings(buildxName: "bad name; rm -rf")

        #expect(settings.buildxName == BuildxCommands.defaultBuilderName)
    }

    @Test func replacingSelectedBuildKitSettingsUpdatesOnlySelectedBuilder() {
        var replacement = BuildKitSettings()
        replacement.imageReference = "docker.io/moby/buildkit:v0.14.0"

        let other = BuilderConfig(
            id: "docker",
            name: "Docker",
            kind: .docker(DockerSettings())
        )
        let settings = AppSettings(builders: [.defaultBuildKit, other])
            .replacingSelectedBuildKitSettings(replacement)

        #expect(settings.selectedBuildKitSettings == replacement)
        #expect(settings.builders[1] == other)
    }

    @Test func replacingSelectedBuildKitSettingsIgnoresDockerSelection() {
        let docker = BuilderConfig(
            id: "docker",
            name: "Docker",
            kind: .docker(DockerSettings())
        )
        var replacement = BuildKitSettings()
        replacement.imageReference = "docker.io/moby/buildkit:v0.14.0"
        let settings = AppSettings(selectedBuilderID: "docker", builders: [.defaultBuildKit, docker])
            .replacingSelectedBuildKitSettings(replacement)

        #expect(settings.selectedBuilder == docker)
        #expect(settings.builders[0] == .defaultBuildKit)
    }

    @Test func selectedBuildKitBuilderIsBuildKit() {
        let settings = AppSettings()

        #expect(settings.selectedBuilderIsBuildKit)
    }

    @Test func selectingBuilderUpdatesSelectedBuilderID() {
        let docker = BuilderConfig.docker(id: "docker", name: "Docker")
        let settings = AppSettings(builders: [.defaultBuildKit, docker])
            .selectingBuilder(id: "docker")

        #expect(settings.selectedBuilder == docker)
        #expect(settings.selectedDockerSettings == DockerSettings())
    }

    @Test func upsertingBuilderAddsAndCanSelectBuilder() {
        let docker = BuilderConfig.docker(id: "docker", name: "Docker")
        let settings = AppSettings().upsertingBuilder(docker, select: true)

        #expect(settings.builders == [.defaultBuildKit, docker])
        #expect(settings.selectedBuilder == docker)
    }

    @Test func renamingBuilderUpdatesNameOnly() {
        let docker = BuilderConfig.docker(id: "docker", name: "Docker")
        let settings = AppSettings(selectedBuilderID: "docker", builders: [.defaultBuildKit, docker])
            .renamingBuilder(id: "docker", name: " Local Docker ")

        #expect(settings.selectedBuilder.name == "Local Docker")
        #expect(settings.builders[0] == .defaultBuildKit)
    }

    @Test func removingBuilderFallsBackSelectionWhenNeeded() {
        let docker = BuilderConfig.docker(id: "docker", name: "Docker")
        let settings = AppSettings(selectedBuilderID: "docker", builders: [.defaultBuildKit, docker])
            .removingBuilder(id: "docker")

        #expect(settings.builders == [.defaultBuildKit])
        #expect(settings.selectedBuilder == .defaultBuildKit)
    }

    @Test func builderKindCasesRoundTripThroughJSON() throws {
        let settings = AppSettings(
            selectedBuilderID: "docker",
            builders: [
                .defaultBuildKit,
                BuilderConfig(
                    id: "docker",
                    name: "Docker",
                    kind: .docker(DockerSettings(
                        imageReference: "docker.io/library/docker:27-dind",
                        initfsReference: "ghcr.io/apple/containerization/vminit:0.31.0",
                        cpuCount: 6,
                        memoryMiB: 8192,
                        kernelOverridePath: "/tmp/vmlinux",
                        autoStart: true,
                        transportMode: .directH2C,
                        daemonConfigJSON: #"{"debug":true}"#
                    ))
                ),
            ]
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(decoded == settings)
    }
}

@Suite("BuilderConfigValidator")
struct BuilderConfigValidatorTests {
    @Test func buildKitValidationReusesBuildKitSettingsValidation() {
        var settings = BuildKitSettings()
        settings.imageReference = ""
        let builder = BuilderConfig.buildKit(id: "buildkit", name: "BuildKit", settings: settings)

        #expect(BuilderConfigValidator.validate(builder) == [.buildKit(.imageReferenceEmpty)])
    }

    @Test func dockerDefaultsAreValid() {
        #expect(BuilderConfigValidator.validate(DockerSettings()).isEmpty)
    }

    @Test func dockerImageReferenceMustNotBeEmpty() {
        let settings = DockerSettings(imageReference: "")

        #expect(BuilderConfigValidator.validate(settings) == [.dockerImageReferenceEmpty])
    }

    @Test func dockerImageReferenceMustIncludeTagOrDigest() {
        let settings = DockerSettings(imageReference: "docker.io/library/docker")

        #expect(BuilderConfigValidator.validate(settings) == [.dockerImageReferenceMalformed("docker.io/library/docker")])
    }

    @Test func dockerDigestImageReferenceIsValid() {
        let settings = DockerSettings(imageReference: "docker.io/library/docker@sha256:" + String(repeating: "a", count: 64))

        #expect(BuilderConfigValidator.validate(settings).isEmpty)
    }

    @Test func dockerDaemonConfigMustBeJSONObject() {
        let settings = DockerSettings(daemonConfigJSON: #"["not", "object"]"#)

        #expect(BuilderConfigValidator.validate(settings).contains(.dockerDaemonConfigMalformed("top-level value must be a JSON object")))
    }

    @Test func dockerDaemonConfigAcceptsValidJSONObject() {
        let settings = DockerSettings(daemonConfigJSON: #"{"debug":true}"#)

        #expect(BuilderConfigValidator.validate(settings).isEmpty)
    }

    @Test func dockerResourcesAreValidated() {
        let settings = DockerSettings(cpuCount: 0, memoryMiB: 128)

        #expect(BuilderConfigValidator.validate(settings).contains(.dockerCPUCountOutOfRange(0)))
        #expect(BuilderConfigValidator.validate(settings).contains(.dockerMemoryOutOfRange(128)))
    }

    @Test func dockerInitfsReferenceMustBePlausibleImageReference() {
        let settings = DockerSettings(initfsReference: "ghcr.io/apple/containerization/vminit")

        #expect(BuilderConfigValidator.validate(settings).contains(.dockerInitfsReferenceMalformed("ghcr.io/apple/containerization/vminit")))
    }
}

@Suite("BuilderStoragePaths")
struct BuilderStoragePathsTests {
    private let root = URL(fileURLWithPath: "/tmp/Crucible", isDirectory: true)

    @Test func defaultBuildKitBuilderPreservesLegacyRootPaths() {
        let paths = BuilderStoragePaths(appSupportRoot: root)

        #expect(paths.root.path == "/tmp/Crucible")
        #expect(paths.buildKitSocketURL.path == "/tmp/Crucible/buildkitd.sock")
        #expect(paths.buildKitStateImageURL.path == "/tmp/Crucible/buildkit-state.ext4")
        #expect(paths.buildKitDaemonConfigURL.path == "/tmp/Crucible/buildkitd.toml")
    }

    @Test func additionalBuildersUseNamespacedPaths() {
        let paths = BuilderStoragePaths(appSupportRoot: root, builderID: "docker")

        #expect(paths.root.path == "/tmp/Crucible/builders/docker")
        #expect(paths.buildKitSocketURL.path == "/tmp/Crucible/builders/docker/buildkitd.sock")
        #expect(paths.buildKitStateImageURL.path == "/tmp/Crucible/builders/docker/buildkit-state.ext4")
        #expect(paths.buildKitDaemonConfigURL.path == "/tmp/Crucible/builders/docker/buildkitd.toml")
        #expect(paths.dockerSocketURL.path == "/tmp/Crucible/builders/docker/docker.sock")
        #expect(paths.dockerDataRootURL.path == "/tmp/Crucible/builders/docker/docker-data")
        #expect(paths.dockerDataImageURL.path == "/tmp/Crucible/builders/docker/docker-data.ext4")
        #expect(paths.dockerDataImageVersionURL.path == "/tmp/Crucible/builders/docker/docker-data.version")
        #expect(paths.dockerDaemonConfigURL.path == "/tmp/Crucible/builders/docker/daemon.json")
    }

    @Test func defaultBuildKitSocketMatchesSettingsDefault() {
        #expect(BuildKitSettings.defaultHostSocketPath() == BuilderStoragePaths().buildKitSocketURL.path)
    }
}

@Suite("BuildKitSupervisor")
struct SupervisorTests {
    @Test func startUsesStubBackendAndReportsRunning() async throws {
        let settings = BuildKitSettings()
        let supervisor = BuildKitSupervisor(settings: settings) { s in
            StubBackend(settings: s)
        }
        try await supervisor.start()
        let state = await supervisor.currentState()
        if case .running = state { } else {
            Issue.record("expected .running, got \(state)")
        }
    }

    @Test func updateSettingsValidates() async throws {
        let supervisor = BuildKitSupervisor(settings: BuildKitSettings()) { s in
            StubBackend(settings: s)
        }
        var bad = BuildKitSettings()
        bad.imageReference = ""
        await #expect(throws: BuildKitBackendError.self) {
            try await supervisor.updateSettings(bad)
        }
    }
}

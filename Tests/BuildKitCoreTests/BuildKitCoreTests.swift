import Foundation
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

    @Test func disabledAutoStartEncodes() throws {
        var settings = BuildKitSettings()
        settings.autoStart = false

        let data = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let autoStart = try #require(object["autoStart"] as? Bool)
        #expect(autoStart == false)
    }

    @Test func containerCLIBackendRejectedUntilImplemented() {
        var s = BuildKitSettings()
        s.backend = .containerCLI
        #expect(BuildKitSettingsValidator.validate(s).contains(.backendUnavailable(.containerCLI)))
    }

    @Test func backendErrorsHaveUserMessages() {
        let message = buildKitUserMessage(for: BuildKitBackendError.daemonStartFailed("mount failed"))
        #expect(message == "Failed to start BuildKit. mount failed")
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

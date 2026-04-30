import Foundation

/// Backend-agnostic configuration for a BuildKit instance.
///
/// Persisted by the app as JSON under
/// `~/Library/Application Support/Crucible/settings.json`.
public struct BuildKitSettings: Sendable, Equatable, Codable {
    public static let defaultImageReference = "docker.io/moby/buildkit:buildx-stable-1"
    public static let legacyDefaultImageReference = "docker.io/moby/buildkit:latest"
    public static let rosettaWorkerPlatformsTOML = "platforms = [\"linux/arm64\", \"linux/amd64\"]"
    public static let exampleDaemonConfigTOML = """
    # BuildKit daemon configuration mounted at /etc/buildkit/buildkitd.toml.
    debug = false

    [worker.oci]
      platforms = ["linux/arm64", "linux/amd64"]
      max-parallelism = 4
      gc = true

      [[worker.oci.gcpolicy]]
        keepBytes = 21474836480
        keepDuration = "168h"
    """

    /// Which backend implementation to use.
    public enum BackendKind: String, Sendable, Codable, CaseIterable {
        /// Default. Links apple/containerization directly.
        case containerization
        /// Opt-in. Shells out to the `container` CLI.
        case containerCLI
    }

    public var backend: BackendKind

    /// OCI image reference for buildkitd. Accepts `repo:tag` or `repo@sha256:...`.
    /// User-overridable. Validated at save time.
    public var imageReference: String

    /// OCI image reference for the guest init filesystem (vminitd + runc).
    /// Pulled by the framework on first boot; cached thereafter.
    public var initfsReference: String

    /// Host filesystem path where the buildkitd unix socket will be exposed.
    public var hostSocketPath: String

    /// vCPU count for the container's VM.
    public var cpuCount: Int

    /// Memory in MiB for the container's VM.
    public var memoryMiB: Int

    /// Optional override path for the Linux kernel binary. When nil, the
    /// backend discovers a kernel from the apple/container CLI install
    /// directory (`~/Library/Application Support/com.apple.container/kernels/`).
    public var kernelOverridePath: String?

    /// Whether the daemon should auto-start when the app launches / on login.
    public var autoStart: Bool

    /// Optional buildkitd TOML configuration. When empty, buildkitd starts
    /// with its image defaults.
    public var daemonConfigTOML: String

    public init(
        backend: BackendKind = .containerization,
        imageReference: String = BuildKitSettings.defaultImageReference,
        initfsReference: String = "ghcr.io/apple/containerization/vminit:0.31.0",
        hostSocketPath: String = BuildKitSettings.defaultHostSocketPath(),
        cpuCount: Int = 4,
        memoryMiB: Int = 4096,
        kernelOverridePath: String? = nil,
        autoStart: Bool = true,
        daemonConfigTOML: String = ""
    ) {
        self.backend = backend
        self.imageReference = imageReference == Self.legacyDefaultImageReference ? Self.defaultImageReference : imageReference
        self.initfsReference = initfsReference
        self.hostSocketPath = hostSocketPath
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.kernelOverridePath = kernelOverridePath
        self.autoStart = autoStart
        self.daemonConfigTOML = daemonConfigTOML
    }

    private enum CodingKeys: String, CodingKey {
        case backend
        case imageReference
        case initfsReference
        case hostSocketPath
        case cpuCount
        case memoryMiB
        case kernelOverridePath
        case autoStart
        case daemonConfigTOML
    }

    public init(from decoder: Decoder) throws {
        let defaults = BuildKitSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedImageReference = try c.decodeIfPresent(String.self, forKey: .imageReference) ?? defaults.imageReference
        self.init(
            backend: try c.decodeIfPresent(BackendKind.self, forKey: .backend) ?? defaults.backend,
            imageReference: decodedImageReference,
            initfsReference: try c.decodeIfPresent(String.self, forKey: .initfsReference) ?? defaults.initfsReference,
            hostSocketPath: try c.decodeIfPresent(String.self, forKey: .hostSocketPath) ?? defaults.hostSocketPath,
            cpuCount: try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? defaults.cpuCount,
            memoryMiB: try c.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? defaults.memoryMiB,
            kernelOverridePath: try c.decodeIfPresent(String.self, forKey: .kernelOverridePath) ?? defaults.kernelOverridePath,
            autoStart: try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? defaults.autoStart,
            daemonConfigTOML: try c.decodeIfPresent(String.self, forKey: .daemonConfigTOML) ?? defaults.daemonConfigTOML
        )
    }

    public func encode(to encoder: Encoder) throws {
        let defaults = BuildKitSettings()
        var c = encoder.container(keyedBy: CodingKeys.self)

        if backend != defaults.backend { try c.encode(backend, forKey: .backend) }
        if imageReference != defaults.imageReference { try c.encode(imageReference, forKey: .imageReference) }
        if initfsReference != defaults.initfsReference { try c.encode(initfsReference, forKey: .initfsReference) }
        if hostSocketPath != defaults.hostSocketPath { try c.encode(hostSocketPath, forKey: .hostSocketPath) }
        if cpuCount != defaults.cpuCount { try c.encode(cpuCount, forKey: .cpuCount) }
        if memoryMiB != defaults.memoryMiB { try c.encode(memoryMiB, forKey: .memoryMiB) }
        if kernelOverridePath != defaults.kernelOverridePath { try c.encode(kernelOverridePath, forKey: .kernelOverridePath) }
        if autoStart != defaults.autoStart { try c.encode(autoStart, forKey: .autoStart) }
        if daemonConfigTOML != defaults.daemonConfigTOML { try c.encode(daemonConfigTOML, forKey: .daemonConfigTOML) }
    }

    public static func defaultHostSocketPath() -> String {
        BuilderStoragePaths().buildKitSocketURL.path
    }

    public func effectiveDaemonConfigTOML() -> String {
        Self.daemonConfigWithRosettaPlatforms(daemonConfigTOML)
    }

    public static func daemonConfigWithRosettaPlatforms(_ config: String) -> String {
        let trimmed = config.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return """
            [worker.oci]
              \(rosettaWorkerPlatformsTOML)
            """
        }
        guard !workerOCISectionDefinesPlatforms(trimmed) else { return config }

        var lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let workerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[worker.oci]" }) {
            lines.insert("  \(rosettaWorkerPlatformsTOML)", at: workerIndex + 1)
            return lines.joined(separator: "\n")
        }

        let separator = config.hasSuffix("\n") || config.isEmpty ? "" : "\n\n"
        return config + separator + """
        [worker.oci]
          \(rosettaWorkerPlatformsTOML)
        """
    }

    private static func workerOCISectionDefinesPlatforms(_ config: String) -> Bool {
        var inWorkerOCI = false
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inWorkerOCI = line == "[worker.oci]"
                continue
            }
            if inWorkerOCI && line.hasPrefix("platforms") {
                return true
            }
        }
        return false
    }
}

import Foundation

/// Backend-agnostic configuration for a BuildKit instance.
///
/// Persisted by the app as JSON under
/// `~/Library/Application Support/Crucible/settings.json`.
public struct BuildKitSettings: Sendable, Equatable, Codable {
    public static let defaultImageReference = "docker.io/moby/buildkit:buildx-stable-1"
    public static let legacyDefaultImageReference = "docker.io/moby/buildkit:latest"
    public static let rosettaWorkerPlatformsTOML = "platforms = [\"linux/arm64\", \"linux/amd64\"]"

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

    /// Where the Linux kernel comes from. Defaults to ``KernelSource/auto``,
    /// which discovers a kernel from Crucible's cache, the apple/container CLI
    /// install directory, then a Kata Containers download.
    public var kernelSource: KernelSource

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
        kernelSource: KernelSource = .auto,
        autoStart: Bool = true,
        daemonConfigTOML: String = ""
    ) {
        self.backend = backend
        self.imageReference = imageReference == Self.legacyDefaultImageReference ? Self.defaultImageReference : imageReference
        self.initfsReference = initfsReference
        self.hostSocketPath = hostSocketPath
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.kernelSource = kernelSource
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
        case kernelSource
        /// Legacy field, decoded for backward compatibility and migrated into
        /// ``kernelSource``. Never encoded.
        case kernelOverridePath
        case autoStart
        case daemonConfigTOML
    }

    public init(from decoder: Decoder) throws {
        let defaults = BuildKitSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedImageReference = try c.decodeIfPresent(String.self, forKey: .imageReference) ?? defaults.imageReference
        let kernelSource: KernelSource
        if let decoded = try c.decodeIfPresent(KernelSource.self, forKey: .kernelSource) {
            kernelSource = decoded
        } else {
            // Migrate the legacy `kernelOverridePath` field if present.
            kernelSource = .fromLegacyOverridePath(
                try c.decodeIfPresent(String.self, forKey: .kernelOverridePath)
            )
        }
        self.init(
            backend: try c.decodeIfPresent(BackendKind.self, forKey: .backend) ?? defaults.backend,
            imageReference: decodedImageReference,
            initfsReference: try c.decodeIfPresent(String.self, forKey: .initfsReference) ?? defaults.initfsReference,
            hostSocketPath: try c.decodeIfPresent(String.self, forKey: .hostSocketPath) ?? defaults.hostSocketPath,
            cpuCount: try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? defaults.cpuCount,
            memoryMiB: try c.decodeIfPresent(Int.self, forKey: .memoryMiB) ?? defaults.memoryMiB,
            kernelSource: kernelSource,
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
        if kernelSource != defaults.kernelSource { try c.encode(kernelSource, forKey: .kernelSource) }
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

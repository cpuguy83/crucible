import Foundation

/// Backend-agnostic configuration for a BuildKit instance.
///
/// Persisted by the app as JSON under
/// `~/Library/Application Support/Crucible/settings.json`.
public struct BuildKitSettings: Sendable, Equatable, Codable {
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

    public init(
        backend: BackendKind = .containerization,
        imageReference: String = "docker.io/moby/buildkit:latest",
        initfsReference: String = "ghcr.io/apple/containerization/vminit:0.31.0",
        hostSocketPath: String = BuildKitSettings.defaultHostSocketPath(),
        cpuCount: Int = 4,
        memoryMiB: Int = 4096,
        kernelOverridePath: String? = nil,
        autoStart: Bool = false
    ) {
        self.backend = backend
        self.imageReference = imageReference
        self.initfsReference = initfsReference
        self.hostSocketPath = hostSocketPath
        self.cpuCount = cpuCount
        self.memoryMiB = memoryMiB
        self.kernelOverridePath = kernelOverridePath
        self.autoStart = autoStart
    }

    public static func defaultHostSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Crucible/buildkitd.sock"
    }
}

import Foundation

/// Describes where the Linux kernel used to boot the guest VM comes from.
///
/// - ``auto``: Discover a kernel automatically (Crucible's download cache, the
///   `apple/container` CLI install directory, then a Kata Containers download).
///   This is the default and preserves Crucible's historical behavior.
/// - ``overridePath``: Use a specific `vmlinux` binary file on disk.
/// - ``registryImage``: Pull a kernel OCI image from a registry and extract the
///   kernel for the host platform. With no `subpath`, the image is treated as an
///   Apple-format kernel image (`application/vnd.apple.containerization.kernel`),
///   whose single layer blob is the kernel binary. With a `subpath`, the image is
///   treated as a standard OCI image and the kernel is read from that path inside
///   its root filesystem (e.g. `/boot/vmlinux`).
public enum KernelSource: Sendable, Equatable, Codable {
    case auto
    case overridePath(String)
    case registryImage(reference: String, subpath: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case path
        case reference
        case subpath
    }

    private enum Kind: String, Codable {
        case auto
        case overridePath
        case registryImage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .auto:
            self = .auto
        case .overridePath:
            self = .overridePath(try c.decode(String.self, forKey: .path))
        case .registryImage:
            let reference = try c.decode(String.self, forKey: .reference)
            let subpath = try c.decodeIfPresent(String.self, forKey: .subpath)
            self = .registryImage(reference: reference, subpath: subpath)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try c.encode(Kind.auto, forKey: .type)
        case .overridePath(let path):
            try c.encode(Kind.overridePath, forKey: .type)
            try c.encode(path, forKey: .path)
        case .registryImage(let reference, let subpath):
            try c.encode(Kind.registryImage, forKey: .type)
            try c.encode(reference, forKey: .reference)
            try c.encodeIfPresent(subpath, forKey: .subpath)
        }
    }

    /// The explicit `vmlinux` path, if this source is ``overridePath``.
    public var overridePath: String? {
        if case .overridePath(let path) = self { return path }
        return nil
    }

    /// The kernel OCI image reference, if this source is ``registryImage``.
    public var registryImageReference: String? {
        if case .registryImage(let reference, _) = self { return reference }
        return nil
    }

    /// The path to the kernel inside the image's root filesystem, if this source
    /// is ``registryImage`` and a subpath was provided. A `nil` (or absent)
    /// subpath means the image is an Apple-format kernel image.
    public var registryImageSubpath: String? {
        if case .registryImage(_, let subpath) = self { return subpath }
        return nil
    }

    public var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    /// Builds a ``KernelSource`` from a legacy optional override path.
    /// A nil or empty path maps to ``auto``.
    public static func fromLegacyOverridePath(_ path: String?) -> KernelSource {
        guard let path, !path.isEmpty else { return .auto }
        return .overridePath(path)
    }
}

import Foundation
import BuildKitCore
@preconcurrency import Containerization

/// Locates a Linux kernel binary suitable for booting via apple/containerization.
///
/// Resolution depends on ``BuildKitSettings/kernelSource``:
/// - ``KernelSource/overridePath``: use the given `vmlinux` file directly.
/// - ``KernelSource/registryImage``: pull an Apple-format kernel OCI image and
///   extract the kernel for the host platform (requires an ``ImageStore``).
/// - ``KernelSource/auto``: discover a kernel from, in order, Crucible's
///   download cache, the `apple/container` CLI install directory, then a fresh
///   download of Kata Containers' static release — the same source used by
///   `apple/containerization`'s `make fetch-default-kernel` target.
public enum KernelLocator {
    public enum Error: Swift.Error, CustomStringConvertible {
        case overrideMissing(String)
        case noKernelAvailable
        case imageStoreUnavailable
        case registryImageRequiresStart

        public var description: String {
            switch self {
            case .overrideMissing(let path):
                return "Kernel override path does not exist: \(path)"
            case .noKernelAvailable:
                return """
                No Linux kernel found locally and a fresh download was not attempted.
                Either set a kernel override path in Crucible's Settings, install \
                Apple's `container` CLI from https://github.com/apple/container and \
                run `container system start` once, or call locateOrDownload.
                """
            case .imageStoreUnavailable:
                return "A kernel image reference is configured but no image store was provided to resolve it."
            case .registryImageRequiresStart:
                return "A kernel image reference is configured; it is resolved when the builder starts."
            }
        }
    }

    /// Default search directory for kernels installed by the `container` CLI.
    public static func appleContainerKernelDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/com.apple.container/kernels", isDirectory: true)
    }

    /// Where Crucible caches its own downloaded kernels.
    public static func crucibleKernelCacheDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Crucible/kernels", isDirectory: true)
    }

    /// Synchronous resolution. Handles ``KernelSource/overridePath`` and the
    /// local tiers of ``KernelSource/auto``. Throws for
    /// ``KernelSource/registryImage`` (which requires async network I/O) and
    /// when no local kernel is available.
    public static func locate(settings: BuildKitSettings) throws -> URL {
        switch settings.kernelSource {
        case .overridePath(let path):
            return try resolveOverride(path)
        case .registryImage:
            throw Error.registryImageRequiresStart
        case .auto:
            if let url = locateAuto() {
                return url
            }
            throw Error.noKernelAvailable
        }
    }

    /// Full resolution. Resolves the configured ``KernelSource``, downloading or
    /// pulling as needed. Progress events are forwarded for the Kata download
    /// case only.
    public static func locateOrDownload(
        settings: BuildKitSettings,
        imageStore: ImageStore? = nil,
        progress: (@Sendable (KernelDownloader.Progress) -> Void)? = nil
    ) async throws -> URL {
        switch settings.kernelSource {
        case .overridePath(let path):
            return try resolveOverride(path)
        case .registryImage(let reference, let subpath):
            guard let imageStore else {
                throw Error.imageStoreUnavailable
            }
            return try await KernelImageResolver.resolve(reference: reference, subpath: subpath, imageStore: imageStore)
        case .auto:
            if let url = locateAuto() {
                return url
            }
            let downloader = KernelDownloader(cacheDirectory: crucibleKernelCacheDirectory())
            return try await downloader.ensureKernel(progress: progress)
        }
    }

    // MARK: - Internals

    /// Verify and return an explicit override path.
    static func resolveOverride(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.overrideMissing(path)
        }
        return url
    }

    /// Local-disk tiers of ``KernelSource/auto``: Crucible cache, then the
    /// `apple/container` CLI install directory. Returns nil if neither has a
    /// candidate.
    static func locateAuto() -> URL? {
        if let cached = newestVmlinux(in: crucibleKernelCacheDirectory()) {
            return cached
        }
        if let cli = newestVmlinux(in: appleContainerKernelDirectory()) {
            return cli
        }
        return nil
    }

    /// Pick the newest file matching `vmlinux*` in `dir` by mtime.
    /// Returns nil if the directory doesn't exist or has no candidates.
    static func newestVmlinux(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = entries.filter { $0.lastPathComponent.hasPrefix("vmlinux") }
        guard !candidates.isEmpty else { return nil }

        return candidates.sorted { lhs, rhs in
            let ldate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rdate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ldate > rdate
        }.first
    }
}

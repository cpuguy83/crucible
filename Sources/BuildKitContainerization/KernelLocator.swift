import Foundation
import BuildKitCore

/// Locates a Linux kernel binary suitable for booting via apple/containerization.
///
/// Resolution order (first hit wins):
/// 1. Explicit override path from `BuildKitSettings.kernelOverridePath`.
/// 2. Cached download from a prior run (under
///    `~/Library/Application Support/Crucible/kernels/`).
/// 3. Newest `vmlinux-*` under
///    `~/Library/Application Support/com.apple.container/kernels/`,
///    populated by the `apple/container` CLI.
/// 4. Fresh download from Kata Containers' static release — the same source
///    used by `apple/containerization`'s `make fetch-default-kernel` target.
///
/// The first three paths are synchronous; the fourth requires network I/O
/// and so is exposed via ``locateOrDownload``.
public enum KernelLocator {
    public enum Error: Swift.Error, CustomStringConvertible {
        case overrideMissing(String)
        case noKernelAvailable

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

    /// Synchronous resolution: paths 1-3 only. Throws ``Error.noKernelAvailable``
    /// if no kernel exists locally.
    public static func locate(settings: BuildKitSettings) throws -> URL {
        if let url = try locateLocal(settings: settings) {
            return url
        }
        throw Error.noKernelAvailable
    }

    /// Full resolution: tries paths 1-3, falling back to a Kata download if
    /// no local kernel exists. Progress events are forwarded for the
    /// download case.
    public static func locateOrDownload(
        settings: BuildKitSettings,
        progress: (@Sendable (KernelDownloader.Progress) -> Void)? = nil
    ) async throws -> URL {
        if let url = try locateLocal(settings: settings) {
            return url
        }
        let downloader = KernelDownloader(cacheDirectory: crucibleKernelCacheDirectory())
        return try await downloader.ensureKernel(progress: progress)
    }

    // MARK: - Internals

    /// Try paths 1-3 in order. Returns nil if nothing local is available.
    /// Throws only if an explicit override is set but missing.
    static func locateLocal(settings: BuildKitSettings) throws -> URL? {
        if let override = settings.kernelOverridePath {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Error.overrideMissing(override)
            }
            return url
        }
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

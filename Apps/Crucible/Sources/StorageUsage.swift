import Foundation

struct StorageUsage: Sendable, Equatable {
    struct Area: Sendable, Equatable, Identifiable {
        var id: String { path }
        var name: String
        var path: String
        var bytes: Int64?
        var detail: String

        var sizeText: String {
            bytes.map(StorageUsage.format) ?? "Not created"
        }
    }

    var appSupportPath: String
    var stateImagePath: String
    var stateImageVirtualBytes: Int64?
    var stateImageAllocatedBytes: Int64?
    var areas: [Area]

    var displayText: String {
        guard let allocated = stateImageAllocatedBytes,
              let virtual = stateImageVirtualBytes else {
            return "State image: not created"
        }
        return "State image: \(Self.format(allocated)) on disk / \(Self.format(virtual)) capacity"
    }

    var stateImageCapacityText: String {
        stateImageVirtualBytes.map(Self.format) ?? "Not created"
    }

    var stateImageAllocatedText: String {
        stateImageAllocatedBytes.map(Self.format) ?? "Not created"
    }

    static func current() -> StorageUsage {
        let base = appSupportDirectory()
        let state = base.appendingPathComponent("buildkit-state.ext4")
        let content = base.appendingPathComponent("content", isDirectory: true)
        let containers = base.appendingPathComponent("containers", isDirectory: true)
        let kernels = base.appendingPathComponent("kernels", isDirectory: true)
        let initfs = base.appendingPathComponent("initfs.ext4")
        let daemonConfig = Self.daemonConfigURL()

        let stateSizes = fileSizes(at: state)

        return StorageUsage(
            appSupportPath: base.path,
            stateImagePath: state.path,
            stateImageVirtualBytes: stateSizes?.logical,
            stateImageAllocatedBytes: stateSizes?.allocated,
            areas: [
                Area(
                    name: "BuildKit state image",
                    path: state.path,
                    bytes: stateSizes?.allocated,
                    detail: "Persistent ext4 disk mounted at /var/lib/buildkit. Contains cache records, content, snapshots, and build metadata."
                ),
                Area(
                    name: "OCI content store",
                    path: content.path,
                    bytes: directoryAllocatedSize(content),
                    detail: "Pulled OCI image blobs for moby/buildkit and vminit. Safe to delete only while Crucible is stopped; images will re-pull."
                ),
                Area(
                    name: "Container rootfs workspace",
                    path: containers.path,
                    bytes: directoryAllocatedSize(containers),
                    detail: "Ephemeral per-start rootfs and writable layers. Crucible removes stale contents on start/stop."
                ),
                Area(
                    name: "Kernel cache",
                    path: kernels.path,
                    bytes: directoryAllocatedSize(kernels),
                    detail: "Downloaded Kata kernel tarball and extracted vmlinux used by Virtualization.framework."
                ),
                Area(
                    name: "Init filesystem",
                    path: initfs.path,
                    bytes: fileSizes(at: initfs)?.allocated,
                    detail: "vminitd/initfs ext4 image used to start and manage the guest VM."
                ),
                Area(
                    name: "BuildKit daemon config",
                    path: daemonConfig.path,
                    bytes: fileSizes(at: daemonConfig)?.allocated,
                    detail: "Generated buildkitd.toml mounted read-only into the guest when custom daemon config is set."
                ),
            ]
        )
    }

    static func appSupportDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Crucible", isDirectory: true)
    }

    static func daemonConfigURL() -> URL {
        appSupportDirectory().appendingPathComponent("buildkitd.toml")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func fileSizes(at url: URL) -> (logical: Int64, allocated: Int64)? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
        ]), let size = values.fileSize else { return nil }
        return (Int64(size), Int64(values.totalFileAllocatedSize ?? size))
    }

    private static func directoryAllocatedSize(_ url: URL) -> Int64? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

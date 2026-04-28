import Foundation

struct StorageUsage: Sendable, Equatable {
    var virtualBytes: Int64
    var allocatedBytes: Int64

    var displayText: String {
        "State image: \(Self.format(allocatedBytes)) on disk / \(Self.format(virtualBytes)) capacity"
    }

    static func current() -> StorageUsage? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Crucible", isDirectory: true)
        let url = base.appendingPathComponent("buildkit-state.ext4")
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
        ]), let size = values.fileSize else { return nil }

        return StorageUsage(
            virtualBytes: Int64(size),
            allocatedBytes: Int64(values.totalFileAllocatedSize ?? size)
        )
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

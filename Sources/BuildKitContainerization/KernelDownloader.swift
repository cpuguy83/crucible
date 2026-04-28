import Foundation
import BuildKitCore
import ContainerizationArchive
import CryptoKit

/// Downloads, verifies, and extracts a Linux kernel binary from the Kata
/// Containers static release tarball — the same source used by
/// `apple/containerization`'s `make fetch-default-kernel` target.
///
/// The downloaded `vmlinux` is cached at a stable path keyed by the source
/// URL's content hash, so subsequent calls with the same source are no-ops.
public actor KernelDownloader {
    /// Pinned source matching apple/containerization's Makefile
    /// (`KATA_BINARY_PACKAGE`). Bumping this is a deliberate change.
    public static let defaultSourceURL = URL(string:
        "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
    )!

    /// SHA256 of `defaultSourceURL`. Kata does not publish a checksum file for
    /// this release asset, so keep this pinned with the URL.
    public static let defaultSourceSHA256 = "647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181"

    /// Path within the tarball that holds the kernel binary.
    public static let defaultMemberPath = "opt/kata/share/kata-containers/vmlinux.container"

    public enum Error: Swift.Error, CustomStringConvertible {
        case downloadFailed(URL, underlying: Swift.Error)
        case httpStatus(Int, URL)
        case checksumMismatch(URL, expected: String, actual: String)
        case extractFailed(member: String, underlying: Swift.Error)
        case writeFailed(URL, underlying: Swift.Error)

        public var description: String {
            switch self {
            case .downloadFailed(let u, let e):
                return "Failed to download kernel from \(u.absoluteString): \(e)"
            case .httpStatus(let s, let u):
                return "Kernel download HTTP \(s) from \(u.absoluteString)"
            case .checksumMismatch(let u, let expected, let actual):
                return "Kernel download checksum mismatch for \(u.lastPathComponent): expected \(expected), got \(actual)"
            case .extractFailed(let m, let e):
                return "Failed to extract \(m) from kernel tarball: \(e)"
            case .writeFailed(let u, let e):
                return "Failed to write kernel to \(u.path): \(e)"
            }
        }
    }

    public struct Progress: Sendable {
        public enum Phase: Sendable { case downloading, extracting, done }
        public var phase: Phase
        public var bytesReceived: Int64
        public var bytesExpected: Int64?
    }

    private let cacheDirectory: URL
    private let sourceURL: URL
    private let memberPath: String
    private let expectedSHA256: String?

    public init(
        cacheDirectory: URL,
        sourceURL: URL = KernelDownloader.defaultSourceURL,
        memberPath: String = KernelDownloader.defaultMemberPath,
        expectedSHA256: String? = KernelDownloader.defaultSourceSHA256
    ) {
        self.cacheDirectory = cacheDirectory
        self.sourceURL = sourceURL
        self.memberPath = memberPath
        self.expectedSHA256 = expectedSHA256
    }

    /// Returns a path to a cached `vmlinux` binary, downloading and
    /// extracting from the Kata tarball on cache miss.
    public func ensureKernel(
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        let kernelURL = cachedKernelURL
        if FileManager.default.fileExists(atPath: kernelURL.path) {
            progress?(.init(phase: .done, bytesReceived: 0, bytesExpected: nil))
            return kernelURL
        }

        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )

        let tarURL = try await downloadTarball(progress: progress)

        progress?(.init(phase: .extracting, bytesReceived: 0, bytesExpected: nil))
        try extractKernel(from: tarURL, to: kernelURL)

        progress?(.init(phase: .done, bytesReceived: 0, bytesExpected: nil))
        return kernelURL
    }

    /// Stable on-disk location for the extracted kernel. Keyed by a hash of
    /// (source URL + member path) so changing either invalidates the cache.
    var cachedKernelURL: URL {
        var hasher = SHA256()
        hasher.update(data: Data(sourceURL.absoluteString.utf8))
        hasher.update(data: Data(memberPath.utf8))
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return cacheDirectory.appendingPathComponent("vmlinux-\(hex)")
    }

    // MARK: - Internals

    private func downloadTarball(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> URL {
        let dest = cacheDirectory.appendingPathComponent("kernel-source.tar.xz")
        if FileManager.default.fileExists(atPath: dest.path) {
            try verifyChecksum(of: dest)
            return dest
        }

        let session = URLSession(configuration: .ephemeral)
        let req = URLRequest(url: sourceURL)
        do {
            let (asyncBytes, response) = try await session.bytes(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Error.httpStatus(http.statusCode, sourceURL)
            }
            let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil

            // Stream into a temp file then move into place atomically so we
            // never leave a half-written file looking like a valid cache.
            let tmp = dest.appendingPathExtension("partial-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }

            var bytes: [UInt8] = []
            bytes.reserveCapacity(64 * 1024)
            var received: Int64 = 0
            for try await byte in asyncBytes {
                bytes.append(byte)
                received += 1
                if bytes.count >= 64 * 1024 {
                    try handle.write(contentsOf: bytes)
                    bytes.removeAll(keepingCapacity: true)
                    progress?(.init(phase: .downloading, bytesReceived: received, bytesExpected: expected))
                }
            }
            if !bytes.isEmpty {
                try handle.write(contentsOf: bytes)
            }
            try handle.close()
            try verifyChecksum(of: tmp)
            try FileManager.default.moveItem(at: tmp, to: dest)
            progress?(.init(phase: .downloading, bytesReceived: received, bytesExpected: expected))
            return dest
        } catch let e as Error {
            throw e
        } catch {
            throw Error.downloadFailed(sourceURL, underlying: error)
        }
    }

    private func verifyChecksum(of url: URL) throws {
        guard let expectedSHA256 else { return }
        let data = try Data(contentsOf: url)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw Error.checksumMismatch(sourceURL, expected: expectedSHA256, actual: actual)
        }
    }

    private func extractKernel(from tarURL: URL, to destination: URL) throws {
        do {
            // The Kata tarball stores `vmlinux.container` as a symlink to a
            // versioned vmlinux-X.Y.Z. ArchiveReader.extractFile returns the
            // symlink entry (zero bytes) without following. So:
            //   pass 1: find the entry, capture its symlink target if any.
            //   pass 2: extract the resolved path.
            let resolvedMember = try resolveMemberPath(in: tarURL)

            let reader = try ArchiveReader(file: tarURL)
            let (entry, data) = try reader.extractFile(path: resolvedMember)
            guard data.count > 0 else {
                throw Error.extractFailed(
                    member: resolvedMember,
                    underlying: NSError(
                        domain: "Crucible.KernelDownloader",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "extracted entry was empty (size=\(entry.size ?? -1), type=\(entry.fileType))"]
                    )
                )
            }
            let tmp = destination.appendingPathExtension("partial-\(UUID().uuidString)")
            try data.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch let e as Error {
            throw e
        } catch {
            throw Error.extractFailed(member: memberPath, underlying: error)
        }
    }

    /// Walks the archive once to find the requested member. If the entry
    /// is a symlink, returns the resolved sibling path; otherwise returns
    /// the original member path. Handles only single-level symlinks (the
    /// case Kata uses); a chain would need iteration but isn't needed here.
    private func resolveMemberPath(in tarURL: URL) throws -> String {
        let reader = try ArchiveReader(file: tarURL)
        var iter = reader.makeIterator()
        while let (entry, _) = iter.next() {
            guard let path = entry.path else { continue }
            let trimmedEntry = path.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            let trimmedTarget = memberPath.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            guard trimmedEntry == trimmedTarget else { continue }
            if entry.fileType == URLFileResourceType.symbolicLink, let target = entry.symlinkTarget {
                // Resolve relative to the symlink's directory.
                let dir = (path as NSString).deletingLastPathComponent
                let resolved = dir.isEmpty ? target : "\(dir)/\(target)"
                return resolved.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
            }
            return memberPath
        }
        throw Error.extractFailed(
            member: memberPath,
            underlying: NSError(
                domain: "Crucible.KernelDownloader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "member not found in archive"]
            )
        )
    }
}

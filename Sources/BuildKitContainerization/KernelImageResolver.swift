@preconcurrency import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationOCI
import Foundation

/// Resolves a Linux kernel from a kernel OCI image pulled from a registry.
///
/// Two image shapes are supported:
///
/// - **Apple-format kernel image**: an OCI image whose single per-platform layer
///   blob (`application/vnd.apple.containerization.kernel`) *is* the kernel
///   binary. Resolved via ``KernelImage``.
/// - **Standard OCI image**: a regular image whose layers are tar(.gz/.zst)
///   filesystem diffs. The kernel is read from a path inside the composed root
///   filesystem.
///
/// Resolution order:
/// - With an explicit `subpath`, the image is treated as a standard OCI image and
///   the kernel is read from that path (e.g. `/boot/vmlinuz`). If the image turns
///   out to be Apple-format, this is rejected.
/// - With no `subpath`, the Apple-format kernel layer is preferred; if the image
///   is a standard OCI image, the default locations (``defaultKernelPaths``) are
///   searched.
///
/// The image is pulled into the provided ``ImageStore`` (skipped if already
/// present). The returned URL points at the kernel binary on the host, suitable
/// for booting via `Kernel(path:platform:)`.
enum KernelImageResolver {
    /// Default kernel directories searched when no subpath is given and the
    /// image is a standard OCI image rather than an Apple-format kernel image.
    /// Within these, both `vmlinuz` and versioned `vmlinuz-<version>` files match.
    static let defaultKernelPaths = ["boot/vmlinuz", "vmlinuz"]

    enum Error: Swift.Error, CustomStringConvertible {
        case pullFailed(reference: String, underlying: String)
        case extractFailed(reference: String, underlying: String)
        case appleFormatWithSubpath(reference: String)
        case subpathNotFound(reference: String, subpath: String)
        case kernelNotFound(reference: String, searched: [String])

        var description: String {
            switch self {
            case .pullFailed(let reference, let underlying):
                return "Failed to pull kernel image \(reference): \(underlying)"
            case .extractFailed(let reference, let underlying):
                return "\(reference) is not a valid kernel image (expected layer media type \(KernelImage.mediaType)): \(underlying)"
            case .appleFormatWithSubpath(let reference):
                return "\(reference) is an Apple-format kernel image (\(KernelImage.mediaType)); a subpath is only valid for standard OCI images. Clear the kernel subpath to use this image."
            case .subpathNotFound(let reference, let subpath):
                return "Kernel file \(subpath) was not found in the root filesystem of \(reference)."
            case .kernelNotFound(let reference, let searched):
                let paths = searched.map { "/" + $0 }.joined(separator: ", ")
                return "\(reference) is not an Apple-format kernel image and no kernel (vmlinuz or vmlinuz-<version>) was found at the default locations (\(paths)). Set a kernel subpath pointing at the kernel inside the image."
            }
        }
    }

    /// Pulls the kernel image if needed and returns the on-disk path to the
    /// kernel binary for `platform`.
    ///
    /// - Parameter subpath: When non-empty, treat the image as a standard OCI
    ///   image and extract the kernel from this path inside its root filesystem.
    ///   When `nil`/empty, prefer the Apple-format kernel layer and otherwise
    ///   fall back to the default rootfs locations (``defaultKernelPaths``).
    static func resolve(
        reference: String,
        subpath: String? = nil,
        imageStore: ImageStore,
        platform: SystemPlatform = .linuxArm
    ) async throws -> URL {
        let image: Containerization.Image
        do {
            image = try await fetchImage(reference: reference, imageStore: imageStore)
        } catch let error as ImagePullError {
            throw Error.pullFailed(reference: reference, underlying: error.description)
        } catch {
            throw Error.pullFailed(reference: reference, underlying: String(describing: error))
        }

        let trimmedSubpath = subpath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSubpath, !trimmedSubpath.isEmpty {
            return try await extractExactSubpath(
                image: image,
                reference: reference,
                subpath: trimmedSubpath,
                platform: platform
            )
        }

        // No subpath: prefer an Apple-format kernel layer.
        do {
            let kernel = try await KernelImage(image: image).kernel(for: platform)
            return kernel.path
        } catch {
            // Not an Apple-format kernel image; fall back to a standard OCI image
            // and look for a kernel at the usual rootfs locations.
            return try await extractDefaultKernel(
                image: image,
                reference: reference,
                platform: platform
            )
        }
    }

    private static func fetchImage(reference: String, imageStore: ImageStore) async throws -> Containerization.Image {
        do {
            return try await imageStore.get(reference: reference)
        } catch let error as ContainerizationError where error.code == .notFound {
            let auth = try await ImagePullAuthenticator.authentication(for: reference)
            return try await imageStore.pull(reference: reference, auth: auth)
        }
    }

    /// Extracts the kernel at an explicit `subpath` from a standard OCI image's
    /// composed root filesystem. Layers are scanned top to bottom (last wins).
    private static func extractExactSubpath(
        image: Containerization.Image,
        reference: String,
        subpath: String,
        platform: SystemPlatform
    ) async throws -> URL {
        let manifest = try await manifest(for: image, reference: reference, platform: platform)

        // An explicit subpath makes no sense for an Apple-format kernel image,
        // which has no rootfs to index into.
        if manifest.layers.contains(where: { $0.mediaType == KernelImage.mediaType }) {
            throw Error.appleFormatWithSubpath(reference: reference)
        }

        let normalized = normalize(subpath: subpath)
        for layer in manifest.layers.reversed() {
            let blobPath = try await contentPath(for: layer.digest, image: image, reference: reference)
            let reader = try ArchiveReader(file: blobPath)
            guard let (_, data) = try? reader.extractFile(path: normalized) else {
                continue
            }
            return try cache(data: data, imageDigest: image.digest, subpath: normalized)
        }
        throw Error.subpathNotFound(reference: reference, subpath: subpath)
    }

    /// Searches a standard OCI image's root filesystem for a kernel at the usual
    /// locations, matching both `vmlinuz` and versioned `vmlinuz-<version>`
    /// names under `/boot` or `/`. Layers are scanned top to bottom.
    private static func extractDefaultKernel(
        image: Containerization.Image,
        reference: String,
        platform: SystemPlatform
    ) async throws -> URL {
        let manifest = try await manifest(for: image, reference: reference, platform: platform)

        for layer in manifest.layers.reversed() {
            let blobPath = try await contentPath(for: layer.digest, image: image, reference: reference)
            if let match = try findDefaultKernel(inLayer: blobPath) {
                return try cache(data: match.data, imageDigest: image.digest, subpath: match.name)
            }
        }
        throw Error.kernelNotFound(reference: reference, searched: defaultKernelPaths)
    }

    /// Scans a single layer archive for the best kernel match, preferring the
    /// highest version when several `vmlinuz-<version>` files are present.
    private static func findDefaultKernel(inLayer blobPath: URL) throws -> (name: String, data: Data)? {
        // `ArchiveReader(file:)` auto-detects the format/compression filter, so
        // gzip, zstd and uncompressed tar layers all work. The streaming
        // iterator lets us skip non-matching entries without reading their data.
        let reader = try ArchiveReader(file: blobPath)
        var best: (name: String, data: Data)?
        for (entry, stream) in reader.makeStreamingIterator() {
            guard entry.fileType == .regular, let path = entry.path else { continue }
            let normalized = normalize(subpath: path)
            guard matchesDefaultKernel(normalized) else { continue }

            let name = (normalized as NSString).lastPathComponent
            if let current = best, name.compare(current.name, options: .numeric) != .orderedDescending {
                continue
            }
            best = (name, drain(stream))
        }
        return best
    }

    /// Matches a normalized rootfs path that is a kernel at a default location:
    /// `vmlinuz` or `vmlinuz-<version>` directly under `/boot` or `/`.
    static func matchesDefaultKernel(_ normalizedPath: String) -> Bool {
        let directory = (normalizedPath as NSString).deletingLastPathComponent
        guard directory.isEmpty || directory == "boot" else { return false }
        let base = (normalizedPath as NSString).lastPathComponent
        return base == "vmlinuz" || base.hasPrefix("vmlinuz-")
    }

    /// Reads an archive entry's full contents into memory.
    private static func drain(_ stream: ArchiveEntryReader) -> Data {
        let chunkSize = 1 << 20
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let read = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return stream.read(base, maxLength: chunkSize)
            }
            if read <= 0 { break }
            out.append(contentsOf: buffer[0..<read])
        }
        return out
    }

    private static func manifest(
        for image: Containerization.Image,
        reference: String,
        platform: SystemPlatform
    ) async throws -> Manifest {
        do {
            return try await image.manifest(for: platform.ociPlatform())
        } catch {
            throw Error.extractFailed(reference: reference, underlying: String(describing: error))
        }
    }

    private static func contentPath(
        for digest: String,
        image: Containerization.Image,
        reference: String
    ) async throws -> URL {
        do {
            return try await image.getContent(digest: digest).path
        } catch {
            throw Error.extractFailed(reference: reference, underlying: String(describing: error))
        }
    }

    /// Writes the extracted kernel to a stable cache path so reboots reuse it.
    private static func cache(data: Data, imageDigest: String, subpath: String) throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Crucible/kernel-images", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("crucible-kernel-images", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let key = (imageDigest + ":" + subpath)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dest = dir.appendingPathComponent("vmlinuz-\(key)")
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// Normalizes a user-supplied rootfs path (strip leading slashes/`./`) so it
    /// matches tar member names like `boot/vmlinuz`.
    private static func normalize(subpath: String) -> String {
        var p = subpath.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("/") { p.removeFirst() }
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }
}

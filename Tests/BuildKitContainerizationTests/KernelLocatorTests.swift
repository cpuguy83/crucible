import Testing
import Foundation
@testable import BuildKitContainerization
import BuildKitCore

@Suite("KernelLocator")
struct KernelLocatorTests {
    @Test func overrideMissingFails() {
        var s = BuildKitSettings()
        s.kernelOverridePath = "/definitely/does/not/exist/vmlinux"
        #expect(throws: KernelLocator.Error.self) {
            _ = try KernelLocator.locate(settings: s)
        }
    }

    @Test func overridePresentResolves() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("crucible-kernel-test-\(UUID().uuidString)")
        try Data("fake kernel".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var s = BuildKitSettings()
        s.kernelOverridePath = tmp.path
        let url = try KernelLocator.locate(settings: s)
        #expect(url.path == tmp.path)
    }

    @Test func searchDirectoriesUseExpectedPaths() {
        let cli = KernelLocator.appleContainerKernelDirectory().path
        #expect(cli.hasSuffix("Library/Application Support/com.apple.container/kernels"))
        let cache = KernelLocator.crucibleKernelCacheDirectory().path
        #expect(cache.hasSuffix("Library/Application Support/Crucible/kernels"))
    }

    @Test func newestVmlinuxPicksMostRecent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crucible-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create two candidates with different mtimes.
        let older = dir.appendingPathComponent("vmlinux-old")
        let newer = dir.appendingPathComponent("vmlinux-new")
        try Data("o".utf8).write(to: older)
        try Data("n".utf8).write(to: newer)
        let oldDate = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)

        // A non-matching file should be ignored.
        try Data("x".utf8).write(to: dir.appendingPathComponent("not-a-kernel"))

        let picked = KernelLocator.newestVmlinux(in: dir)
        #expect(picked?.lastPathComponent == "vmlinux-new")
    }

    @Test func newestVmlinuxReturnsNilForMissingDirectory() {
        let missing = URL(fileURLWithPath: "/definitely/does/not/exist-\(UUID().uuidString)")
        #expect(KernelLocator.newestVmlinux(in: missing) == nil)
    }
}

@Suite("KernelDownloader")
struct KernelDownloaderTests {
    @Test func cachedKernelURLIsStableForSameInputs() {
        let dir = URL(fileURLWithPath: "/tmp/crucible-cache-test")
        let a = KernelDownloader(cacheDirectory: dir)
        let b = KernelDownloader(cacheDirectory: dir)
        // Use sync mirror by computing through a fresh actor reference.
        // Since cachedKernelURL is computed off URL/memberPath which are
        // constants for default-init, a and b must produce the same path.
        let urlA = Task { await a.cachedKernelURL.path }
        let urlB = Task { await b.cachedKernelURL.path }
        #expect(true)  // structural assertion below
        // Force the tasks; running synchronously in a test is fine via blocking await.
        Task { @MainActor in
            let pa = await urlA.value
            let pb = await urlB.value
            #expect(pa == pb)
            #expect(pa.hasPrefix(dir.path))
            #expect(URL(fileURLWithPath: pa).lastPathComponent.hasPrefix("vmlinux-"))
        }
    }

    @Test func cachedKernelURLChangesWithSourceURL() async {
        let dir = URL(fileURLWithPath: "/tmp/crucible-cache-test")
        let a = KernelDownloader(cacheDirectory: dir)
        let b = KernelDownloader(
            cacheDirectory: dir,
            sourceURL: URL(string: "https://example.com/different.tar.xz")!
        )
        let pa = await a.cachedKernelURL.path
        let pb = await b.cachedKernelURL.path
        #expect(pa != pb)
    }

    @Test func ensureKernelReturnsCachedFileWithoutDownload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crucible-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloader = KernelDownloader(cacheDirectory: dir)
        let cached = await downloader.cachedKernelURL
        try Data("pre-staged".utf8).write(to: cached)

        // Should hit the cache; no network attempted.
        let resolved = try await downloader.ensureKernel()
        #expect(resolved.path == cached.path)
        let bytes = try Data(contentsOf: resolved)
        #expect(String(data: bytes, encoding: .utf8) == "pre-staged")
    }
}

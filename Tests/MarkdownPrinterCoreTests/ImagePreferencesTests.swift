import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class ImagePreferencesTests: XCTestCase {
    func testAutomaticDownloadsDefaultOnAndPersistBothChoices() throws {
        let fixture = try ImageFixture()
        defer { fixture.cleanUp() }
        XCTAssertTrue(fixture.preferences.automaticallyDownloadRemoteImages)
        fixture.preferences.automaticallyDownloadRemoteImages = false
        XCTAssertFalse(ImagePreferences(defaults: fixture.defaults).automaticallyDownloadRemoteImages)
        fixture.preferences.automaticallyDownloadRemoteImages = true
        XCTAssertTrue(ImagePreferences(defaults: fixture.defaults).automaticallyDownloadRemoteImages)
    }

    func testDefaultDownloadsUniqueUncachedHTTPSImagesAndRebuildsPDF() async throws {
        let fixture = try ImageFixture()
        defer { fixture.cleanUp() }
        let cached = "https://example.com/cached.png"
        _ = try fixture.cache.store(fixture.png, for: cached)
        let session = fixture.session()
        try session.apply(MarkdownDocument(title: "Images", markdown: """
        # Automatic Images

        ![First](https://example.com/one.png)
        ![Duplicate](https://example.com/one.png)
        <img src="https://example.com/two.png" alt="Second">
        ![Cached](\(cached))
        ![Insecure](http://example.com/insecure.png)
        """))
        let revision = try XCTUnwrap(session.renderedSnapshot?.revision)
        await waitUntil {
            !session.isPreparingDocument && session.renderedSnapshot!.revision > revision
        }
        let sources = await fixture.downloader.requestedSources()
        XCTAssertEqual(Set(sources), ["https://example.com/one.png", "https://example.com/two.png"])
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(session.uncachedRemoteImageSources, ["http://example.com/insecure.png"])
        XCTAssertTrue(session.downloadingRemoteImageSources.isEmpty)
        XCTAssertNil(session.errorMessage)
        let pdf = try XCTUnwrap(PDFDocument(data: session.pdfData()))
        XCTAssertTrue(try XCTUnwrap(pdf.string).contains("Automatic Images"))
        XCTAssertFalse(try XCTUnwrap(pdf.string).contains("click to download: First"))
        let attachments = (0..<session.renderedText.length).compactMap {
            session.renderedText.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment
        }
        XCTAssertEqual(attachments.count, 4)
        let saved = fixture.directory.appendingPathComponent("images.pdf")
        try session.savePDF(to: saved)
        XCTAssertEqual(try Data(contentsOf: saved), session.renderedPDFData)
    }

    func testOffKeepsManualDownloadsAndEnablingUpdatesAllOpenDocuments() async throws {
        let fixture = try ImageFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.automaticallyDownloadRemoteImages = false
        let first = fixture.session()
        let second = fixture.session()
        try first.apply(MarkdownDocument(title: "One", markdown: "![One](https://example.com/one.png)"))
        try await second.applyAsync(MarkdownDocument(title: "Two", markdown: "![Two](https://example.com/two.png)"))
        XCTAssertTrue(first.downloadingRemoteImageSources.isEmpty)
        XCTAssertTrue(second.downloadingRemoteImageSources.isEmpty)
        let before = await fixture.downloader.requestedSources()
        XCTAssertTrue(before.isEmpty)
        await first.downloadRemoteImage(source: "https://example.com/one.png")
        XCTAssertTrue(first.uncachedRemoteImageSources.isEmpty)

        fixture.preferences.automaticallyDownloadRemoteImages = true
        await waitUntil { !second.renderedText.string.contains("click to download") }
        XCTAssertTrue(second.uncachedRemoteImageSources.isEmpty)
        let sources = await fixture.downloader.requestedSources()
        XCTAssertEqual(Set(sources), ["https://example.com/one.png", "https://example.com/two.png"])

        try await second.synchronizeAsync(with: MarkdownDocument(
            title: "Two", markdown: "![Three](https://example.com/three.png)"
        ))
        await waitUntil { !second.renderedText.string.contains("click to download") }
        XCTAssertNotNil(fixture.cache.cachedFileURL(for: "https://example.com/three.png"))
    }

    func testAutomaticFailuresStayQuietAndDoNotLoopAfterRendering() async throws {
        let failed = "https://example.com/fail.png"
        let fixture = try ImageFixture(failingSources: [failed])
        defer { fixture.cleanUp() }
        let session = fixture.session()
        try session.apply(MarkdownDocument(title: "Mixed", markdown: """
        ![Failure](\(failed))
        ![Success](https://example.com/success.png)
        """))
        let revision = session.renderedSnapshot!.revision
        await waitUntil { !session.isPreparingDocument && session.renderedSnapshot!.revision > revision }
        XCTAssertEqual(session.uncachedRemoteImageSources, [failed])
        XCTAssertTrue(session.renderedText.string.contains("click to download"))
        XCTAssertNil(session.errorMessage)
        try session.applyExplicitPageSetup(.letter)
        let sources = await fixture.downloader.requestedSources()
        XCTAssertEqual(sources.filter { $0 == failed }.count, 1)

        await session.downloadRemoteImage(source: failed)
        XCTAssertNotNil(session.errorMessage)
        let afterRetry = await fixture.downloader.requestedSources()
        XCTAssertEqual(afterRetry.filter { $0 == failed }.count, 2)
    }

    func testAllFailedDownloadsFinishAndCanRetryAfterToggling() async throws {
        let source = "https://example.com/fail.png"
        let fixture = try ImageFixture(failingSources: [source])
        defer { fixture.cleanUp() }
        let session = fixture.session()
        fixture.preferences.automaticallyDownloadRemoteImages = false
        fixture.preferences.automaticallyDownloadRemoteImages = true // No document yet.
        try await session.applyAsync(MarkdownDocument(title: "Failure", markdown: "![Failure](\(source))"))
        await waitUntil { session.downloadingRemoteImageSources.isEmpty }
        XCTAssertNil(session.errorMessage)
        fixture.preferences.automaticallyDownloadRemoteImages = false
        fixture.preferences.automaticallyDownloadRemoteImages = true
        await waitUntil { session.downloadingRemoteImageSources.isEmpty }
        let requests = await fixture.downloader.requestedSources()
        XCTAssertEqual(requests, [source, source])
    }

    func testDisablingCancelsInFlightDownloadsAndPreservesPreview() async throws {
        let fixture = try ImageFixture(blocked: true)
        defer { fixture.cleanUp() }
        let session = fixture.session()
        let source = "https://example.com/slow.png"
        try session.apply(MarkdownDocument(title: "Slow", markdown: "![Slow](\(source))"))
        let revision = session.renderedSnapshot!.revision
        await waitUntil { await fixture.downloader.requestedSources() == [source] }
        fixture.preferences.automaticallyDownloadRemoteImages = false
        XCTAssertTrue(session.downloadingRemoteImageSources.isEmpty)
        await fixture.downloader.releaseAll()
        await waitUntil { await fixture.downloader.finishedCount() == 1 }
        XCTAssertEqual(session.renderedSnapshot?.revision, revision)
        XCTAssertNil(fixture.cache.cachedFileURL(for: source))
        XCTAssertNil(session.errorMessage)
    }

    func testReplacingDocumentCancelsOldDownloadsWithoutRestoringOldContent() async throws {
        let fixture = try ImageFixture(blocked: true)
        defer { fixture.cleanUp() }
        let session = fixture.session()
        let old = "https://example.com/old.png"
        let new = "https://example.com/new.png"
        try session.apply(MarkdownDocument(title: "Old", markdown: "![Old](\(old))"))
        await waitUntil { await fixture.downloader.requestedSources() == [old] }
        try await session.applyAsync(MarkdownDocument(title: "New", markdown: "![New](\(new))"))
        await waitUntil { await fixture.downloader.requestedSources().count == 2 }
        await fixture.downloader.releaseAll()
        await waitUntil { !session.isPreparingDocument && !session.renderedText.string.contains("click to download") }
        XCTAssertEqual(session.title, "New")
        XCTAssertNil(fixture.cache.cachedFileURL(for: old))
        XCTAssertNotNil(fixture.cache.cachedFileURL(for: new))
        XCTAssertTrue(session.downloadingRemoteImageSources.isEmpty)
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out waiting for image downloads", file: file, line: line)
    }
}

@MainActor
private final class ImageFixture {
    let suite = "ImagePreferencesTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let preferences: ImagePreferences
    let directory: URL
    let cache: RemoteImageCache
    let png: Data
    let downloader: ControlledImageDownloader

    init(failingSources: Set<String> = [], blocked: Bool = false) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences = ImagePreferences(defaults: defaults)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        cache = RemoteImageCache(directoryURL: directory)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 30, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        for x in 0..<30 {
            for y in 0..<20 {
                bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.6, blue: 0.7, alpha: 1), atX: x, y: y)
            }
        }
        png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        downloader = ControlledImageDownloader(cache: cache, png: png, failingSources: failingSources, blocked: blocked)
    }

    func session() -> DocumentSession {
        DocumentSession(imagePreferences: preferences, remoteImageCache: cache, remoteImageDownloader: downloader)
    }

    func cleanUp() {
        preferences.automaticallyDownloadRemoteImages = false
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ControlledImageDownloader: RemoteImageDownloading {
    let cache: RemoteImageCache
    let png: Data
    let failingSources: Set<String>
    var blocked: Bool
    private var sources: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var finished = 0

    init(cache: RemoteImageCache, png: Data, failingSources: Set<String>, blocked: Bool) {
        self.cache = cache
        self.png = png
        self.failingSources = failingSources
        self.blocked = blocked
    }

    func download(source: String) async throws -> URL {
        sources.append(source)
        defer { finished += 1 }
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        if failingSources.contains(source) { throw RemoteImageDownloadError.httpStatus(404) }
        return try cache.store(png, for: source)
    }

    func releaseAll() {
        blocked = false
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func requestedSources() -> [String] { sources }
    func finishedCount() -> Int { finished }
}

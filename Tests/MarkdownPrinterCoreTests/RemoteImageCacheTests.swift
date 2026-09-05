import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

final class RemoteImageCacheTests: XCTestCase {
    private var directory: URL!
    private var cache: RemoteImageCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteImageCacheTests-\(UUID().uuidString)", isDirectory: true)
        cache = RemoteImageCache(directoryURL: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        cache = nil
        directory = nil
    }

    func testRemoteReferencesValidateURLsAndCatalogEveryMarkdownLocationOnce() throws {
        XCTAssertNil(RemoteImageReference(source: "relative.png", alternativeText: "Local"))
        XCTAssertNil(RemoteImageReference(source: "ftp://example.com/a.png", alternativeText: "FTP"))
        XCTAssertNil(RemoteImageReference(source: "https:///missing-host.png", alternativeText: "Bad"))
        XCTAssertEqual(
            RemoteImageReference.remoteURL(from: " https://example.com/a.png ")?.absoluteString,
            "https://example.com/a.png"
        )

        let document = MarkdownDocument(title: "Images", markdown: "", blocks: [
            .heading(level: 1, content: [.image(alt: "One", source: "https://example.com/one.png")]),
            .blockquote([.paragraph([.strong([
                .image(alt: "Two", source: "http://example.com/two.jpg")
            ])])]),
            .list(items: [MarkdownListItem(blocks: [
                .rawHTML("<img src='https://example.com/three.png' alt='Three' width='90'>")
            ])], ordered: false, start: 1),
            .table(
                headers: [[.text("Image")]],
                alignments: [.leading],
                rows: [[[
                    .rawHTML("<img src='https://example.com/four.png' alt='Four' width='80'>"),
                    .image(alt: "Duplicate", source: "https://example.com/one.png")
                ]]]
            ),
            .footnoteDefinition(label: "source", content: [
                .link(children: [.image(alt: "Five", source: "https://example.com/five.png")], destination: "https://example.com")
            ]),
            .paragraph([.image(alt: "Local", source: "local.png")]),
            .codeBlock(language: nil, code: "https://example.com/not-an-image.png"),
            .thematicBreak
        ])

        let references = RemoteImageCatalog.references(in: document)
        XCTAssertEqual(references.map(\.source), [
            "https://example.com/one.png",
            "http://example.com/two.jpg",
            "https://example.com/three.png",
            "https://example.com/four.png",
            "https://example.com/five.png"
        ])
        XCTAssertEqual(references[2].alternativeText, "Three")
        XCTAssertEqual(references[2].requestedWidth, 90)
        XCTAssertEqual(
            RemoteImageCatalog.references(in: [.image(alt: "Inline", source: "https://example.com/i.png")]).count,
            1
        )
    }

    func testActionURLRoundTripsSourceAndRejectsOtherValues() throws {
        let source = "https://example.com/image with query.png?size=2&crop=yes"
        let url = RemoteImageActionURL.downloadURL(for: source)

        XCTAssertEqual(RemoteImageActionURL.downloadSource(from: url), source)
        XCTAssertEqual(RemoteImageActionURL.downloadSource(from: url.absoluteString), source)
        XCTAssertNil(RemoteImageActionURL.downloadSource(from: URL(string: "https://example.com")!))
        XCTAssertNil(RemoteImageActionURL.downloadSource(from: 12))
        XCTAssertNil(RemoteImageActionURL.downloadSource(from: "markdown-printer://remote-image/other"))
    }

    func testCacheStoresValidImagesRejectsInvalidDataAndIgnoresCorruption() throws {
        let source = "https://example.com/art.png"
        XCTAssertNil(cache.cachedFileURL(for: source))
        XCTAssertNil(cache.cachedFileURL(for: "local.png"))
        XCTAssertThrowsError(try cache.store(Data("not an image".utf8), for: source)) {
            XCTAssertEqual($0 as? RemoteImageDownloadError, .invalidImage)
        }
        XCTAssertThrowsError(try cache.store(makePNG(), for: "local.png")) {
            XCTAssertEqual($0 as? RemoteImageDownloadError, .invalidURL)
        }

        let stored = try cache.store(makePNG(), for: source)
        XCTAssertEqual(cache.cachedFileURL(for: source), stored)
        XCTAssertTrue(stored.path.hasPrefix(directory.path))
        try Data().write(to: stored)
        XCTAssertNil(cache.cachedFileURL(for: source))

        try cache.removeCachedFile(for: source)
        try cache.removeCachedFile(for: source)
        XCTAssertNil(cache.cachedFileURL(for: source))
        XCTAssertEqual(RemoteImageCache(directoryURL: directory), cache)
    }

    func testDownloaderCachesValidatedHTTPSImageAndReusesIt() async throws {
        let source = "https://example.com/image.png"
        let png = try makePNG()
        let downloader = RemoteImageDownloader(cache: cache) { _ in
            RemoteImageDownloadResponse(
                data: png,
                statusCode: 200,
                mimeType: "image/png",
                expectedContentLength: 500
            )
        }
        let first = try await downloader.download(source: source)
        XCTAssertEqual(first, cache.cachedFileURL(for: source))

        let cachedOnly = RemoteImageDownloader(cache: cache) { _ in
            throw TestError.unexpectedFetch
        }
        let reused = try await cachedOnly.download(source: source)
        let maximumDownloadSize = await downloader.maximumDownloadSize
        let downloaderCache = await downloader.cache
        XCTAssertEqual(reused, first)
        XCTAssertEqual(maximumDownloadSize, 25 * 1_024 * 1_024)
        XCTAssertEqual(downloaderCache, cache)
    }

    func testDownloaderRejectsUnsafeOrInvalidResponses() async throws {
        let responseCases: [(RemoteImageDownloadResponse, RemoteImageDownloadError)] = [
            (RemoteImageDownloadResponse(data: try makePNG(), statusCode: 404, mimeType: "image/png"), .httpStatus(404)),
            (RemoteImageDownloadResponse(data: Data([1]), statusCode: 200, mimeType: "text/html"), .invalidContentType),
            (RemoteImageDownloadResponse(data: Data("bad".utf8), statusCode: 200, mimeType: nil), .invalidImage),
            (RemoteImageDownloadResponse(data: try makePNG(), statusCode: nil, mimeType: nil, expectedContentLength: 5), .tooLarge(4)),
            (RemoteImageDownloadResponse(data: Data(repeating: 1, count: 5), statusCode: 200, mimeType: nil), .tooLarge(4))
        ]
        for (index, item) in responseCases.enumerated() {
            let item = item
            let source = "https://example.com/case-\(index).png"
            let downloader = RemoteImageDownloader(cache: cache, maximumDownloadSize: 4) { _ in item.0 }
            do {
                _ = try await downloader.download(source: source)
                XCTFail("Expected \(item.1)")
            } catch {
                XCTAssertEqual(error as? RemoteImageDownloadError, item.1)
            }
        }

        let noFetch = RemoteImageDownloader(cache: cache) { _ in throw TestError.unexpectedFetch }
        await assertDownloadError(.invalidURL) {
            try await noFetch.download(source: "not a URL")
        }
        await assertDownloadError(.insecureURL) {
            try await noFetch.download(source: "http://example.com/insecure.png")
        }
        XCTAssertEqual(RemoteImageDownloadError.invalidURL.localizedDescription, "The remote image address is invalid.")
        XCTAssertEqual(RemoteImageDownloadError.insecureURL.localizedDescription, "Only secure HTTPS images can be downloaded.")
        XCTAssertEqual(RemoteImageDownloadError.httpStatus(503).localizedDescription, "The image server returned HTTP status 503.")
        XCTAssertEqual(RemoteImageDownloadError.invalidContentType.localizedDescription, "The downloaded file is not a supported image.")
        XCTAssertEqual(RemoteImageDownloadError.tooLarge(2 * 1_024 * 1_024).localizedDescription, "The remote image exceeds the 2 MB download limit.")
    }

    private func assertDownloadError(
        _ expected: RemoteImageDownloadError,
        operation: () async throws -> URL
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? RemoteImageDownloadError, expected)
        }
    }

    private func makePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 12, height: 8))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}

private enum TestError: Error {
    case unexpectedFetch
}

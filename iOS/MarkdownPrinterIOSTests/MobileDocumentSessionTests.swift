import XCTest
import UIKit
import MarkdownPrinterCore
@testable import MarkdownPrinterMobileSupport

@MainActor
final class MobileDocumentSessionTests: XCTestCase {
    private enum TestError: LocalizedError {
        case failed
        var errorDescription: String? { "Test export failed." }
    }

    func testInitialDocumentBuildsPresentationAndRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Session.md")
        try Data("# Session\n\nBody".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MobileDocumentSession(document: try MarkdownDocument.load(from: url), sourceURL: url)

        XCTAssertEqual(session.title, "Session")
        XCTAssertEqual(session.presentation?.blocks.count, 2)
        XCTAssertEqual(session.sourceURL, url)
        XCTAssertEqual(session.revision, 1)
        XCTAssertEqual(session.pdfState, .idle)
    }

    func testPDFDataCachesByRevisionAndSharesAnInFlightTask() async throws {
        var calls = 0
        let session = MobileDocumentSession(
            document: MarkdownDocument(title: "Cache", markdown: "First"),
            pdfProvider: { document in
                calls += 1
                try await Task.sleep(for: .milliseconds(25))
                return Data("PDF:\(document.markdown)".utf8)
            }
        )

        async let first = session.pdfData()
        async let second = session.pdfData()
        let values = try await [first, second]
        XCTAssertEqual(values[0], values[1])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.pdfState, .ready)
        let cached = try await session.pdfData()
        XCTAssertEqual(cached, values[0])
        XCTAssertEqual(calls, 1)

        session.apply(MarkdownDocument(title: "Cache", markdown: "Second"))
        XCTAssertEqual(session.pdfState, .idle)
        let regenerated = try await session.pdfData()
        XCTAssertEqual(regenerated, Data("PDF:Second".utf8))
        XCTAssertEqual(calls, 2)
    }

    func testPDFFailureAndClearErrorAreRecoverable() async {
        let session = MobileDocumentSession(
            document: MarkdownDocument(title: "Failure", markdown: "Body"),
            pdfProvider: { _ in throw TestError.failed }
        )
        do {
            _ = try await session.pdfData()
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Test export failed.")
        }
        XCTAssertEqual(session.pdfState, .failed("Test export failed."))
        XCTAssertEqual(session.errorMessage, "Test export failed.")
        session.clearError()
        XCTAssertNil(session.errorMessage)
    }

    func testNoDocumentAndCancellationStates() async {
        let empty = MobileDocumentSession(pdfProvider: { _ in Data() })
        XCTAssertEqual(empty.title, "Markdown Printer")
        do {
            _ = try await empty.pdfData()
            XCTFail("Expected no document")
        } catch {
            XCTAssertEqual(error as? MobileDocumentSessionError, .noDocument)
        }
        XCTAssertNotNil(MobileDocumentSessionError.noDocument.errorDescription)

        let cancellable = MobileDocumentSession(
            document: MarkdownDocument(title: "Cancel", markdown: "Body"),
            pdfProvider: { _ in
                try await Task.sleep(for: .seconds(10))
                return Data()
            }
        )
        let task = Task { try await cancellable.pdfData() }
        await Task.yield()
        XCTAssertEqual(cancellable.pdfState, .preparing)
        cancellable.cancelPDFGeneration()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellable.pdfState, .idle)
    }

    func testLoadAndRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("Original.md")
        try Data("# Original".utf8).write(to: originalURL)

        let session = MobileDocumentSession()
        await session.load(url: originalURL)
        XCTAssertEqual(session.title, "Original")
        let firstRevision = session.revision

        try Data("# Updated".utf8).write(to: originalURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: originalURL.path
        )
        await session.refreshIfChanged()
        XCTAssertEqual(session.title, "Updated")
        XCTAssertGreaterThan(session.revision, firstRevision)
    }

    func testLoadFailurePublishesReadableError() async {
        let session = MobileDocumentSession()
        await session.refreshIfChanged()
        await session.load(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("definitely-missing.md")
        )
        XCTAssertNil(session.document)
        XCTAssertNotNil(session.errorMessage)
    }

    func testPermissionFailurePublishesARecoverableFileRequest() async {
        let deniedLoader = MobileDocumentLoader { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        let session = MobileDocumentSession(
            loader: deniedLoader,
            pdfProvider: { _ in Data() }
        )
        let requestedURL = URL(fileURLWithPath: "/provider/research-integration-map.md")

        await session.load(url: requestedURL)

        XCTAssertNil(session.document)
        XCTAssertEqual(
            session.permissionRequest,
            MobileDocumentPermissionRequest(url: requestedURL)
        )
        XCTAssertEqual(
            session.errorMessage,
            "Allow access to the folder containing “research-integration-map.md” so Markdown Printer can open it."
        )
    }

    func testPermissionRequestCanAuthorizeContainingDirectoryOnce() async throws {
        let suiteName = "MobileDocumentSessionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileDirectoryAccessStore(
            defaults: defaults,
            bookmarkKey: "authorized-folders",
            bookmarkCreator: { _ in Data("bookmark".utf8) },
            bookmarkResolver: { _ in throw CocoaError(.fileReadUnknown) },
            leaseFactory: { url in
                SecurityScopedResourceLease(
                    url: url,
                    startAccessing: { true },
                    stopAccessing: {}
                )
            },
            isReadableDirectory: { _ in false }
        )
        let deniedLoader = MobileDocumentLoader { _ in
            throw CocoaError(.fileReadNoPermission)
        }
        let session = MobileDocumentSession(
            loader: deniedLoader,
            directoryAccessStore: store,
            pdfProvider: { _ in Data() }
        )
        let requestedURL = URL(fileURLWithPath: "/provider/project/research.md")

        XCTAssertThrowsError(try session.authorizeDirectory(URL(fileURLWithPath: "/provider"))) { error in
            XCTAssertEqual(error as? MobileDirectoryAccessError, .noPendingRequest)
        }
        await session.load(url: requestedURL)
        XCTAssertThrowsError(
            try session.authorizeDirectory(URL(fileURLWithPath: "/provider/elsewhere"))
        ) { error in
            XCTAssertEqual(error as? MobileDirectoryAccessError, .wrongFolder("research.md"))
        }

        try session.authorizeDirectory(URL(fileURLWithPath: "/provider/project", isDirectory: true))
        XCTAssertTrue(store.hasAccess(to: requestedURL))
        XCTAssertEqual(defaults.array(forKey: "authorized-folders") as? [Data], [Data("bookmark".utf8)])
    }

    func testDefaultExporterProducesAndCachesARealPDF() async throws {
        let session = MobileDocumentSession(
            document: MarkdownDocument(title: "Default Export", markdown: "# Default Export\n\nBody")
        )
        let first = try await session.pdfData()
        let second = try await session.pdfData()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(session.pdfState, .ready)
    }

    func testRemoteImageDownloadsInvalidatePDFAndDownloadOnlyUncachedSources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileRemoteImages-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteImageCache(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageData = try makePNG()
        let downloader = MobileTestRemoteImageDownloader(cache: cache, imageData: imageData)
        var pdfCalls = 0
        let first = "https://example.com/one.png"
        let second = "https://example.com/two.png"
        let session = MobileDocumentSession(
            document: MarkdownDocument(
                title: "Remote",
                markdown: "![One](\(first))\n\n<img src='\(second)' alt='Two'>"
            ),
            remoteImageCache: cache,
            remoteImageDownloader: downloader,
            pdfProvider: { _ in
                pdfCalls += 1
                return Data("PDF-\(pdfCalls)".utf8)
            }
        )
        _ = try await session.pdfData()
        let initialRevision = session.revision
        XCTAssertEqual(session.uncachedRemoteImageSources, [first, second])

        await session.downloadRemoteImage(source: "https://example.com/not-present.png")
        let requestsBeforeDownload = await downloader.requestedSources()
        XCTAssertEqual(requestsBeforeDownload, [])
        await session.downloadRemoteImage(source: first)
        XCTAssertGreaterThan(session.revision, initialRevision)
        XCTAssertEqual(session.remoteImageRevision, 1)
        XCTAssertEqual(session.pdfState, .idle)
        XCTAssertNotNil(cache.cachedFileURL(for: first))

        _ = try await session.pdfData()
        XCTAssertEqual(pdfCalls, 2)
        await session.downloadRemoteImage(source: first)
        await session.downloadAllRemoteImages()
        let requestedSources = await downloader.requestedSources()
        XCTAssertEqual(requestedSources, [first, second])
        XCTAssertTrue(session.uncachedRemoteImageSources.isEmpty)
        XCTAssertEqual(session.remoteImageRevision, 2)
        XCTAssertTrue(session.downloadingRemoteImageSources.isEmpty)
        XCTAssertNil(session.errorMessage)
    }

    func testRemoteImageFailuresAreReportedWithoutDiscardingSuccessfulDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileRemoteImageFailures-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteImageCache(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "https://example.com/fail-one.png"
        let second = "https://example.com/fail-two.png"
        let downloader = MobileTestRemoteImageDownloader(
            cache: cache,
            imageData: try makePNG(),
            failingSources: [first, second]
        )
        let session = MobileDocumentSession(
            document: MarkdownDocument(
                title: "Remote",
                markdown: "![One](\(first))\n\n![Two](\(second))"
            ),
            remoteImageCache: cache,
            remoteImageDownloader: downloader,
            pdfProvider: { _ in Data() }
        )

        await session.downloadRemoteImage(source: first)
        XCTAssertEqual(session.errorMessage, "Test remote image failure.")
        await session.downloadAllRemoteImages()
        XCTAssertEqual(session.errorMessage, "2 remote images could not be downloaded.")
        XCTAssertEqual(session.remoteImageRevision, 0)
        XCTAssertTrue(session.downloadingRemoteImageSources.isEmpty)
    }

    private func makePNG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 12)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 18, height: 12))
        }
        return try XCTUnwrap(image.pngData())
    }
}

private enum MobileRemoteImageTestError: LocalizedError {
    case failed

    var errorDescription: String? { "Test remote image failure." }
}

private actor MobileTestRemoteImageDownloader: RemoteImageDownloading {
    let cache: RemoteImageCache
    let imageData: Data
    let failingSources: Set<String>
    private var sources: [String] = []

    init(
        cache: RemoteImageCache,
        imageData: Data,
        failingSources: Set<String> = []
    ) {
        self.cache = cache
        self.imageData = imageData
        self.failingSources = failingSources
    }

    func download(source: String) async throws -> URL {
        sources.append(source)
        if failingSources.contains(source) { throw MobileRemoteImageTestError.failed }
        return try cache.store(imageData, for: source)
    }

    func requestedSources() -> [String] {
        sources
    }
}

import XCTest
import MarkdownPrinterCore
@testable import MarkdownPrinterMobileSupport

@MainActor
final class MobileDocumentSessionTests: XCTestCase {
    private enum TestError: LocalizedError {
        case failed
        var errorDescription: String? { "Test export failed." }
    }

    func testInitialDocumentBuildsPresentationMetadataAndRevision() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Session.md")
        try Data("# Session\n\nBody".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let session = MobileDocumentSession(document: try MarkdownDocument.load(from: url), sourceURL: url)

        XCTAssertEqual(session.title, "Session")
        XCTAssertEqual(session.presentation?.blocks.count, 2)
        XCTAssertEqual(session.sourceURL, url)
        XCTAssertEqual(session.metadata?.filename, "Session.md")
        XCTAssertEqual(session.revision, 1)
        XCTAssertEqual(session.pdfState, .idle)
        XCTAssertTrue(session.fileActions.canDuplicate)
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

    func testLoadRefreshAndUpdateSourceURL() async throws {
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

        let movedURL = directory.appendingPathComponent("Moved.markdown")
        try FileManager.default.moveItem(at: originalURL, to: movedURL)
        let beforeMove = session.revision
        session.updateSourceURL(movedURL)
        XCTAssertEqual(session.sourceURL, movedURL)
        XCTAssertEqual(session.metadata?.filename, "Moved.markdown")
        XCTAssertGreaterThan(session.revision, beforeMove)
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
}

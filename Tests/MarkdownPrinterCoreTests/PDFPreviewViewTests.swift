import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class PDFPreviewViewTests: XCTestCase {
    func testLinkCoordinatorForwardsPDFClicks() {
        let expectedURL = URL(string: "https://example.com")!
        var openedURL: URL?
        let coordinator = PDFPreviewView.Coordinator { openedURL = $0 }

        coordinator.pdfViewWillClick(onLink: PDFView(), with: expectedURL)

        XCTAssertEqual(openedURL, expectedURL)
    }

    func testMarkdownLinkTargetRecognizesSupportedLocalFilesAndRemovesFragments() throws {
        for pathExtension in ["md", "markdown", "mdown", "mkd", "MD"] {
            let fileURL = URL(fileURLWithPath: "/tmp/notes.\(pathExtension)")
            var components = try XCTUnwrap(URLComponents(url: fileURL, resolvingAgainstBaseURL: false))
            components.query = "source=preview"
            components.fragment = "details"
            let linkedURL = try XCTUnwrap(components.url)

            XCTAssertEqual(MarkdownLinkTarget.fileURL(from: linkedURL), fileURL.standardizedFileURL)
        }
    }

    func testMarkdownLinkTargetLeavesWebAndOtherLocalFilesToTheSystem() {
        XCTAssertNil(MarkdownLinkTarget.fileURL(from: URL(string: "https://example.com/notes.md")!))
        XCTAssertNil(MarkdownLinkTarget.fileURL(from: URL(fileURLWithPath: "/tmp/report.pdf")))
    }

    func testInitialLayoutFitsTheCompleteFirstPage() throws {
        let document = try makeMultiPageDocument()
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))

        view.display(document)
        view.layoutSubtreeIfNeeded()

        let pageRect = view.convert(firstPage.bounds(for: .cropBox), from: firstPage)
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 0)
        XCTAssertLessThan(pageRect.width, view.bounds.width)
        XCTAssertLessThan(pageRect.height, view.bounds.height)
        XCTAssertEqual(view.displayMode, .singlePageContinuous)
        XCTAssertFalse(view.autoScales)
    }

    func testWidthResizeFitsThePageToTheAvailableWidth() throws {
        let document = try makeMultiPageDocument()
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let initialPageWidth = view.convert(firstPage.bounds(for: .cropBox), from: firstPage).width

        view.setFrameSize(NSSize(width: 1_040, height: 890))
        view.layoutSubtreeIfNeeded()

        let expandedPageWidth = view.convert(firstPage.bounds(for: .cropBox), from: firstPage).width
        XCTAssertGreaterThan(expandedPageWidth, initialPageWidth)
        XCTAssertEqual(view.bounds.width - expandedPageWidth, 64, accuracy: 1)
        XCTAssertLessThan(expandedPageWidth, view.bounds.width)
    }

    func testHeightOnlyResizeKeepsTheCurrentScale() throws {
        let document = try makeMultiPageDocument()
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let initialScale = view.scaleFactor

        view.setFrameSize(NSSize(width: 760, height: 1_100))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.scaleFactor, initialScale, accuracy: 0.001)
    }

    func testPlainSpaceAdvancesExactlyOnePage() throws {
        let document = try makeMultiPageDocument()
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        view.keyDown(with: space)

        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 1)
    }

    func testSettledInitialFitOverridesInterimRestoredPagePosition() async throws {
        let document = try makeMultiPageDocument()
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        view.goToNextPage(nil)
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 1)

        await nextMainQueueTurn()
        await nextMainQueueTurn()

        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 0)
    }

    func testOutboundPDFDragUsesADeferredPrimaryButtonPress() {
        let view = PageAdvancingPDFView()
        let recognizer = view.outboundPDFDragRecognizer

        XCTAssertEqual(recognizer.buttonMask, 0x1)
        XCTAssertEqual(recognizer.minimumPressDuration, NSEvent.doubleClickInterval)
        XCTAssertTrue(view.gestureRecognizers.contains { $0 === recognizer })
    }

    func testPDFFilePromiseAdvertisesPDFAndWritesExactBytes() throws {
        let expectedData = Data("exact preview bytes".utf8)
        let writer = PDFFilePromiseWriter(pdfData: expectedData, fileName: "Original Name.pdf")
        let provider = writer.makeProvider()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        var completionError: Error?

        XCTAssertEqual(provider.fileType, UTType.pdf.identifier)
        XCTAssertTrue(provider.userInfo as AnyObject === writer)
        XCTAssertEqual(
            writer.filePromiseProvider(provider, fileNameForType: provider.fileType),
            "Original Name.pdf"
        )
        XCTAssertEqual(writer.operationQueue(for: provider).maxConcurrentOperationCount, 1)

        writer.filePromiseProvider(provider, writePromiseTo: output) { completionError = $0 }

        XCTAssertNil(completionError)
        XCTAssertEqual(try Data(contentsOf: output), expectedData)
    }

    func testPDFFilePromiseReportsWriteFailures() {
        let writer = PDFFilePromiseWriter(pdfData: Data("PDF".utf8), fileName: "Failure.pdf")
        let provider = writer.makeProvider()
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Failure.pdf")
        var completionError: Error?

        writer.filePromiseProvider(provider, writePromiseTo: missingParent) { completionError = $0 }

        XCTAssertNotNil(completionError)
    }

    private func makeMultiPageDocument() throws -> PDFDocument {
        let markdown = (1...100)
            .map { "Paragraph \($0): Enough text to create several pages for preview navigation." }
            .joined(separator: "\n\n")
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 2)
        return document
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

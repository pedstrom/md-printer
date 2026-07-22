import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class PDFPreviewViewTests: XCTestCase {
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

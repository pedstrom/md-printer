import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class ExportDragThumbnailTests: XCTestCase {
    func testTextPageHasOpaquePaperAndVisibleEdgesInBothExportFormats() throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Drag preview", markdown: "# Drag preview\n\nA short document."))
        let document = try XCTUnwrap(PDFDocument(data: session.exportData(as: .pdf)))
        let page = try XCTUnwrap(document.page(at: 0))
        for format in ExportFormat.allCases {
            let image = ExportDragThumbnail.image(page: page, format: format)
            let pixels = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            let paper = try XCTUnwrap(pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(paper.alphaComponent, 1, accuracy: 0.01, "Blank paper must be visible before AppKit starts dragging.")
            XCTAssertEqual(paper.redComponent, 1, accuracy: 0.01)
            XCTAssertEqual(paper.greenComponent, 1, accuracy: 0.01)
            XCTAssertEqual(paper.blueComponent, 1, accuracy: 0.01)
            let edge = try XCTUnwrap(pixels.colorAt(x: 0, y: pixels.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(edge.alphaComponent, 1, accuracy: 0.01)
            XCTAssertLessThan(edge.redComponent, 0.9, "The miniature needs an outline against the white PDF preview.")
        }
    }

    func testBothFormatsKeepThePagePreviewAndAddDistinctReadableBadges() throws {
        let pageImage = NSImage(size: NSSize(width: 612, height: 792))
        pageImage.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 612, height: 792).fill()
        pageImage.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: pageImage))

        let pdf = ExportDragThumbnail.image(page: page, format: .pdf)
        let word = ExportDragThumbnail.image(page: page, format: .word)

        XCTAssertEqual(pdf.size, NSSize(width: 110, height: 142))
        XCTAssertEqual(word.size, pdf.size)
        XCTAssertEqual(pdf.accessibilityDescription, "PDF export")
        XCTAssertEqual(word.accessibilityDescription, "Microsoft Word export")
        let pdfPixels = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(pdf.tiffRepresentation)))
        let wordPixels = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(word.tiffRepresentation)))
        XCTAssertNotEqual(pdf.tiffRepresentation, word.tiffRepresentation)
        // The upper page content is retained in both formats, above the format badge.
        let x = pdfPixels.pixelsWide / 2
        let y = pdfPixels.pixelsHigh / 3
        XCTAssertEqual(pdfPixels.colorAt(x: x, y: y), wordPixels.colorAt(x: x, y: y))
        let contentColor = try XCTUnwrap(pdfPixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(contentColor.redComponent, contentColor.blueComponent)
    }

    func testBadgesRemainAvailableWithoutAPreviewPage() throws {
        for format in ExportFormat.allCases {
            let image = ExportDragThumbnail.image(page: nil, format: format)
            XCTAssertEqual(image.size, NSSize(width: 110, height: 142))
            XCTAssertEqual(image.accessibilityDescription, "\(format.displayName) export")
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }
}

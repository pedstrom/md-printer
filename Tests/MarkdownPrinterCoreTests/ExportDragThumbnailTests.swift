import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class ExportDragThumbnailTests: XCTestCase {
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

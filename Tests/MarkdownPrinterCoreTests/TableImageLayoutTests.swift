import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class TableImageLayoutTests: XCTestCase {
    func testLargeImagesStayInsideActualCellContentBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try imageData(size: NSSize(width: 1200, height: 900)).write(to: directory.appendingPathComponent("image.png"))
        for alignment in ["---", ":---:", "---:"] {
            let text = MarkdownRenderer().render(markdown: """
            | Left | Right |
            | \(alignment) | \(alignment) |
            | ![A](image.png) | ![B](image.png) |
            """, baseURL: directory)
            let storage = NSTextStorage(attributedString: text)
            let fitter = TableImageLayout(text: storage)
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(containerSize: NSSize(width: 504, height: 684))
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            XCTAssertTrue(fitter.fitWidths(using: manager, pageHeight: 684))
            manager.ensureLayout(for: container)
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment,
                      let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                      let cell = style.textBlocks.first as? NSTextTableBlock else { return }
                let glyph = manager.glyphIndexForCharacter(at: range.location)
                let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let position = manager.location(forGlyphAt: glyph)
                let ink = NSRect(x: line.minX + position.x + attachment.bounds.minX,
                                 y: line.minY + position.y - attachment.bounds.maxY,
                                 width: attachment.bounds.width, height: attachment.bounds.height)
                let layout = manager.layoutRect(for: cell, at: glyph, effectiveRange: nil)
                let bounds = manager.boundsRect(for: cell, at: glyph, effectiveRange: nil)
                XCTAssertGreaterThanOrEqual(ink.minX, layout.minX - 0.1)
                XCTAssertLessThanOrEqual(ink.maxX, layout.maxX + 0.1)
                XCTAssertGreaterThanOrEqual(ink.minY, bounds.minY)
                XCTAssertLessThanOrEqual(ink.maxY, bounds.maxY)
            }
        }
    }

    func testModestReductionKeepsFinalImageRowAndCaptionsOnThePage() async throws {
        try await checkTwoTables(lowerHeight: 900, expectedPages: 1)
    }

    func testLargerReductionMovesTheRowWithoutPaintingIntoTheFooter() async throws {
        try await checkTwoTables(lowerHeight: 1400, expectedPages: 2)
    }

    func testVeryTallImagesFitAFreshPageWithoutMutatingSourceAttachments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try imageData(size: NSSize(width: 400, height: 2000)).write(to: directory.appendingPathComponent("tall.png"))
        let text = MarkdownRenderer().render(markdown: """
        | Portrait | Portrait |
        | --- | --- |
        | ![A](tall.png) | ![B](tall.png) |
        | Caption | Caption |
        """, baseURL: directory)
        let original = attachmentBounds(in: text)
        let exporter = PDFExporter()
        let synchronous = try exporter.pdfData(from: text)
        let asynchronous = try await exporter.pdfDataAsync(from: text)
        for data in [synchronous, asynchronous] {
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, 1)
            XCTAssertTrue(document.string?.contains("Caption") == true)
            try assertBluePixelsInsideContent(document)
        }
        XCTAssertEqual(attachmentBounds(in: text), original)
    }

    func testHeadingMovesAcrossSeveralImageTablesKeepAllImagesInsideThePage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try imageData(size: NSSize(width: 800, height: 1000)).write(to: directory.appendingPathComponent("image.png"))
        let markdown = (1...4).map { index in
            """
            ## Comparison \(index)

            A short introduction to the next pair of screenshots.

            | Image | Image |
            | --- | --- |
            | ![Image](image.png) | ![Image](image.png) |
            | Caption \(index) | Caption \(index) |
            """
        }.joined(separator: "\n\n")
        let text = MarkdownRenderer().render(markdown: markdown, baseURL: directory)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        for index in 1...4 {
            let heading = try XCTUnwrap(document.findString("Comparison \(index)", withOptions: []).first)
            XCTAssertTrue(heading.pages.first?.string?.contains("Caption \(index)") == true)
        }
        try assertBluePixelsInsideContent(document)
    }

    private func checkTwoTables(lowerHeight: CGFloat, expectedPages: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try imageData(size: NSSize(width: 800, height: 800)).write(to: directory.appendingPathComponent("upper.png"))
        try imageData(size: NSSize(width: 800, height: lowerHeight)).write(to: directory.appendingPathComponent("lower.png"))
        let text = MarkdownRenderer().render(markdown: """
        # Image comparisons

        | Image | Image |
        | --- | --- |
        | ![Image](upper.png) | ![Image](upper.png) |
        | Upper caption | Upper caption |

        | Image | Image |
        | --- | --- |
        | ![Image](lower.png) | ![Image](lower.png) |
        | Lower caption | Lower caption |
        """, baseURL: directory)
        let original = attachmentBounds(in: text)
        let exporter = PDFExporter()
        let synchronous = try exporter.pdfData(from: text)
        let asynchronous = try await exporter.pdfDataAsync(from: text)
        let document = try XCTUnwrap(PDFDocument(data: synchronous))
        let asyncDocument = try XCTUnwrap(PDFDocument(data: asynchronous))
        XCTAssertEqual(document.pageCount, expectedPages)
        XCTAssertEqual(document.pageCount, asyncDocument.pageCount)
        XCTAssertEqual(document.string, asyncDocument.string)
        XCTAssertTrue(document.page(at: expectedPages - 1)?.string?.contains("Lower caption") == true)
        try assertBluePixelsInsideContent(document)
        try assertBluePixelsInsideContent(asyncDocument)
        XCTAssertEqual(attachmentBounds(in: text), original)
    }

    private func attachmentBounds(in text: NSAttributedString) -> [NSRect] {
        var result: [NSRect] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment.bounds) }
        }
        return result
    }

    private func assertBluePixelsInsideContent(_ document: PDFDocument) throws {
        let configuration = RendererConfiguration()
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(page.thumbnail(of: configuration.pageSize, for: .mediaBox).tiffRepresentation)))
            var count = 0
            var columns = [0, 0]
            var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.blueComponent > 0.5, color.blueComponent > color.redComponent + 0.3 else { continue }
                    count += 1
                    columns[x < 306 ? 0 : 1] += 1
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            XCTAssertGreaterThan(count, 1000)
            XCTAssertTrue(columns.allSatisfy { $0 > 500 }, "Both image columns must remain visible: \(columns)")
            XCTAssertGreaterThanOrEqual(minX, 54)
            XCTAssertLessThan(maxX, 558)
            XCTAssertGreaterThanOrEqual(minY, 54)
            XCTAssertLessThan(maxY, 738, "Image painted into the footer on page \(index + 1)")
        }
    }

    private func imageData(size: NSSize) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

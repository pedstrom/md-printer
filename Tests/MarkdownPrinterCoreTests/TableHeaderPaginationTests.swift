import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class TableHeaderPaginationTests: XCTestCase {
    func testTableHeaderMovesWithFirstDataRowInBothExportPaths() async throws {
        let rows = (1...70).map { "| Entry \($0) | Value \($0) |" }.joined(separator: "\n")
        let text = try boundaryText(table: "| Name | Value |\n| --- | --- |\n" + rows,
                                    header: "Name", missing: "Entry 1")
        let exporter = PDFExporter()
        let synchronous = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: text)))
        let asynchronousData = try await exporter.pdfDataAsync(from: text)
        let asynchronous = try XCTUnwrap(PDFDocument(data: asynchronousData))
        for document in [synchronous, asynchronous] {
            let headerPage = try page(containing: "Name", in: document)
            XCTAssertTrue(headerPage.string?.contains("Entry 1") == true)
            XCTAssertTrue(headerPage.string?.contains("Value 1") == true)
            XCTAssertTrue(document.string?.contains("Entry 70") == true)
            XCTAssertGreaterThan(document.pageCount, 2)
        }
        XCTAssertEqual(synchronous.pageCount, asynchronous.pageCount)
        XCTAssertEqual(synchronous.string, asynchronous.string)
    }

    func testWrappedAndEmptyHeadersStayWithCompleteFirstRow() throws {
        for header in ["", String(repeating: "Wrapped header text ", count: 8)] {
            let firstCell = "First row begins " + String(repeating: "wrapped cell content ", count: 12) + "FIRST-END"
            let text = try boundaryText(table: """
            | \(header) | Right header |
            | --- | --- |
            | \(firstCell) | Right first row |
            | Later row | Later value |
            """, header: "Right header", missing: "FIRST-END")
            let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
            let headerPage = try page(containing: "Right header", in: document)
            XCTAssertTrue(headerPage.string?.contains("First row begins") == true)
            XCTAssertTrue(headerPage.string?.contains("FIRST-END") == true)
            XCTAssertTrue(headerPage.string?.contains("Right first row") == true)
        }
    }

    func testAdjacentTablesKeepTheirOwnFirstRows() throws {
        let text = try boundaryText(table: """
        | First table header | First value |
        | --- | --- |
        | First entry | First data |

        | Second table header | Second value |
        | --- | --- |
        | Second entry | Second data |
        """, header: "Second table header", missing: "Second entry")
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        let firstPage = try page(containing: "First table header", in: document)
        let secondPage = try page(containing: "Second table header", in: document)
        XCTAssertTrue(firstPage.string?.contains("First entry") == true)
        XCTAssertTrue(secondPage.string?.contains("Second entry") == true)
        XCTAssertTrue(secondPage.string?.contains("Second data") == true)
        XCTAssertFalse(firstPage === secondPage)
    }

    func testImageRowMovesWithItsTableHeader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 200, height: 280))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 280)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("sample.png"))
        let text = try boundaryText(table: """
        | Category selection | Vendor selection |
        | --- | --- |
        | ![Category](sample.png) IMAGELEFT | ![Vendor](sample.png) IMAGERIGHT |
        | Left caption | Right caption |
        """, header: "Category selection", missing: "IMAGELEFT", baseURL: directory)
        let exporter = PDFExporter()
        for data in [try exporter.pdfData(from: text), try await exporter.pdfDataAsync(from: text)] {
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, 2)
            let headerPage = try page(containing: "Category selection", in: document)
            for marker in ["Vendor selection", "IMAGELEFT", "IMAGERIGHT", "Left caption", "Right caption"] {
                XCTAssertTrue(headerPage.string?.contains(marker) == true, "\(marker): \(headerPage.string ?? "")")
            }
        }
    }

    func testHeaderOnlyTablesAndOversizedOpeningsDoNotCreateFutilePages() async throws {
        let headerOnly = "| Name | Value |\n| --- | --- |"
        let oversized = "| " + String(repeating: "Name<br>", count: 10) + "Header end |\n| --- |\n| "
            + String(repeating: "Tall cell content<br>", count: 35) + "ENDROW |"
        for markdown in [headerOnly, oversized] {
            let text = MarkdownRenderer().render(markdown: markdown)
            let exporter = PDFExporter()
            let synchronous = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: text)))
            let asynchronousData = try await exporter.pdfDataAsync(from: text)
            let asynchronous = try XCTUnwrap(PDFDocument(data: asynchronousData))
            XCTAssertTrue(synchronous.page(at: 0)?.string?.contains("Name") == true)
            XCTAssertEqual(synchronous.pageCount, asynchronous.pageCount)
            XCTAssertEqual(synchronous.string, asynchronous.string)
            if markdown == headerOnly {
                XCTAssertEqual(synchronous.pageCount, 1)
            } else {
                XCTAssertTrue(synchronous.string?.contains("ENDROW") == true)
                XCTAssertEqual(synchronous.pageCount, 2)
            }
        }
    }

    func testTableProtectionAlsoAppliesBeyondTheHeadingScanLimit() throws {
        let text = NSMutableAttributedString(attributedString: try boundaryText(table: """
        | Large document header | Value |
        | --- | --- |
        | First entry | First value |
        """, header: "Large document header", missing: "First entry"))
        text.append(MarkdownRenderer().render(markdown: "\n\n" + String(repeating: "Body text. ", count: 24_000)))
        XCTAssertGreaterThan(text.length, 250_000)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertTrue(try page(containing: "Large document header", in: document).string?.contains("First entry") == true)
    }

    // Find a real TextKit boundary without applying the exporter's pagination corrections.
    private func boundaryText(table: String, header: String, missing: String,
                              baseURL: URL? = nil) throws -> NSAttributedString {
        let configuration = RendererConfiguration()
        for fillerCount in 1...50 {
            let markdown = String(repeating: "Filler line.\n", count: fillerCount) + "\n" + table
            let text = MarkdownRenderer().render(markdown: markdown, baseURL: baseURL)
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(containerSize: NSSize(
                width: configuration.contentWidth,
                height: configuration.pageSize.height - configuration.pageMargins.top - configuration.pageMargins.bottom
            ))
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let range = manager.characterRange(forGlyphRange: manager.glyphRange(for: container), actualGlyphRange: nil)
            let firstPage = (text.string as NSString).substring(with: range)
            if firstPage.contains(header), !firstPage.contains(missing) { return text }
        }
        return try XCTUnwrap(nil, "Could not reproduce a natural table-header boundary.")
    }

    private func page(containing marker: String, in document: PDFDocument) throws -> PDFPage {
        try XCTUnwrap((0..<document.pageCount).compactMap { document.page(at: $0) }
            .first { $0.string?.contains(marker) == true })
    }
}

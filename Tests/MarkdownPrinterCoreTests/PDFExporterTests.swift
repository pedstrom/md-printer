import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class PDFExporterTests: XCTestCase {
    func testGeneratesLetterPDFWithSearchableAvenirText() throws {
        let renderer = MarkdownRenderer()
        let data = try PDFExporter().pdfData(from: renderer.render(markdown: "# Report\n\nHello **world**."))
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 0.5)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 792, accuracy: 0.5)
        XCTAssertTrue(page.string?.contains("Report") == true)
        XCTAssertTrue(page.string?.contains("Hello world") == true)
        let headingSelection = try XCTUnwrap(document.findString("Report", withOptions: []).first)
        XCTAssertGreaterThan(headingSelection.bounds(for: page).midY, 600, "The first heading should render upright near the top margin.")
    }

    func testLongDocumentPaginates() throws {
        let markdown = (1...180).map { "Paragraph \($0): Enough text to occupy a line in the rendered document." }.joined(separator: "\n\n")
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 2)
        XCTAssertTrue(document.page(at: document.pageCount - 1)?.string?.contains("Paragraph 180") == true)
    }

    func testLongTablePaginatesAndStaysSearchable() throws {
        let rows = (1...70).map { "| Row \($0) | Value \($0) |" }.joined(separator: "\n")
        let markdown = "| Name | Value |\n| --- | ---: |\n" + rows
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1)
        let allText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        XCTAssertTrue(allText.contains("Row 1"))
        XCTAssertTrue(allText.contains("Row 70"))
    }

    func testPDFPreservesLinkAnnotation() throws {
        let text = MarkdownRenderer().render(markdown: "[OpenAI](https://openai.com)")
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        let annotations = try XCTUnwrap(document.page(at: 0)).annotations
        XCTAssertTrue(annotations.contains(where: { $0.url?.absoluteString == "https://openai.com" }))
    }

    func testFencedCodeBlockRendersWithoutStallingPagination() throws {
        let text = MarkdownRenderer().render(markdown: "```swift\nlet answer = 42\nprint(answer)\n```")
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("let answer = 42") == true)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("print(answer)") == true)
    }

    func testWriteAndPrintExistingPDF() throws {
        let exporter = PDFExporter()
        let text = MarkdownRenderer().render(markdown: "Printable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.pdf")
        try exporter.write(text, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(PDFDocument(data: data))
        XCTAssertNotNil(try exporter.printOperation(forPDFData: data).view)
        XCTAssertThrowsError(try exporter.printOperation(forPDFData: Data([0x00])))
    }

    func testEmptyAttributedStringStillCreatesOnePage() throws {
        let data = try PDFExporter().pdfData(from: NSAttributedString(string: ""))
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
    }
}

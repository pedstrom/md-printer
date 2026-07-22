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

    func testEveryPageHasASequentialCenteredFooterNumber() throws {
        let markdown = Array(
            repeating: "A paragraph without digits that occupies space in the rendered document.",
            count: 180
        ).joined(separator: "\n\n")
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 2)

        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let pageNumber = String(pageIndex + 1)
            XCTAssertEqual(page.string?.split(whereSeparator: \.isWhitespace).last.map(String.init), pageNumber)
            let selection = try XCTUnwrap(
                document.findString(pageNumber, withOptions: []).first(where: { $0.pages.contains(page) })
            )
            let bounds = selection.bounds(for: page)
            XCTAssertEqual(bounds.midX, page.bounds(for: .mediaBox).midX, accuracy: 1)
            XCTAssertLessThan(bounds.maxY, 54)
        }
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

    func testWrappedQuotationRendersAndRemainsSearchable() throws {
        let markdown = "> A quoted passage long enough to wrap onto another visible line while retaining one continuous left border."
        let text = MarkdownRenderer().render(markdown: markdown)
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 1)
        let extractedText = try XCTUnwrap(document.page(at: 0)?.string)
        let normalizedText = extractedText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(normalizedText.contains("A quoted passage"))
        XCTAssertTrue(normalizedText.contains("continuous"))
        XCTAssertTrue(normalizedText.contains("left border"), "Extracted quotation: \(extractedText)")
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
        let operation = try exporter.printOperation(forPDFData: data)
        XCTAssertNotNil(operation.view)
        XCTAssertEqual(operation.printInfo.paperSize.width, 612, accuracy: 0.5)
        XCTAssertEqual(operation.printInfo.paperSize.height, 792, accuracy: 0.5)
        XCTAssertEqual(operation.printInfo.topMargin, 0)
        XCTAssertEqual(operation.printInfo.leftMargin, 0)
        XCTAssertEqual(operation.printInfo.bottomMargin, 0)
        XCTAssertEqual(operation.printInfo.rightMargin, 0)
        XCTAssertThrowsError(try exporter.printOperation(forPDFData: Data([0x00])))
    }

    func testPrintToPDFPreservesPreviewPageAndContentPosition() throws {
        let exporter = PDFExporter()
        let paragraphs = (1...90)
            .map { "Paragraph \($0): Printing must preserve every generated page without adding another layout pass." }
            .joined(separator: "\n\n")
        let previewData = try exporter.pdfData(
            from: MarkdownRenderer().render(markdown: "# Print fidelity\n\n\(paragraphs)")
        )
        let previewDocument = try XCTUnwrap(PDFDocument(data: previewData))
        XCTAssertGreaterThan(previewDocument.pageCount, 1)
        let previewPage = try XCTUnwrap(previewDocument.page(at: 0))
        let previewHeading = try XCTUnwrap(previewDocument.findString("Print fidelity", withOptions: []).first)
            .bounds(for: previewPage)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let printedURL = directory.appendingPathComponent("printed.pdf")

        let operation = try exporter.printOperation(forPDFData: previewData)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = printedURL
        XCTAssertTrue(operation.run())

        let printedDocument = try XCTUnwrap(PDFDocument(url: printedURL))
        XCTAssertEqual(printedDocument.pageCount, previewDocument.pageCount)
        let printedPage = try XCTUnwrap(printedDocument.page(at: 0))
        let printedHeading = try XCTUnwrap(printedDocument.findString("Print fidelity", withOptions: []).first)
            .bounds(for: printedPage)

        XCTAssertEqual(printedPage.bounds(for: .mediaBox).width, previewPage.bounds(for: .mediaBox).width, accuracy: 0.5)
        XCTAssertEqual(printedPage.bounds(for: .mediaBox).height, previewPage.bounds(for: .mediaBox).height, accuracy: 0.5)
        XCTAssertEqual(printedHeading.minX, previewHeading.minX, accuracy: 0.5)
        XCTAssertEqual(printedHeading.maxY, previewHeading.maxY, accuracy: 0.5)
        XCTAssertTrue(printedDocument.page(at: printedDocument.pageCount - 1)?.string?.contains("Paragraph 90") == true)
    }

    func testEmptyAttributedStringStillCreatesOnePage() throws {
        let data = try PDFExporter().pdfData(from: NSAttributedString(string: ""))
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
    }
}

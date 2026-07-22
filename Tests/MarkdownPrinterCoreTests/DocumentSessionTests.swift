import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class DocumentSessionTests: XCTestCase {
    func testInitialStateAndNoDocumentErrors() throws {
        let session = DocumentSession()
        XCTAssertEqual(session.title, "Markdown Printer")
        XCTAssertFalse(session.hasDocument)
        XCTAssertThrowsError(try session.pdfData()) { XCTAssertEqual($0 as? DocumentSessionError, .noDocument) }
        XCTAssertThrowsError(try session.savePDF(to: FileManager.default.temporaryDirectory.appendingPathComponent("none.pdf")))
        XCTAssertThrowsError(try session.printOperation())
        XCTAssertEqual(DocumentSessionError.noDocument.localizedDescription, "Open a Markdown file before saving or printing.")
    }

    func testApplyCreatesPreviewPDFAndClearsError() throws {
        let session = DocumentSession()
        session.report(error: TestError.example)
        try session.apply(MarkdownDocument(title: "Sample", markdown: "# Sample"))
        XCTAssertEqual(session.title, "Sample")
        XCTAssertTrue(session.hasDocument)
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.renderedText.string.contains("Sample"))
        XCTAssertNotNil(PDFDocument(data: try session.pdfData()))
        session.report(error: TestError.example)
        XCTAssertEqual(session.errorMessage, "Example failure")
        session.clearError()
        XCTAssertNil(session.errorMessage)
    }

    func testLoadDataHandlesValidAndInvalidInput() {
        let session = DocumentSession()
        session.load(data: Data("# Markdown Title\n\nBody".utf8), suggestedTitle: "Filename")
        XCTAssertEqual(session.title, "Markdown Title")
        session.load(data: Data([0xFF]))
        XCTAssertEqual(session.errorMessage, "The file is not valid UTF-8 or UTF-16 text.")
        XCTAssertEqual(session.title, "Markdown Title")
    }

    func testLoadURLSaveAndPrint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Input.md")
        let output = directory.appendingPathComponent("Output.pdf")
        try Data("# From File".utf8).write(to: input)

        let session = DocumentSession()
        session.load(url: input)
        XCTAssertEqual(session.title, "From File")
        try session.savePDF(to: output)
        XCTAssertNotNil(PDFDocument(url: output))
        XCTAssertNotNil(try session.printOperation().view)

        session.load(url: directory.appendingPathComponent("missing.md"))
        XCTAssertNotNil(session.errorMessage)
    }
}

private enum TestError: LocalizedError {
    case example
    var errorDescription: String? { "Example failure" }
}

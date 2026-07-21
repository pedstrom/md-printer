import Foundation
import XCTest
@testable import MarkdownPrinterCore

final class MarkdownDocumentTests: XCTestCase {
    func testDecodeUTF8AndSuggestedTitle() throws {
        let document = try MarkdownDocument.decode(
            data: Data("# Hello".utf8),
            suggestedTitle: "Greeting"
        )
        XCTAssertEqual(document, MarkdownDocument(title: "Greeting", markdown: "# Hello"))
        XCTAssertNil(document.baseURL)
    }

    func testLoadUsesFilenameAndBaseURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("My Notes.md")
        try Data("Body".utf8).write(to: url)

        let document = try MarkdownDocument.load(from: url)
        XCTAssertEqual(document.title, "My Notes")
        XCTAssertEqual(document.markdown, "Body")
        XCTAssertEqual(document.sourceURL, url)
        XCTAssertEqual(document.baseURL, directory)
    }

    func testDecodeUTF16AndRejectsBinary() throws {
        let utf16 = "Unicode ✓".data(using: .utf16)!
        XCTAssertEqual(try MarkdownDocument.decode(data: utf16).markdown, "Unicode ✓")
        XCTAssertThrowsError(try MarkdownDocument.decode(data: Data([0xFF]))) { error in
            XCTAssertEqual(error as? MarkdownDocumentError, .unsupportedTextEncoding)
            XCTAssertEqual(error.localizedDescription, "The file is not valid UTF-8 or UTF-16 text.")
        }
    }
}

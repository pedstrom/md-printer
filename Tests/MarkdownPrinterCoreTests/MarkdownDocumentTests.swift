import Foundation
import XCTest
@testable import MarkdownPrinterCore

final class MarkdownDocumentTests: XCTestCase {
    func testDecodeUsesH1BeforeSuggestedTitle() throws {
        let document = try MarkdownDocument.decode(
            data: Data("# **Hello** `Report`".utf8),
            suggestedTitle: "Greeting"
        )
        XCTAssertEqual(document.title, "Hello Report")
        XCTAssertEqual(document.markdown, "# **Hello** `Report`")
        XCTAssertNil(document.baseURL)
    }

    func testDecodeUsesSuggestedTitleWithoutAnH1() throws {
        let document = try MarkdownDocument.decode(
            data: Data("## Secondary heading\n\nBody".utf8),
            suggestedTitle: "Filename"
        )
        XCTAssertEqual(document.title, "Filename")
    }

    func testH1TitleFlattensOtherInlineFormatting() throws {
        let markdown = "# *Quarterly* <u>Status</u> ~~Draft~~ [Plan](https://example.com) ![Icon](icon.png)"
        let document = try MarkdownDocument.decode(data: Data(markdown.utf8))
        XCTAssertEqual(document.title, "Quarterly Status Draft Plan Icon")
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

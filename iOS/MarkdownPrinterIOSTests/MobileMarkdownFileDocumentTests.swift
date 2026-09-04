import XCTest
import SwiftUI
import MarkdownPrinterCore
import UniformTypeIdentifiers
@testable import MarkdownPrinterIOS

final class MobileMarkdownFileDocumentTests: XCTestCase {
    func testDocumentDecodesDataAndUsesSourceFilenameAndHeading() throws {
        let data = Data("# Visible Heading\n\nBody".utf8)
        let file = try MobileMarkdownFileDocument(data: data)
        let sourceURL = URL(fileURLWithPath: "/tmp/Filename.mdown")

        let document = file.markdownDocument(sourceURL: sourceURL)

        XCTAssertEqual(document.title, "Visible Heading")
        XCTAssertEqual(document.sourceURL, sourceURL)
        XCTAssertEqual(document.markdown, "# Visible Heading\n\nBody")
        XCTAssertEqual(MobileMarkdownFileDocument.readableContentTypes.count, 1)
        XCTAssertEqual(
            MobileMarkdownFileDocument.markdownContentType.identifier,
            "net.daringfireball.markdown"
        )
    }

    func testDocumentWithoutHeadingUsesFilenameAndRejectsInvalidEncoding() throws {
        let file = try MobileMarkdownFileDocument(data: Data("Plain text".utf8))
        XCTAssertEqual(
            file.markdownDocument(sourceURL: URL(fileURLWithPath: "/tmp/Read Me.mkd")).title,
            "Read Me"
        )
        XCTAssertThrowsError(try MobileMarkdownFileDocument(data: Data([0x80, 0x81])))
    }

    func testShareStoreWritesNamedTemporaryPDF() throws {
        let data = Data("%PDF-test".utf8)
        let url = try MobilePDFShareStore.write(data: data, filename: "Shared.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "Shared.pdf")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testStoreSampleCreatesLocalMarkdownWithoutOverwritingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPrinterSampleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = try AppStoreSampleDocument.ensureExists(in: directory)
        XCTAssertEqual(firstURL.lastPathComponent, "Markdown Printer Sample.md")
        XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), AppStoreSampleDocument.markdown)
        XCTAssertTrue(AppStoreSampleDocument.markdown.contains("# Welcome to Markdown Printer"))
        XCTAssertTrue(AppStoreSampleDocument.markdown.contains("does not upload"))

        try Data("User-edited sample".utf8).write(to: firstURL, options: .atomic)
        let secondURL = try AppStoreSampleDocument.ensureExists(in: directory)
        XCTAssertEqual(secondURL, firstURL)
        XCTAssertEqual(try String(contentsOf: secondURL, encoding: .utf8), "User-edited sample")
    }

    func testAppInformationUsesPublicHTTPSDestinations() {
        XCTAssertEqual(MarkdownPrinterAppInformation.privacyPolicyURL.scheme, "https")
        XCTAssertEqual(MarkdownPrinterAppInformation.supportURL.scheme, "https")
        XCTAssertEqual(MarkdownPrinterAppInformation.sourceURL.host, "github.com")
        XCTAssertTrue(
            MarkdownPrinterAppInformation.privacyPolicyURL.path.hasSuffix("docs/privacy-policy.md")
        )
        XCTAssertTrue(
            MarkdownPrinterAppInformation.supportURL.path.hasSuffix("docs/ios-support.md")
        )
    }

    func testPDFActivityItemRoutesBytesToPrintAndFileURLToOtherDestinations() {
        let data = Data("%PDF-test".utf8)
        let url = URL(fileURLWithPath: "/tmp/Shared.pdf")
        let item = MobilePDFActivityItem(data: data, fileURL: url)

        XCTAssertEqual(item.placeholderItem as? URL, url)
        XCTAssertEqual(item.item(for: .print) as? Data, data)
        XCTAssertEqual(item.item(for: .mail) as? URL, url)
        XCTAssertEqual(item.dataTypeIdentifier, UTType.pdf.identifier)
    }
}

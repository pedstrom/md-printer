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

    func testPDFFileDocumentRetainsData() {
        let data = Data("%PDF-test".utf8)
        let document = MobilePDFFileDocument(data: data)
        XCTAssertEqual(document.data, data)
        XCTAssertEqual(MobilePDFFileDocument.readableContentTypes, [.pdf])
    }

    func testShareStoreWritesNamedTemporaryPDF() throws {
        let data = Data("%PDF-test".utf8)
        let url = try MobilePDFShareStore.write(data: data, filename: "Shared.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "Shared.pdf")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor
    func testPDFActivityItemSuppliesBytesToPrintAndFileURLToOtherDestinations() {
        let data = Data("%PDF-test".utf8)
        let url = URL(fileURLWithPath: "/tmp/Shared.pdf")
        let item = MobilePDFActivityItem(data: data, fileURL: url)
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)

        XCTAssertEqual(
            item.activityViewControllerPlaceholderItem(controller) as? URL,
            url
        )
        XCTAssertEqual(
            item.activityViewController(controller, itemForActivityType: .print) as? Data,
            data
        )
        XCTAssertEqual(
            item.activityViewController(controller, itemForActivityType: .mail) as? URL,
            url
        )
        XCTAssertEqual(
            item.activityViewController(
                controller,
                dataTypeIdentifierForActivityType: .print
            ),
            UTType.pdf.identifier
        )
    }
}

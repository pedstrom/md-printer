import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownPrinterUI

final class MultiDocumentTests: XCTestCase {
    func testMarkdownFileDocumentPreservesSourceAndHeadingTitle() throws {
        let sourceURL = URL(fileURLWithPath: "/tmp/report.md")
        let fileDocument = try MarkdownFileDocument(data: Data("# Report Title\n\nBody".utf8))

        let document = fileDocument.markdownDocument(sourceURL: sourceURL)

        XCTAssertEqual(document.sourceURL, sourceURL)
        XCTAssertEqual(document.title, "Report Title")
        XCTAssertEqual(document.markdown, "# Report Title\n\nBody")
        XCTAssertEqual(MarkdownFileDocument.readableContentTypes, [MarkdownFileDocument.markdownContentType])
    }

    func testMarkdownFileDocumentRejectsInvalidText() {
        XCTAssertThrowsError(try MarkdownFileDocument(data: Data([0xFF])))
    }

    func testDropLoaderCollectsEveryFileURLInProviderOrder() async {
        let urls = [URL(fileURLWithPath: "/tmp/one.md"), URL(fileURLWithPath: "/tmp/two.md")]
        let providers = urls.map(makeFileProvider)
        let unrelatedProvider = NSItemProvider(object: "not a file" as NSString)

        XCTAssertTrue(DroppedFileLoader.accepts(providers))
        XCTAssertFalse(DroppedFileLoader.accepts([unrelatedProvider]))
        let loadedURLs = await DroppedFileLoader.urls(from: [providers[0], unrelatedProvider, providers[1]])

        XCTAssertEqual(loadedURLs, urls)
    }

    private func makeFileProvider(url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }
}

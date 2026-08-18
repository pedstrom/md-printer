import Foundation
import XCTest
@testable import MarkdownPrinterUI

final class MarkdownPrinterViewTests: XCTestCase {
    func testWelcomeArtworkLoadsTheApprovedDocumentIconSource() throws {
        let sourceURL = repositoryRoot
            .appendingPathComponent("Resources/MarkdownDocumentIcon.png")
        let image = try XCTUnwrap(MarkdownPrinterWelcomeArtwork.image(at: sourceURL))

        XCTAssertEqual(MarkdownPrinterWelcomeArtwork.resourceName, "MarkdownDocumentIcon")
        XCTAssertEqual(MarkdownPrinterWelcomeArtwork.resourceExtension, "icns")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testWelcomeArtworkReturnsNilForAMissingResource() {
        let missingURL = URL(fileURLWithPath: "/private/tmp/missing-markdown-document-icon")

        XCTAssertNil(MarkdownPrinterWelcomeArtwork.image(at: missingURL))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

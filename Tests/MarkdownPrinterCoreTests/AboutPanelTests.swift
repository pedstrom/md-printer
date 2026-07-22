import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class AboutPanelTests: XCTestCase {
    func testAboutPanelCreditsLinkToTheRepositoryLicense() throws {
        let credits = try XCTUnwrap(
            AboutPanel.options[.credits] as? NSAttributedString
        )
        var effectiveRange = NSRange(location: 0, length: 0)

        XCTAssertEqual(credits.string, AboutPanel.licenseLinkText)
        XCTAssertEqual(
            credits.attribute(.link, at: 0, effectiveRange: &effectiveRange) as? URL,
            AboutPanel.licenseURL
        )
        XCTAssertEqual(effectiveRange, NSRange(location: 0, length: credits.length))
        XCTAssertEqual(
            (credits.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle)?.alignment,
            .center
        )
    }

    func testShowPassesTheLicenseOptionsToThePresenter() {
        var presentedCredits: NSAttributedString?

        AboutPanel.show { options in
            presentedCredits = options[.credits] as? NSAttributedString
        }

        XCTAssertEqual(presentedCredits?.string, AboutPanel.licenseLinkText)
    }
}

import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class AboutPanelTests: XCTestCase {
    func testAboutPanelCreditsLinkToReleaseHistoryAboveTheRepositoryLicense() throws {
        let credits = try XCTUnwrap(
            AboutPanel.options[.credits] as? NSAttributedString
        )
        XCTAssertEqual(credits.string, "Release Notes\nMIT License on GitHub")
        let links = [
            ("Release Notes", "https://github.com/pedstrom/md-printer/releases"),
            ("MIT License on GitHub", "https://github.com/pedstrom/md-printer/blob/main/LICENSE")
        ]
        for (title, destination) in links {
            let range = (credits.string as NSString).range(of: title)
            var effectiveRange = NSRange(location: 0, length: 0)
            XCTAssertEqual(
                (credits.attribute(.link, at: range.location, effectiveRange: &effectiveRange)
                    as? URL)?.absoluteString,
                destination
            )
            XCTAssertEqual(effectiveRange, range)
            XCTAssertEqual(
                (credits.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle)?.alignment,
                .center
            )
        }
        XCTAssertNil(credits.attribute(.link, at: "Release Notes".utf16.count, effectiveRange: nil))
    }

    func testShowPassesReleaseNotesAndLicenseOptionsToThePresenter() {
        var presentedCredits: NSAttributedString?

        AboutPanel.show { options in
            presentedCredits = options[.credits] as? NSAttributedString
        }

        XCTAssertEqual(presentedCredits?.string, "Release Notes\nMIT License on GitHub")
    }
}

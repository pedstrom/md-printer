import AppKit
import XCTest
@testable import MarkdownPrinterCore

final class PageConfigurationTests: XCTestCase {
    func testPageSetupValidatesPersistsAndAppliesOrientationAndScale() throws {
        let setup = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .landscape,
            scale: 1.25
        )

        XCTAssertEqual(setup.pageSize.width, 842)
        XCTAssertEqual(setup.pageSize.height, 595)
        XCTAssertEqual(setup.scalePercentage, 125)
        XCTAssertEqual(
            try JSONDecoder().decode(
                DocumentPageSetup.self,
                from: JSONEncoder().encode(setup)
            ),
            setup
        )

        let configuration = RendererConfiguration().applying(setup)
        XCTAssertEqual(configuration.pageSize, CGSize(width: 842, height: 595))
        XCTAssertEqual(configuration.pageMargins.top, 54)
        XCTAssertEqual(configuration.bodyFontSize, 12.5)
        XCTAssertEqual(configuration.headingFontSizes.first, 32.5)
        XCTAssertEqual(configuration.maximumImageWidth, 734)
    }

    func testInvalidPageSetupFallsBackToLetterPortraitAtOneHundredPercent() {
        let setup = DocumentPageSetup(
            paperName: "",
            paperSize: CGSize(width: CGFloat.infinity, height: -1),
            orientation: .landscape,
            scale: .nan
        )

        XCTAssertEqual(setup, DocumentPageSetup.letter)
        XCTAssertEqual(setup.pageSize, CGSize(width: 612, height: 792))
        XCTAssertEqual(setup.scalePercentage, 100)
    }

    func testFooterValuesResolveMetadataAndNormalizeCustomText() {
        let date = Date(timeIntervalSince1970: 1_767_355_200) // 2026-01-02 12:00 UTC
        let document = MarkdownDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/Notes.final.md"),
            sourceModificationDate: date,
            title: "Fallback",
            markdown: "# Document Title"
        )
        let locale = Locale(identifier: "en_US")
        let timeZone = TimeZone(secondsFromGMT: 0)!

        XCTAssertEqual(FooterValue.none.resolved(for: document), "")
        XCTAssertEqual(FooterValue.documentTitle.resolved(for: document), "Document Title")
        XCTAssertEqual(FooterValue.filename.resolved(for: document), "Notes.final.md")
        XCTAssertEqual(
            FooterValue.custom("First\nSecond\r\nThird\tValue").normalized,
            .custom("First Second Third Value")
        )
        XCTAssertEqual(
            FooterValue.date.resolved(for: document, locale: locale, timeZone: timeZone),
            "Jan 2, 2026"
        )
        XCTAssertTrue(
            FooterValue.dateTime
                .resolved(for: document, locale: locale, timeZone: timeZone)
                .hasPrefix("Jan 2, 2026")
        )

        let unavailable = MarkdownDocument(title: "Untitled", markdown: "Body")
        XCTAssertEqual(FooterValue.date.resolved(for: unavailable), "")
        XCTAssertEqual(FooterValue.dateTime.resolved(for: unavailable), "")
        XCTAssertEqual(FooterValue.filename.resolved(for: unavailable), "")
    }

    func testFooterMenuLabelsAndResolvedCustomValueCoverEveryChoice() {
        XCTAssertEqual(
            FooterValue.menuValues.map(\.displayName),
            ["None", "Date", "Date & Time", "Document Title", "Filename", "Custom…"]
        )
        XCTAssertEqual(
            FooterValue.custom("Already normalized").resolved(
                for: MarkdownDocument(title: "Title", markdown: "Body")
            ),
            "Already normalized"
        )
    }
}

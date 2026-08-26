import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class PagePreferencesTests: XCTestCase {
    func testPreferencesDefaultPersistAndNormalizeFooterText() throws {
        let suite = "PagePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PagePreferences(defaults: defaults)

        XCTAssertEqual(first.defaultPageSetup, .letter)
        XCTAssertEqual(first.leftFooter, .none)
        XCTAssertEqual(first.rightFooter, .none)

        first.defaultPageSetup = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .landscape,
            scale: 0.8
        )
        first.leftFooter = .dateTime
        first.rightFooter = .custom("Pete\nEdstrom")

        let reloaded = PagePreferences(defaults: defaults)
        XCTAssertEqual(reloaded.defaultPageSetup, first.defaultPageSetup)
        XCTAssertEqual(reloaded.leftFooter, .dateTime)
        XCTAssertEqual(reloaded.rightFooter, .custom("Pete Edstrom"))
    }

    func testResolvedFootersUseTheSameDocumentMetadata() {
        let suite = "PagePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PagePreferences(defaults: defaults)
        preferences.leftFooter = .documentTitle
        preferences.rightFooter = .filename
        let document = MarkdownDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/Source.markdown"),
            title: "Source",
            markdown: "# Heading"
        )

        XCTAssertEqual(
            preferences.resolvedFooters(for: document),
            ResolvedFooterConfiguration(left: "Heading", right: "Source.markdown")
        )
    }
}

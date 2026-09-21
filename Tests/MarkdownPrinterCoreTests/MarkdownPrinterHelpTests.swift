import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class MarkdownPrinterHelpTests: XCTestCase {
    func testNavigatorRoutesOverviewAndShortcutsThroughOneRevisionedDestination() {
        let navigator = MarkdownPrinterHelpNavigator()

        XCTAssertEqual(navigator.destination, .overview)
        XCTAssertEqual(navigator.destination.sectionID, .overview)
        XCTAssertEqual(navigator.requestRevision, 0)

        navigator.show(.shortcuts)
        XCTAssertEqual(navigator.destination, .shortcuts)
        XCTAssertEqual(navigator.destination.sectionID, .keyboardShortcuts)
        XCTAssertEqual(navigator.requestRevision, 1)

        navigator.show(.overview)
        XCTAssertEqual(navigator.destination, .overview)
        XCTAssertEqual(navigator.requestRevision, 2)
    }

    func testHelpCoversEveryRequestedTopic() {
        let text = MarkdownPrinterHelpContent.searchableText
        let requiredPhrases = [
            "Open Markdown Files",
            "Save, Share, and Drag Exports",
            "Hold Option when dragging from the preview or clicking Share",
            "Navigate and Zoom the Preview",
            "Search",
            "Thumbnails",
            "Windows, Tabs, and Reopening",
            "Reopen Windows from Last Session",
            "Page Setup, Footers, and Printing",
            "Show in Finder",
            "Quick Look",
            "remote images",
            "Download All Images",
            "disposable cache",
            "Quick Look stays offline",
            "Document content stays on this Mac",
            "Keyboard Shortcuts"
        ]

        for phrase in requiredPhrases {
            XCTAssertTrue(text.contains(phrase), "Missing help topic: \(phrase)")
        }
        XCTAssertFalse(text.contains("http://"))
        XCTAssertFalse(text.contains("https://"))
    }

    func testShortcutReferenceDocumentsEveryAppSpecificEquivalentAndAlternative() {
        let shortcuts = Dictionary(
            uniqueKeysWithValues: MarkdownPrinterHelpContent.shortcuts.map { ($0.action, $0) }
        )

        XCTAssertEqual(shortcuts["New Window"]?.keys, "⌘N")
        XCTAssertEqual(shortcuts["New Tab"]?.keys, "⌘T")
        XCTAssertEqual(shortcuts["Save Export"]?.keys, "⌘S")
        XCTAssertEqual(shortcuts["Save As"]?.keys, "⇧⌘S")
        XCTAssertEqual(shortcuts["Page Setup"]?.keys, "⇧⌘P")
        XCTAssertEqual(shortcuts["Print"]?.keys, "⌘P")
        XCTAssertEqual(shortcuts["Find"]?.keys, "⌘F")
        XCTAssertEqual(shortcuts["Find Next"]?.keys, "⌘G")
        XCTAssertEqual(shortcuts["Find Previous"]?.keys, "⇧⌘G")
        XCTAssertEqual(shortcuts["Actual Size"]?.keys, "⌘0")
        XCTAssertEqual(shortcuts["Zoom to Fit"]?.keys, "⌘9")
        XCTAssertEqual(shortcuts["Zoom In"]?.keys, "⌘+ or ⌘=")
        XCTAssertEqual(shortcuts["Zoom Out"]?.keys, "⌘−")
        XCTAssertEqual(shortcuts["Previous Page"]?.keys, "⌥↑ or ⇧Space")
        XCTAssertEqual(shortcuts["Next Page"]?.keys, "⌥↓ or Space")
    }

    func testEveryShortcutHasACompleteAccessibilityLabel() {
        for shortcut in MarkdownPrinterHelpContent.shortcuts {
            XCTAssertFalse(shortcut.action.isEmpty)
            XCTAssertFalse(shortcut.keys.isEmpty)
            XCTAssertEqual(
                shortcut.accessibilityLabel,
                "\(shortcut.action): \(shortcut.spokenKeys)"
            )
        }
    }

    func testHelpSectionIdentifiersAreUniqueAndIncludeBothMenuDestinations() {
        let sectionIDs = MarkdownPrinterHelpContent.sections.map(\.id)

        XCTAssertEqual(Set(sectionIDs).count, sectionIDs.count)
        XCTAssertTrue(sectionIDs.contains(MarkdownPrinterHelpDestination.overview.sectionID))
        XCTAssertTrue(sectionIDs.contains(MarkdownPrinterHelpDestination.shortcuts.sectionID))
        XCTAssertEqual(
            Set(sectionIDs),
            Set(MarkdownPrinterHelpSection.ID.allCases)
        )
    }
}

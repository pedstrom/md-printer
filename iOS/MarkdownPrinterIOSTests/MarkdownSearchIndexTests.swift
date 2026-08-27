import XCTest
@testable import MarkdownPrinterMobileSupport

final class MarkdownSearchIndexTests: XCTestCase {
    private let index = MarkdownSearchIndex(
        entries: [
            MarkdownSearchEntry(blockID: "one", text: "Cat catalog CAT. Exact phrase here."),
            MarkdownSearchEntry(blockID: "two", text: "Unicode café CAT\nExact phrase here too."),
            MarkdownSearchEntry(blockID: "three", text: String(repeating: "padding ", count: 12) + "needle" + String(repeating: " tail", count: 12))
        ]
    )

    func testEmptyQueryReturnsNoMatches() {
        XCTAssertEqual(index.matches(for: MarkdownSearchOptions()), [])
    }

    func testSearchTreatsQueryAsAnExactLiteralPhrase() {
        let matches = index.matches(for: MarkdownSearchOptions(query: "Exact phrase"))
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.blockID), ["one", "two"])
        XCTAssertTrue(matches.allSatisfy { $0.range.length == 12 })
    }

    func testMatchCaseAndWholeWordAreIndependent() {
        XCTAssertEqual(
            index.matches(for: MarkdownSearchOptions(query: "cat", matchCase: false)).count,
            4
        )
        XCTAssertEqual(
            index.matches(for: MarkdownSearchOptions(query: "cat", matchCase: true)).count,
            1
        )
        XCTAssertEqual(
            index.matches(for: MarkdownSearchOptions(query: "cat", matchCase: false, wholeWord: true)).count,
            3
        )
        XCTAssertEqual(
            index.matches(for: MarkdownSearchOptions(query: "CAT", matchCase: true, wholeWord: true)).count,
            2
        )
    }

    func testUnicodeRangesAndLongPreviewAreStable() throws {
        let unicode = try XCTUnwrap(
            index.matches(for: MarkdownSearchOptions(query: "café", matchCase: true)).first
        )
        XCTAssertEqual(unicode.range, NSRange(location: 8, length: 4))
        XCTAssertEqual(unicode.id, "two-8-4")

        let long = try XCTUnwrap(
            index.matches(for: MarkdownSearchOptions(query: "needle")).first
        )
        XCTAssertTrue(long.preview.hasPrefix("…"))
        XCTAssertTrue(long.preview.hasSuffix("…"))
        XCTAssertFalse(long.preview.contains("\n"))
    }
}

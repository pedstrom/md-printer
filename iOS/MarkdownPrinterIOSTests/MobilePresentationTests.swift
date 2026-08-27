import XCTest
import MarkdownPrinterCore
@testable import MarkdownPrinterMobileSupport

final class MobilePresentationTests: XCTestCase {
    func testPresentationMapsBlocksAndOrdersFootnotesByFirstReference() {
        let document = MarkdownDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/guide.md"),
            title: "guide",
            markdown: """
            # Mobile Guide

            First[^b], then *styled* text[^a].

            [^a]: Alpha note
            [^b]: Beta note
            [^unused]: Unreferenced note
            """
        )

        let presentation = MobileMarkdownPresenter().prepare(document: document)

        XCTAssertEqual(presentation.title, "Mobile Guide")
        XCTAssertEqual(presentation.sourceURL, document.sourceURL)
        XCTAssertEqual(presentation.blocks.map(\.id), ["block-0", "block-1"])
        XCTAssertEqual(presentation.footnotes.map(\.label), ["b", "a", "unused"])
        XCTAssertEqual(presentation.footnotes.map(\.number), [1, 2, 3])
        XCTAssertEqual(presentation.footnoteNumbers, ["b": 1, "a": 2, "unused": 3])
        XCTAssertEqual(presentation.blocks[1].plainText, "First[1], then styled text[2].")
        XCTAssertEqual(presentation.footnotes[0].plainText, "1. Beta note")
    }

    func testPlainTextCoversListsQuotesCodeHTMLTablesAndImages() {
        let presenter = MobileMarkdownPresenter()
        let document = MarkdownDocument(
            title: "Features",
            markdown: """
            > Quoted **text**

            3. [x] Complete
            4. [ ] Pending

            ```swift
            let value = 42
            ```

            <aside>literal</aside>

            | Name | Value |
            | --- | ---: |
            | Icon | ![diagram](diagram.png) |

            First line
            second line\("  ")
            third line

            ---
            """
        )
        let presentation = presenter.prepare(document: document)
        let text = presentation.blocks.map(\.plainText).joined(separator: "\n")

        XCTAssertTrue(text.contains("Quoted text"))
        XCTAssertTrue(text.contains("3. ☑ Complete"))
        XCTAssertTrue(text.contains("4. ☐ Pending"))
        XCTAssertTrue(text.contains("let value = 42"))
        XCTAssertTrue(text.contains("<aside>literal</aside>"))
        XCTAssertTrue(text.contains("Name\tValue"))
        XCTAssertTrue(text.contains("Icon\tdiagram"))
        XCTAssertTrue(text.contains("First line second line\nthird line"))
        XCTAssertTrue(text.hasSuffix("\n"), "The thematic break contributes an empty searchable block.")
    }

    func testSearchIndexIncludesBodyAndFootnotes() {
        let presentation = MobileMarkdownPresenter().prepare(
            document: MarkdownDocument(
                title: "Search",
                markdown: "Paragraph needle.[^note]\n\n[^note]: Another needle."
            )
        )

        let matches = presentation.searchIndex.matches(
            for: MarkdownSearchOptions(query: "needle")
        )

        XCTAssertEqual(matches.map(\.blockID), ["block-0", "footnote-note"])
    }

    func testSharedMarkdownLinkResolverNormalizesAllSupportedExtensions() throws {
        let directory = URL(fileURLWithPath: "/tmp/Markdown Links", isDirectory: true)
        for pathExtension in MarkdownLinkTarget.supportedPathExtensions {
            let resolved = try XCTUnwrap(
                MarkdownLinkTarget.resolvedURL(
                    for: "Sibling%20Note.\(pathExtension)",
                    relativeTo: directory
                )
            )
            XCTAssertEqual(
                MarkdownLinkTarget.fileURL(from: resolved),
                directory.appendingPathComponent("Sibling Note.\(pathExtension)").standardizedFileURL
            )
        }
        XCTAssertNil(MarkdownLinkTarget.fileURL(from: URL(fileURLWithPath: "/tmp/file.txt")))
        XCTAssertNil(MarkdownLinkTarget.fileURL(from: URL(string: "https://example.com/readme.md")!))
        XCTAssertEqual(
            MarkdownLinkTarget.resolvedURL(for: "https://example.com/a%20b", relativeTo: directory)?.absoluteString,
            "https://example.com/a%20b"
        )
    }

    func testFootnoteLinksRoundTripDefinitionReferenceStringsAndRejectOtherValues() {
        let definition = MobileFootnoteLink.url(for: .definition("detail note"))
        let reference = MobileFootnoteLink.url(for: .reference("detail note"))
        XCTAssertEqual(MobileFootnoteLink.target(from: definition), .definition("detail note"))
        XCTAssertEqual(MobileFootnoteLink.target(from: reference.absoluteString), .reference("detail note"))
        XCTAssertNil(MobileFootnoteLink.target(from: URL(string: "https://example.com")!))
        XCTAssertNil(MobileFootnoteLink.target(from: 42))
        XCTAssertNil(
            MobileFootnoteLink.target(
                from: URL(string: "markdown-printer-footnote://unknown?label=detail")!
            )
        )
    }
}

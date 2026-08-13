import XCTest
@testable import MarkdownPrinterCore

final class MarkdownParserTests: XCTestCase {
    private let parser = MarkdownParser()

    func testHeadingsParagraphAndRules() {
        let blocks = parser.parse("# One\n###### Six\n####### Not heading\n\n---\n\nParagraph\ncontinues")
        XCTAssertEqual(blocks, [
            .heading(level: 1, content: [.text("One")]),
            .heading(level: 6, content: [.text("Six")]),
            .paragraph([.text("####### Not heading")]),
            .thematicBreak,
            .paragraph([.text("Paragraph"), .lineBreak, .text("continues")])
        ])
    }

    func testFencedCodeWithLanguageAndUnclosedFence() {
        XCTAssertEqual(
            parser.parse("```swift\nlet value = 1\n```\n~~~\nraw\n"),
            [
                .codeBlock(language: "swift", code: "let value = 1"),
                .codeBlock(language: nil, code: "raw\n")
            ]
        )
    }

    func testBlockquoteAndMixedLists() {
        let blocks = parser.parse("> first\n> second\n\n- apple\n* [x] done\n+ [ ] todo\n\n3. third\n4. fourth")
        XCTAssertEqual(blocks, [
            .blockquote([.text("first"), .lineBreak, .text("second")]),
            .list(items: [
                MarkdownListItem(content: [.text("apple")]),
                MarkdownListItem(content: [.text("done")], checked: true),
                MarkdownListItem(content: [.text("todo")], checked: false)
            ], ordered: false, start: 1),
            .list(items: [
                MarkdownListItem(content: [.text("third")]),
                MarkdownListItem(content: [.text("fourth")])
            ], ordered: true, start: 3)
        ])
    }

    func testTableAlignmentAndRows() {
        let markdown = """
        | Name | Amount | Notes |
        | :--- | ---: | :---: |
        | Tea | 2 | **hot** |
        | Pie | 1 | |
        """
        XCTAssertEqual(parser.parse(markdown), [
            .table(
                headers: [[.text("Name")], [.text("Amount")], [.text("Notes")]],
                alignments: [.leading, .trailing, .center],
                rows: [
                    [[.text("Tea")], [.text("2")], [.strong([.text("hot")])]],
                    [[.text("Pie")], [.text("1")], []]
                ]
            )
        ])
    }

    func testNonTableDelimiterAndCarriageReturns() {
        XCTAssertEqual(
            parser.parse("A|B\r\n--|---\rNext\r"),
            [.paragraph([.text("A|B"), .lineBreak, .text("--|---"), .lineBreak, .text("Next")])]
        )
    }

    func testAlternateThematicBreaksAndInvalidListMarkers() {
        XCTAssertEqual(parser.parse("* * *\n\n___\n\n1.no\n0. yes"), [
            .thematicBreak,
            .thematicBreak,
            .paragraph([.text("1.no")]),
            .list(items: [MarkdownListItem(content: [.text("yes")])], ordered: true, start: 0)
        ])
    }

    func testFootnoteDefinitionsAreBlocksWithIndentedContinuations() {
        let markdown = """
        Claim[^evidence].

        [^evidence]: First line with **emphasis**.
            Continued line.

            Final paragraph.

        Afterward.
        """
        XCTAssertEqual(parser.parse(markdown), [
            .paragraph([.text("Claim"), .footnoteReference(label: "evidence"), .text(".")]),
            .footnoteDefinition(label: "evidence", content: [
                .text("First line with "),
                .strong([.text("emphasis")]),
                .text("."),
                .lineBreak,
                .text("Continued line."),
                .lineBreak,
                .lineBreak,
                .text("Final paragraph.")
            ]),
            .paragraph([.text("Afterward.")])
        ])
    }
}

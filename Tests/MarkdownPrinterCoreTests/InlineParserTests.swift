import XCTest
@testable import MarkdownPrinterCore

final class InlineParserTests: XCTestCase {
    private let parser = InlineParser()

    func testPlainTextEscapesAndLineBreaks() {
        XCTAssertEqual(
            parser.parse("plain \\* text\nnext<br>third<br/>fourth"),
            [.text("plain * text"), .softBreak, .text("next"), .hardBreak, .text("third"), .hardBreak, .text("fourth")]
        )
    }

    func testStrongEmphasisAndNestedStyles() {
        XCTAssertEqual(parser.parse("**bold**"), [.strong([.text("bold")])])
        XCTAssertEqual(parser.parse("__bold__"), [.strong([.text("bold")])])
        XCTAssertEqual(parser.parse("*italic*"), [.emphasis([.text("italic")])])
        XCTAssertEqual(parser.parse("_italic_"), [.emphasis([.text("italic")])])
        XCTAssertEqual(parser.parse("***both***"), [.emphasis([.strong([.text("both")])])])
        XCTAssertEqual(parser.parse("___both___"), [.emphasis([.strong([.text("both")])])])
    }

    func testUnderlineStrikeAndCode() {
        XCTAssertEqual(parser.parse("<u>under **bold**</u>"), [.underline([.text("under "), .strong([.text("bold")])])])
        XCTAssertEqual(parser.parse("~~gone~~"), [.strikethrough([.text("gone")])])
        XCTAssertEqual(parser.parse("use `code` now"), [.text("use "), .code("code"), .text(" now")])
    }

    func testLinksAndImages() {
        XCTAssertEqual(
            parser.parse("[OpenAI](https://openai.com)"),
            [.link(children: [.text("OpenAI")], destination: "https://openai.com")]
        )
        XCTAssertEqual(
            parser.parse("![Photo](<images/my photo.png>)"),
            [.image(alt: "Photo", source: "images/my photo.png")]
        )
        XCTAssertEqual(
            parser.parse("![Photo](image.png \"Caption\")"),
            [.image(alt: "Photo", source: "image.png", title: "Caption")]
        )
    }

    func testFootnoteReferencesBecomeDedicatedInlineNodes() {
        XCTAssertEqual(
            parser.parse("Claim[^source] and again[^source]."),
            [
                .text("Claim"),
                .footnoteReference(label: "source"),
                .text(" and again"),
                .footnoteReference(label: "source"),
                .text(".")
            ]
        )
        XCTAssertEqual(parser.parse("escaped \\[^source]"), [.text("escaped [^source]")])
        XCTAssertEqual(parser.parse("empty [^]"), [.text("empty [^]")])
    }

    func testMalformedDelimitersRemainText() {
        let source = "**open *still _open `tick [link](missing"
        XCTAssertEqual(plainText(from: parser.parse(source)), source)
        XCTAssertEqual(parser.parse("trailing\\"), [.text("trailing\\")])
        XCTAssertEqual(parser.parse("![bad]"), [.text("![bad]")])
    }

    func testCommonMarkDelimiterWhitespaceAndCodeRunEdges() {
        XCTAssertEqual(parser.parse("*\u{00a0}a\u{00a0}*"), [.text("*\u{00a0}a\u{00a0}*")])
        XCTAssertEqual(parser.parse("*foo bar\n*"), [.text("*foo bar"), .softBreak, .text("*")])
        XCTAssertEqual(parser.parse("` `` `"), [.code("``")])
        XCTAssertEqual(parser.parse("```foo``"), [.text("```foo``")])
        XCTAssertEqual(parser.parse("`foo``bar``"), [.text("`foo"), .code("bar")])

        let blockParser = MarkdownParser()
        XCTAssertEqual(
            CommonMarkHTMLSerializer.serialize(blockParser.parse("*\u{00a0}a\u{00a0}*\n")),
            "<p>*\u{00a0}a\u{00a0}*</p>\n"
        )
        XCTAssertEqual(
            CommonMarkHTMLSerializer.serialize(blockParser.parse("*foo bar\n*\n")),
            "<p>*foo bar\n*</p>\n"
        )
    }

    private func plainText(from nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case let .text(text): return text
            case let .emphasis(children): return "*" + plainText(from: children) + "*"
            default: return ""
            }
        }.joined()
    }
}

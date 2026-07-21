import XCTest
@testable import MarkdownPrinterCore

final class InlineParserTests: XCTestCase {
    private let parser = InlineParser()

    func testPlainTextEscapesAndLineBreaks() {
        XCTAssertEqual(
            parser.parse("plain \\* text\nnext<br>third<br/>fourth"),
            [.text("plain * text"), .lineBreak, .text("next"), .lineBreak, .text("third"), .lineBreak, .text("fourth")]
        )
    }

    func testStrongEmphasisAndNestedStyles() {
        XCTAssertEqual(parser.parse("**bold**"), [.strong([.text("bold")])])
        XCTAssertEqual(parser.parse("__bold__"), [.strong([.text("bold")])])
        XCTAssertEqual(parser.parse("*italic*"), [.emphasis([.text("italic")])])
        XCTAssertEqual(parser.parse("_italic_"), [.emphasis([.text("italic")])])
        XCTAssertEqual(parser.parse("***both***"), [.strong([.emphasis([.text("both")])])])
        XCTAssertEqual(parser.parse("___both___"), [.strong([.emphasis([.text("both")])])])
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
            [.image(alt: "Photo", source: "image.png")]
        )
    }

    func testMalformedDelimitersRemainText() {
        let source = "**open *still _open `tick [link](missing"
        XCTAssertEqual(plainText(from: parser.parse(source)), source)
        XCTAssertEqual(parser.parse("trailing\\"), [.text("trailing\\")])
        XCTAssertEqual(parser.parse("![bad]"), [.text("![bad]")])
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

import XCTest
@testable import MarkdownPrinterCore

final class CommonMarkFeatureTests: XCTestCase {
    private let parser = MarkdownParser()

    func testSetextHeadingsHandleMultilineContentAndSupplyDocumentTitle() {
        let markdown = "First *line*\nsecond line\n=====\n\nNext\n---"
        XCTAssertEqual(parser.parse(markdown), [
            .heading(level: 1, content: [
                .text("First "),
                .emphasis([.text("line")]),
                .lineBreak,
                .text("second line")
            ]),
            .heading(level: 2, content: [.text("Next")])
        ])
        XCTAssertEqual(
            MarkdownDocument(title: "Fallback", markdown: markdown).title,
            "First line second line"
        )
    }

    func testIndentedCodePreservesChunksTabsAndExcessIndentation() {
        XCTAssertEqual(parser.parse("\talpha\n\n        beta\n\ntext\n    continuation"), [
            .codeBlock(language: nil, code: "alpha\n\n    beta"),
            .paragraph([.text("text"), .lineBreak, .text("continuation")])
        ])
    }

    func testReferenceLinksAndImagesResolveAfterCollectionWithFirstDefinitionWinning() {
        let markdown = """
        [Before][ Mixed   Label ] [Collapsed][] [Shortcut] ![Photo][image]

        [mixed label]: /first "First title"
        [MIXED LABEL]: /second
        [collapsed]: /collapsed
        [shortcut]: /shortcut
        [image]: local.png 'Image title'
        """
        XCTAssertEqual(parser.parse(markdown), [
            .paragraph([
                .link(children: [.text("Before")], destination: "/first", title: "First title"),
                .text(" "),
                .link(children: [.text("Collapsed")], destination: "/collapsed", title: nil),
                .text(" "),
                .link(children: [.text("Shortcut")], destination: "/shortcut", title: nil),
                .text(" "),
                .image(alt: "Photo", source: "local.png", title: "Image title")
            ])
        ])
    }

    func testReferenceLabelsUseUnicodeCaseFoldingAndUnresolvedReferencesStayLiteral() {
        XCTAssertEqual(parser.parse("[αγω] [SS] [missing]\n\n[ΑΓΩ]: /φου\n[ß]: /case-folded"), [
            .paragraph([
                .link(children: [.text("αγω")], destination: "/φου", title: nil),
                .text(" "),
                .link(children: [.text("SS")], destination: "/case-folded", title: nil),
                .text(" [missing]")
            ])
        ])
    }

    func testCoreAutolinksValidateSchemesAndEmailAddressesOnlyInsideAngles() {
        XCTAssertEqual(InlineParser().parse(
            "<https://example.com/a?b=1> <person@example.com> <m:no> https://example.com"
        ), [
            .link(
                children: [.text("https://example.com/a?b=1")],
                destination: "https://example.com/a?b=1",
                title: nil
            ),
            .text(" "),
            .link(
                children: [.text("person@example.com")],
                destination: "mailto:person@example.com",
                title: nil
            ),
            .text(" <m:no> https://example.com")
        ])
    }

    func testEntitiesDecodeAfterStructureButStayLiteralInCodeAndRawHTML() {
        XCTAssertEqual(parser.parse("&#42;literal&#42;\n\n*emphasis*\n\n`&copy;`\n\n    &copy;\n\n<span title=\"&copy;\">"), [
            .paragraph([.text("*literal*")]),
            .paragraph([.emphasis([.text("emphasis")])]),
            .paragraph([.code("&copy;")]),
            .codeBlock(language: nil, code: "&copy;"),
            .rawHTML("<span title=\"&copy;\">\n")
        ])
        XCTAssertEqual(InlineParser().parse("&ngE; &#0;"), [.text("≧̸ �")])
    }

    func testAllSevenHTMLBlockFormsBecomeInertRawSource() {
        let examples = [
            "<script>unsafe()</script>",
            "<!-- comment -->",
            "<?instruction?>",
            "<!DOCTYPE html>",
            "<![CDATA[<unsafe>]]>",
            "<div>\nbody",
            "<custom attribute=\"value\">"
        ]

        for source in examples {
            guard case let .rawHTML(raw)? = parser.parse(source).first else {
                return XCTFail("Expected raw HTML block for \(source)")
            }
            XCTAssertEqual(raw, source + "\n")
        }
    }

    func testInlineRawHTMLIsDistinctWhileUnderlineAndBreakExtensionsWin() {
        XCTAssertEqual(InlineParser().parse("<i data-x='1'>x</i>"), [
            .rawHTML("<i data-x='1'>"),
            .text("x"),
            .rawHTML("</i>")
        ])
        XCTAssertEqual(InlineParser().parse("<u>under</u><br />after"), [
            .underline([.text("under")]),
            .lineBreak,
            .text("after")
        ])
    }
}

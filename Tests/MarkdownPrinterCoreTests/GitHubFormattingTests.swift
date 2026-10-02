import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI
@testable import MarkdownPrinterQuickLookSupport

final class GitHubFormattingTests: XCTestCase {
    private func links(_ nodes: [InlineNode]) -> [String] {
        nodes.flatMap {
            switch $0 {
            case let .link(_, destination, _): return [destination]
            case let .emphasis(children), let .strong(children), let .underline(children), let .strikethrough(children): return links(children)
            default: return []
            }
        }
    }

    func testExtendedAutolinksFollowGFMExamplesAndBoundaries() {
        let examples: [(String, [String])] = [
            ("www.commonmark.org", ["http://www.commonmark.org"]),
            ("Visit www.commonmark.org/help for more information.", ["http://www.commonmark.org/help"]),
            ("www.example.com/a.b.", ["http://www.example.com/a.b"]),
            ("(https://example.com/search?q=Markup+(business)))", ["https://example.com/search?q=Markup+(business)"]),
            ("www.example.com/search?q=commonmark&hl;", ["http://www.example.com/search?q=commonmark"]),
            ("https://example.com/a?x=1&y=2!", ["https://example.com/a?x=1&y=2"]),
            ("foo@bar.baz.", ["mailto:foo@bar.baz"]),
            ("hello@mail+xyz.example hello+xyz@mail.example", ["mailto:hello+xyz@mail.example"]),
            ("a.b-c_d@a.b- a.b-c_d@a.b_", []),
            ("mailto:foo@bar.baz/ xmpp:foo@bar.baz/txt@bin.com/again", ["mailto:foo@bar.baz", "xmpp:foo@bar.baz/txt@bin.com"]),
            ("xhttps://example.com :www.example.com example.com www.!", []),
            ("www.foo_bar.example.com www.example_bad.com", ["http://www.foo_bar.example.com"]),
            ("**https://example.com** ~~www.example.com~~ <u>foo@bar.baz</u>", ["https://example.com", "http://www.example.com", "mailto:foo@bar.baz"])
        ]
        for (source, expected) in examples { XCTAssertEqual(links(InlineParser().parse(source)), expected, source) }
        XCTAssertEqual(InlineParser(extendedAutolinks: false).parse("https://example.com"), [.text("https://example.com")])
    }

    func testExplicitLinksImagesCodeAndHTMLTakePrecedence() {
        let nodes = InlineParser().parse("[https://example.com](https://target.example) ![www.example.com](image.png) `https://example.com` <b data-url=\"https://example.com\">text</b>")
        XCTAssertEqual(links(nodes), ["https://target.example"])
        XCTAssertTrue(nodes.contains(.image(alt: "www.example.com", source: "image.png")))
        XCTAssertEqual(links(InlineParser().parse("[www.example.com][ref]", references: ["ref": LinkReferenceDefinition(destination: "#heading", title: nil)])), ["#heading"])
    }

    @MainActor
    func testAutolinksAndSectionsReachTablesListsQuotesAndFootnotes() throws {
        let markdown = """
        # Anchor

        - [X] https://example.com/list
        - [ ] www.example.com

        > hello@example.com [Quote section](#anchor)

        | Link | Section |
        | --- | --- |
        | xmpp:hello@example.com/resource | [Table section](#anchor) |

        Note[^note].

        [^note]: mailto:hello@example.com [Note section](#anchor)
        """
        let text = MarkdownRenderer().render(markdown: markdown)
        var destinations: [String] = []
        var references: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { destinations.append(url.absoluteString) }
        }
        text.enumerateAttribute(.markdownSectionReference, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let anchor = value as? String { references.append(anchor) }
        }
        XCTAssertEqual(destinations, ["https://example.com/list", "http://www.example.com", "mailto:hello@example.com", "xmpp:hello@example.com/resource", "mailto:hello@example.com"])
        XCTAssertEqual(references, ["anchor", "anchor", "anchor"])
        XCTAssertTrue(text.string.contains("☑︎"))
        XCTAssertTrue(text.string.contains("☐"))
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertEqual(pdf.page(at: 0)?.annotations.filter { $0.action is PDFActionGoTo }.count, 5)
    }

    func testTaskMarkersWhitespaceNestingAndInvalidMarkers() {
        let blocks = MarkdownParser().parse("- [X]\tCompleted\n  - [\t] Nested\n- [ ]  Todo\n  continued\n- [q] ordinary\n- [x]missing space")
        guard case let .list(items, _, _, _) = blocks.first else { return XCTFail("Missing list") }
        XCTAssertEqual(items.map(\.checked), [true, false, nil, nil])
        guard case let .list(nested, _, _, _) = items[0].blocks.last else { return XCTFail("Missing nested list") }
        XCTAssertEqual(nested.first?.checked, false)
        XCTAssertEqual(items[1].content, [.text("Todo"), .softBreak, .text("continued")])
    }

    func testSectionCatalogFormattingUnicodeCollisionsAndNestedPaths() {
        let blocks = MarkdownParser().parse("# **Packing** _List_!\n## Packing List\n### Packing List-1\n#### Packing List\n> ##### Café Θ 你好_under\n\n- ###### Nested `code` ![Photo](image.png)\n\n## !!!\n## !!!")
        let sections = MarkdownSectionCatalog(blocks: blocks).sections
        XCTAssertEqual(sections.map(\.anchor), ["packing-list", "packing-list-1", "packing-list-1-1", "packing-list-2", "café-θ-你好_under", "nested-code-photo", "", "-1"])
        XCTAssertEqual(sections[4].blockID, "block-4-quote-0")
        XCTAssertEqual(sections[5].blockID, "block-5-item-0-0")
        XCTAssertEqual(MarkdownSectionCatalog.slug([.text("  Trimmed  ")]), "trimmed")
        XCTAssertEqual(MarkdownSectionCatalog.slug([.rawHTML("<b>"), .text("Title"), .rawHTML("</b>")]), "title")
    }

    func testLocalLinkComponentsAndHostHandoffRoundTrip() throws {
        let folder = URL(fileURLWithPath: "/tmp/documents", isDirectory: true)
        let url = try XCTUnwrap(MarkdownLinkTarget.resolvedURL(for: "a%23b%20c.md?query=value#caf%C3%A9", relativeTo: folder))
        let target = try XCTUnwrap(MarkdownLinkTarget.localTarget(from: url))
        XCTAssertEqual(target.fileURL.path, "/tmp/documents/a#b c.md")
        XCTAssertEqual(target.fragment, "café")
        let decoded = try XCTUnwrap(MarkdownLinkTarget.hostAppTarget(from: MarkdownLinkTarget.hostAppURL(for: target)))
        XCTAssertEqual(decoded.fileURL, target.fileURL)
        XCTAssertEqual(decoded.fragment, target.fragment)
        XCTAssertEqual(MarkdownLinkTarget.sectionFragment(from: URL(string: "#caf%C3%A9")!), "café")
        XCTAssertEqual(MarkdownLinkTarget.sectionFragment(from: url, sourceURL: target.fileURL), "café")
        XCTAssertNil(MarkdownLinkTarget.sectionFragment(from: URL(string: "https://example.com/#section")!))
        XCTAssertNil(MarkdownLinkTarget.hostAppTarget(from: URL(string: "markdown-printer://open?file=https://example.com/a.md")!))
        let plain = MarkdownNavigationRequest(fileURL: target.fileURL)
        XCTAssertNil(MarkdownLinkTarget.hostAppTarget(from: MarkdownLinkTarget.hostAppURL(for: plain))?.fragment)
        XCTAssertNil(MarkdownLinkTarget.localTarget(from: URL(string: "https://example.com/a.md")!))
        XCTAssertNotEqual(plain.id, target.id)
        XCTAssertTrue(MarkdownNavigationError.sectionNotFound("missing").localizedDescription.contains("missing"))
    }

    @MainActor
    func testRenderedSectionsPDFDestinationsAndQuickLookNavigation() throws {
        let markdown = "[Forward](#later) [Missing](#absent) https://example.com\n\n# First\n\n" + String(repeating: "Paragraph of content that occupies printable space.\n\n", count: 100) + "## Later\n\n[Back](#first)\n\n> ### Nested\n"
        let document = MarkdownDocument(sourceURL: URL(fileURLWithPath: "/tmp/example.md"), title: "T", markdown: markdown)
        let text = MarkdownRenderer().render(document: document)
        let result = try PDFExporter().render(from: text)
        XCTAssertEqual(Set(result.sectionDestinations.keys), ["first", "later", "nested"])
        XCTAssertGreaterThan(try XCTUnwrap(result.sectionDestinations["later"]).pageIndex, 0)
        let pdf = try XCTUnwrap(PDFDocument(data: result.data))
        let actions = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }.compactMap { $0.action as? PDFActionGoTo }
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.allSatisfy { $0.destination.page != nil })
        let quickLook = ContinuousPreviewView(frame: CGRect(x: 0, y: 0, width: 680, height: 400))
        quickLook.display(ContinuousPreviewRenderer().render(PreparedQuickLookDocument(document: document, blocks: document.blocks)))
        XCTAssertTrue(quickLook.scrollToSection("nested"))
        XCTAssertFalse(quickLook.scrollToSection("absent"))
        XCTAssertTrue(quickLook.textView(quickLook.textView, clickedOnLink: URL(string: "#later")!, at: 0))
    }

    @MainActor
    func testNavigationRequestsReplaceByFileAndOldCompletionCannotConsumeNewRequest() {
        let coordinator = MarkdownNavigationCoordinator()
        let file = URL(fileURLWithPath: "/tmp/example.md")
        let first = MarkdownNavigationRequest(fileURL: file, fragment: "one")
        let second = MarkdownNavigationRequest(fileURL: file, fragment: "two")
        XCTAssertNil(coordinator.request(for: nil))
        coordinator.enqueue(first)
        coordinator.enqueue(second)
        coordinator.complete(first)
        XCTAssertEqual(coordinator.request(for: file), second)
        coordinator.complete(second)
        XCTAssertNil(coordinator.request(for: file))
    }
    func testTaskMarkersAreOnlyRemovedFromFirstParagraphAndAllowLineWhitespace() {
        let source = "- [ ]\n  continued\n\n  [X] Second paragraph\n- # [X] Heading\n- [ ] # Literal hash\n- `[X] code`\n- [ ]\n- [  ] Invalid\n- [\u{00A0}] Invalid"
        guard case let .list(items, _, _, _) = MarkdownParser().parse(source).first else { return XCTFail("Missing list") }
        XCTAssertEqual(items.map(\.checked), [false, nil, false, nil, nil, nil, nil])
        XCTAssertEqual(items[0].content, [.text("continued")])
        XCTAssertEqual(items[0].blocks.count, 2)
        XCTAssertEqual(items[2].content, [.text("# Literal hash")])
    }

    @MainActor
    func testQuickLookCrossFileHandoffKeepsSectionAndDoesNotReadSibling() throws {
        let preview = ContinuousPreviewView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        var opened: URL?
        preview.openURL = { opened = $0 }
        let file = URL(fileURLWithPath: "/tmp/other#file.md")
        var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
        components.fragment = "café"
        XCTAssertTrue(preview.textView(preview.textView, clickedOnLink: components.url!, at: 0))
        let target = try XCTUnwrap(opened.flatMap(MarkdownLinkTarget.hostAppTarget))
        XCTAssertEqual(target.fileURL, file)
        XCTAssertEqual(target.fragment, "café")
        XCTAssertFalse(preview.textView(preview.textView, clickedOnLink: 42, at: 0))
        preview.display(NSAttributedString(string: "The preview remains available."))
        preview.reportNavigationUnavailable()
        preview.layoutSubtreeIfNeeded()
        XCTAssertFalse(preview.navigationNotice.isHidden)
        XCTAssertEqual(preview.textView.string, "The preview remains available.")
        XCTAssertLessThan(preview.scrollView.frame.height, preview.bounds.height)
        preview.display(NSAttributedString(string: "Next document"))
        XCTAssertTrue(preview.navigationNotice.isHidden)
    }

    @MainActor
    func testPDFSectionsPersistAfterSavingAndWrappedLinksHaveSeparateHitAreas() async throws {
        let markdown = "[" + String(repeating: "Wrapped section link ", count: 16) + "](#later)\n\n# First\n\n" + String(repeating: "Body paragraph.\n\n", count: 90) + "## Later\n\n[Back](#first) [Other](other.md#later)\n\n## Café\n\n[Unicode](#caf%C3%A9)"
        let text = MarkdownRenderer().render(markdown: markdown, baseURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
        let result = try await PDFExporter().renderAsync(from: text)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sections-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try result.data.write(to: url)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let annotations = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }
        let sectionLinks = annotations.filter { $0.action is PDFActionGoTo }
        XCTAssertGreaterThan(sectionLinks.count, 2)
        XCTAssertTrue(sectionLinks.allSatisfy { ($0.action as? PDFActionGoTo)?.destination.page != nil })
        let firstPageLinks = pdf.page(at: 0)!.annotations.filter { $0.action is PDFActionGoTo }
        XCTAssertGreaterThan(Set(firstPageLinks.map { $0.bounds.minY }).count, 1)
        XCTAssertTrue(annotations.contains { ($0.action as? PDFActionURL)?.url?.absoluteString == "file:///tmp/other.md#later" })
        XCTAssertEqual(Set(result.sectionDestinations.keys), ["first", "later", "café"])
        XCTAssertTrue(((sectionLinks.last?.action as? PDFActionGoTo)?.destination.page?.string ?? "").contains("Café"))
    }

}

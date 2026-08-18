import AppKit
import MarkdownPrinterCore
import MarkdownPrinterQuickLookSupport
import XCTest

final class ContinuousPreviewLoaderTests: XCTestCase {
    func testLoaderDecodesAndParsesMarkdownDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Notes.md")
        try Data("# Loaded title\n\n| A | B |\n| --- | --- |\n| 1 | 2 |".utf8)
            .write(to: url)

        let prepared = try await ContinuousPreviewLoader().load(at: url)

        XCTAssertEqual(prepared.document.title, "Loaded title")
        XCTAssertEqual(prepared.document.sourceURL, url)
        XCTAssertTrue(prepared.blocks.contains { block in
            if case .table = block { return true }
            return false
        })
    }

    func testLoaderReportsEncodingErrorWithoutPrivatePath() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-\(UUID().uuidString).md")
        try Data([0xFF, 0xFF, 0xFF]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await ContinuousPreviewLoader().load(at: url)
            XCTFail("Expected unsupported encoding")
        } catch let error as ContinuousPreviewError {
            XCTAssertEqual(error, .unsupportedTextEncoding)
            XCTAssertFalse(error.localizedDescription.contains(url.path))
        }
    }

    func testLoaderReportsUnreadableDocumentWithoutPrivatePath() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).md")

        do {
            _ = try await ContinuousPreviewLoader().load(at: url)
            XCTFail("Expected unreadable document")
        } catch let error as ContinuousPreviewError {
            XCTAssertEqual(error, .unreadableDocument)
            XCTAssertFalse(error.localizedDescription.contains(url.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

@MainActor
final class ContinuousPreviewRenderingTests: XCTestCase {
    func testScreenConfigurationUsesAvenirResponsiveSizingAndAdaptiveColors() {
        let configuration = ContinuousPreviewStyle.rendererConfiguration

        XCTAssertEqual(configuration.fontFamily, "Avenir Next")
        XCTAssertEqual(configuration.bodyFontSize, 13)
        XCTAssertEqual(configuration.headingFontSizes, [31, 26, 22, 18, 16, 13])
        XCTAssertEqual(configuration.contentWidth, 680)
        XCTAssertEqual(configuration.maximumImageWidth, 680)
        XCTAssertEqual(configuration.textColor, .labelColor)
        XCTAssertEqual(configuration.secondaryTextColor, .secondaryLabelColor)
        XCTAssertEqual(configuration.accentColor, .linkColor)
        XCTAssertEqual(configuration.codeBackgroundColor, .controlBackgroundColor)
        XCTAssertEqual(configuration.tableBorderColor, .separatorColor)
    }

    func testRendererPreservesSupportedMarkdownAndAddsFootnoteNavigation() throws {
        let markdown = """
        # Heading

        Paragraph **bold** *italic* <u>under</u> ~~gone~~ `code` [link](https://example.com) with note[^n].

        > quote

        - item
        - [x] done

        3. ordered

        ```swift
        let value = 1
        ```

        ---

        | Left | Right |
        | :--- | ---: |
        | A | 2 |

        ![Remote](https://example.com/remote.png)

        [^n]: Footnote text
        """
        let document = MarkdownDocument(title: "Fixture", markdown: markdown)
        let prepared = PreparedQuickLookDocument(
            document: document,
            blocks: MarkdownParser().parse(markdown)
        )

        let output = ContinuousPreviewRenderer().render(prepared)

        for text in [
            "Heading", "bold", "italic", "under", "gone", "code", "link", "quote",
            "item", "done", "ordered", "let value = 1", "Left", "Right", "Remote",
            "Footnote text"
        ] {
            XCTAssertTrue(output.string.contains(text), "Missing \(text)")
        }
        XCTAssertTrue(output.string.contains("[Image: Remote]"))
        XCTAssertTrue(output.string.contains("────"))

        let bodyRange = (output.string as NSString).range(of: "Paragraph")
        let bodyFont = try XCTUnwrap(
            output.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(bodyFont.familyName, "Avenir Next")
        XCTAssertEqual(bodyFont.pointSize, 13)

        let headingRange = (output.string as NSString).range(of: "Heading")
        let headingFont = try XCTUnwrap(
            output.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(headingFont.pointSize, 31)

        let referenceRange = (output.string as NSString).range(of: "note1")
        let referenceIndex = referenceRange.location + referenceRange.length - 1
        let referenceLink = try XCTUnwrap(
            output.attribute(.link, at: referenceIndex, effectiveRange: nil)
        )
        XCTAssertEqual(
            QuickLookFootnoteLink.target(from: referenceLink),
            .definition("n")
        )

        let definitionRange = (output.string as NSString).range(of: "1. Footnote")
        let definitionLink = try XCTUnwrap(
            output.attribute(.link, at: definitionRange.location, effectiveRange: nil)
        )
        XCTAssertEqual(
            QuickLookFootnoteLink.target(from: definitionLink),
            .reference("n")
        )
    }

    func testFootnoteLinksRoundTripUnicodeAndRejectOtherLinks() {
        let label = "résumé / note"
        let definitionURL = QuickLookFootnoteLink.url(for: .definition(label))
        let referenceURL = QuickLookFootnoteLink.url(for: .reference(label))

        XCTAssertEqual(
            QuickLookFootnoteLink.target(from: definitionURL),
            .definition(label)
        )
        XCTAssertEqual(
            QuickLookFootnoteLink.target(from: referenceURL.absoluteString),
            .reference(label)
        )
        XCTAssertNil(QuickLookFootnoteLink.target(from: URL(string: "https://example.com")!))
        XCTAssertNil(QuickLookFootnoteLink.target(from: 42))
    }

    func testNativePreviewIsContinuousSelectableResizableAndNavigatesFootnotes() throws {
        let view = ContinuousPreviewView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 500)
        )
        let markdown = "Reference[^a].\n\n[^a]: Definition"
        let prepared = PreparedQuickLookDocument(
            document: MarkdownDocument(title: "T", markdown: markdown),
            blocks: MarkdownParser().parse(markdown)
        )
        let attributed = ContinuousPreviewRenderer().render(prepared)

        view.display(attributed)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.scrollView.hasVerticalScroller)
        XCTAssertFalse(view.scrollView.hasHorizontalScroller)
        XCTAssertTrue(view.textView.isSelectable)
        XCTAssertFalse(view.textView.isEditable)
        XCTAssertGreaterThan(view.textView.frame.height, 0)
        let readingWidth = view.textView.frame.width - view.textView.textContainerInset.width * 2
        XCTAssertLessThanOrEqual(readingWidth, 680.5)

        let referenceRange = try XCTUnwrap(
            view.destinationRange(for: .reference("a"))
        )
        let definitionRange = try XCTUnwrap(
            view.destinationRange(for: .definition("a"))
        )
        XCTAssertLessThan(referenceRange.location, definitionRange.location)
        XCTAssertTrue(view.textView(
            view.textView,
            clickedOnLink: QuickLookFootnoteLink.url(for: .definition("a")),
            at: referenceRange.location
        ))
        XCTAssertFalse(view.textView(
            view.textView,
            clickedOnLink: URL(string: "https://example.com")!,
            at: 0
        ))

        view.textView.setSelectedRange(referenceRange)
        XCTAssertEqual(
            (view.textView.string as NSString).substring(with: view.textView.selectedRange()),
            "1"
        )

        view.frame.size.width = 420
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(
            view.textView.textContainerInset.width,
            ContinuousPreviewStyle.horizontalMargin
        )
    }

    func testErrorViewIsConciseAndContainsNoPath() {
        let view = ContinuousPreviewView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        view.display(error: .unreadableDocument)

        XCTAssertTrue(view.textView.string.contains("Preview unavailable"))
        XCTAssertTrue(view.textView.string.contains("couldn’t read this file"))
        XCTAssertFalse(view.textView.string.contains("/Users/"))
    }
}

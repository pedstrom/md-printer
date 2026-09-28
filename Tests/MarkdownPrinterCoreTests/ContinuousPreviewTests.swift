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
        XCTAssertEqual(configuration.headingFontSizes, [34, 26, 21, 17, 14, 13])
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
            "item", "done", "ordered", "let value = 1", "Left", "Right",
            "Footnote text"
        ] {
            XCTAssertTrue(output.string.contains(text), "Missing \(text)")
        }
        XCTAssertTrue(placeholders(in: output).contains { $0.filename == "remote.png" })
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
        XCTAssertEqual(headingFont.pointSize, 34)

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

    func testRendererSharesReferenceAutolinkEntityAndSafeHTMLImageBehavior() throws {
        let markdown = """
        Quick Look title
        ================

        [Guide][guide] <reader@example.com> &copy; Raw <span>source</span>.

        <img src="https://example.com/never-fetch.png">

        [guide]: https://example.com/guide
        """
        let document = MarkdownDocument(title: "Fallback", markdown: markdown)
        let blocks = MarkdownParser().parse(markdown)
        let output = ContinuousPreviewRenderer().render(PreparedQuickLookDocument(
            document: document,
            blocks: blocks
        ))

        XCTAssertEqual(document.title, "Quick Look title")
        XCTAssertTrue(output.string.contains("Guide reader@example.com © Raw <span>source</span>."))
        XCTAssertFalse(output.string.contains("<img"))
        XCTAssertEqual(placeholders(in: output).map(\.filename), ["never-fetch.png"])
        let guide = (output.string as NSString).range(of: "Guide")
        let email = (output.string as NSString).range(of: "reader@example.com")
        let raw = (output.string as NSString).range(of: "<span>")
        XCTAssertNotNil(output.attribute(.link, at: guide.location, effectiveRange: nil))
        XCTAssertNotNil(output.attribute(.link, at: email.location, effectiveRange: nil))
        XCTAssertNil(output.attribute(.link, at: raw.location, effectiveRange: nil))
        XCTAssertNil(output.attribute(.attachment, at: raw.location, effectiveRange: nil))
        let rawFont = try XCTUnwrap(output.attribute(.font, at: raw.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(rawFont.isFixedPitch)
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

    func testUnavailableImagesUseFilenameOnlyAndKeepFullAppFallback() throws {
        let markdown = """
        ![Different alt text](private/photos/mountain%20lake.png)

        ![Absolute](/private/not-present/photo.jpg)

        ![Remote](https://example.com/private/sunset%20view.jpg?secret=value#fragment)

        <img src="file:///private/not-present/r%C3%A9sum%C3%A9.png" width="120">
        """
        let document = MarkdownDocument(title: "Images", markdown: markdown)
        let output = ContinuousPreviewRenderer().render(PreparedQuickLookDocument(
            document: document, blocks: document.blocks
        ))
        let boxes = placeholders(in: output)

        XCTAssertEqual(boxes.map(\.filename), ["mountain lake.png", "photo.jpg", "sunset view.jpg", "résumé.png"])
        XCTAssertEqual(boxes.last?.bounds.width, 120)
        XCTAssertFalse(output.string.contains("private"))
        XCTAssertFalse(output.string.contains("Different alt text"))
        XCTAssertTrue(MarkdownRenderer().render(document: document).string.contains("[Image: Different alt text]"))
        XCTAssertEqual(QuickLookImagePlaceholder(source: "https://example.com/", maximumWidth: 100).filename, "Image")
    }

    func testAccessibleImagesStillRenderAndTablePlaceholdersFit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("available.png"))
        try Data("invalid image".utf8).write(to: directory.appendingPathComponent("broken.png"))
        let document = MarkdownDocument(
            sourceURL: directory.appendingPathComponent("fixture.md"),
            title: "Images",
            markdown: """
            ![Available](available.png)

            | Photo | Notes |
            | --- | --- |
            | ![Missing](not-present.png) | Description |
            | ![Corrupt](broken.png) | Description |
            """
        )
        let output = ContinuousPreviewRenderer().render(PreparedQuickLookDocument(
            document: document, blocks: document.blocks
        ))
        let image = try XCTUnwrap(output.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertFalse(image is QuickLookImagePlaceholder)
        XCTAssertEqual(image.image?.size, NSSize(width: 100, height: 50))
        XCTAssertEqual(placeholders(in: output).map(\.filename), ["not-present.png", "broken.png"])
        for placeholder in placeholders(in: output) {
            XCTAssertLessThan(placeholder.bounds.width, 340)
        }
    }

    func testPlaceholderLayoutFitsNarrowPreviewsAndDrawsInBothAppearances() throws {
        let placeholder = QuickLookImagePlaceholder(source: "private/mountain-lake.png", maximumWidth: 680)
        let container = NSTextContainer(size: NSSize(width: 220, height: 500))
        let frame = placeholder.attachmentBounds(
            for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: 220, height: 500),
            glyphPosition: .zero, characterIndex: 0
        )
        XCTAssertEqual(frame.width, 210)
        XCTAssertGreaterThan(frame.height, 60)
        for appearanceName: NSAppearance.Name in [.aqua, .darkAqua] {
            try XCTUnwrap(NSAppearance(named: appearanceName)).performAsCurrentDrawingAppearance {
                let image = placeholder.image(forBounds: frame, textContainer: container, characterIndex: 0)
                XCTAssertEqual(image?.accessibilityDescription, "Unavailable image: mountain-lake.png")
                XCTAssertEqual(image?.size, frame.size)
                XCTAssertNotNil(image?.tiffRepresentation)
            }
        }

        let document = MarkdownDocument(title: "Fixture", markdown: "![Photo](missing.png)\n\nAfter image")
        let view = ContinuousPreviewView(frame: NSRect(x: 0, y: 0, width: 780, height: 500))
        view.display(ContinuousPreviewRenderer().render(PreparedQuickLookDocument(
            document: document, blocks: document.blocks
        )))
        for width: CGFloat in [780, 280, 500] {
            view.frame.size.width = width
            view.layoutSubtreeIfNeeded()
            let layout = try XCTUnwrap(view.textView.layoutManager)
            let textContainer = try XCTUnwrap(view.textView.textContainer)
            layout.ensureLayout(for: textContainer)
            let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: textContainer)
            XCTAssertGreaterThan(glyph.width, 100)
            XCTAssertLessThanOrEqual(glyph.maxX, textContainer.size.width + 1)
        }
    }

    func testPlaceholderCellDrawsCenteredFilenameInLightAndDarkMode() throws {
        let placeholder = QuickLookImagePlaceholder(source: "photos/mountain.png", maximumWidth: 320)
        let cell = try XCTUnwrap(placeholder.attachmentCell)
        XCTAssertEqual(cell.cellSize(), placeholder.bounds.size)
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            var rendered: Data?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                let image = NSImage(size: placeholder.bounds.size, flipped: false) { rect in
                    NSColor.textBackgroundColor.setFill()
                    rect.fill()
                    cell.draw(withFrame: rect, in: nil)
                    return true
                }
                rendered = image.tiffRepresentation
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered)))
            let background = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
            var labelPixels: [NSPoint] = []
            for y in 16..<(bitmap.pixelsHigh - 16) {
                for x in 16..<(bitmap.pixelsWide - 16) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if abs(color.redComponent - background.redComponent) > 0.2 {
                        labelPixels.append(NSPoint(x: x, y: y))
                    }
                }
            }
            XCTAssertGreaterThan(labelPixels.count, 50, "Filename must be visibly drawn")
            let minX = try XCTUnwrap(labelPixels.map(\.x).min())
            let maxX = try XCTUnwrap(labelPixels.map(\.x).max())
            let minY = try XCTUnwrap(labelPixels.map(\.y).min())
            let maxY = try XCTUnwrap(labelPixels.map(\.y).max())
            XCTAssertEqual((minX + maxX) / 2, CGFloat(bitmap.pixelsWide) / 2, accuracy: 3)
            XCTAssertEqual((minY + maxY) / 2, CGFloat(bitmap.pixelsHigh) / 2, accuracy: 4)
        }
    }

    private func placeholders(in output: NSAttributedString) -> [QuickLookImagePlaceholder] {
        var attachments: [QuickLookImagePlaceholder] = []
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, _ in
            if let placeholder = value as? QuickLookImagePlaceholder { attachments.append(placeholder) }
        }
        return attachments
    }
}

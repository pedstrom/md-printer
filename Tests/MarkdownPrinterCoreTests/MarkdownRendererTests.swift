import AppKit
import XCTest
@testable import MarkdownPrinterCore

final class MarkdownRendererTests: XCTestCase {
    private let renderer = MarkdownRenderer()

    func testEmptyAndConvenienceRendering() {
        XCTAssertEqual(renderer.render(markdown: "").string, "")
        XCTAssertEqual(
            renderer.render(document: MarkdownDocument(title: "T", markdown: "Hello")).string,
            "Hello\n"
        )
    }

    func testHeadingsBodyAndInlineAttributes() throws {
        let output = renderer.render(markdown: "# Heading\n\nText **bold** *italic* <u>under</u> ~~gone~~ `code` [link](https://example.com)")
        XCTAssertTrue(output.string.contains("Heading"))
        XCTAssertTrue(output.string.contains("Text bold italic under gone code link"))

        let headingRange = (output.string as NSString).range(of: "Heading")
        let headingFont = output.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(headingFont?.familyName, "Avenir Next")
        XCTAssertEqual(headingFont?.pointSize, 24)

        let bodyRange = (output.string as NSString).range(of: "Text")
        let bodyFont = output.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bodyFont?.pointSize, 10)

        assertAttribute(.underlineStyle, text: "under", in: output)
        assertAttribute(.strikethroughStyle, text: "gone", in: output)
        assertAttribute(.backgroundColor, text: "code", in: output)
        assertAttribute(.link, text: "link", in: output)
        let codeRange = (output.string as NSString).range(of: "code")
        let codeFont = output.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(try XCTUnwrap(codeFont).isFixedPitch)
        XCTAssertEqual(codeFont?.pointSize, 9.5)
    }

    func testAllHeadingLevelsCarryNativeHeaderMetadata() throws {
        let markdown = (1...6)
            .map { "\(String(repeating: "#", count: $0)) Heading \($0)" }
            .joined(separator: "\n")
        let output = renderer.render(markdown: markdown)

        for level in 1...6 {
            let range = (output.string as NSString).range(of: "Heading \(level)")
            let paragraph = try XCTUnwrap(
                output.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
            )
            XCTAssertEqual(paragraph.headerLevel, level)
        }
    }

    func testSecondaryHeadingsAndIntroductoryParagraphsUseCompactBlockTransitions() {
        let output = renderer.render(markdown: """
        ## Second

        Second body.

        Introductory paragraph.

        - first item

        ### Third

        Third body.

        #### Fourth

        Fourth body.
        """)

        XCTAssertTrue(output.string.contains("Second\nSecond body."))
        XCTAssertFalse(output.string.contains("Second\n\nSecond body."))
        XCTAssertTrue(output.string.contains("Introductory paragraph.\n•  first item"))
        XCTAssertFalse(output.string.contains("Introductory paragraph.\n\n•  first item"))
        XCTAssertTrue(output.string.contains("Third\nThird body."))
        XCTAssertTrue(output.string.contains("Fourth\nFourth body."))
    }

    func testRelativeLinksResolveAgainstTheMarkdownFileFolder() throws {
        let baseURL = URL(fileURLWithPath: "/tmp/reports/deeper-research", isDirectory: true)
        let output = renderer.render(
            markdown: "[Overview](../overview.md#details) and [Section](#local)",
            baseURL: baseURL
        )
        let overviewRange = (output.string as NSString).range(of: "Overview")
        let sectionRange = (output.string as NSString).range(of: "Section")

        XCTAssertEqual(
            output.attribute(.link, at: overviewRange.location, effectiveRange: nil) as? URL,
            URL(string: "../overview.md#details", relativeTo: baseURL)?.absoluteURL
        )
        XCTAssertEqual(
            output.attribute(.link, at: sectionRange.location, effectiveRange: nil) as? URL,
            URL(string: "#local")
        )
    }

    func testFootnotesRenderAsNumberedSuperscriptLinksAndCompactNotes() throws {
        let output = renderer.render(markdown: """
        First claim[^A], another[^B], and repeated[^A].

        [^B]: Beta note with **bold** detail.
        [^A]: Alpha note.
        """)

        XCTAssertEqual(
            output.string,
            "First claim1, another2, and repeated1.\n\n────────────\n1. Alpha note.\n2. Beta note with bold detail.\n"
        )
        XCTAssertFalse(output.string.contains("[^"))

        let firstReferenceRange = (output.string as NSString).range(of: "1,")
        let referenceFont = try XCTUnwrap(
            output.attribute(.font, at: firstReferenceRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(referenceFont.pointSize, 7.2, accuracy: 0.01)
        let baselineOffset = try XCTUnwrap(
            output.attribute(.baselineOffset, at: firstReferenceRange.location, effectiveRange: nil)
                as? CGFloat
        )
        XCTAssertEqual(baselineOffset, 3.2, accuracy: 0.01)
        XCTAssertEqual(
            output.attribute(.markdownFootnoteReference, at: firstReferenceRange.location, effectiveRange: nil) as? String,
            "A"
        )
        XCTAssertNotNil(output.attribute(.underlineStyle, at: firstReferenceRange.location, effectiveRange: nil))

        let alphaRange = (output.string as NSString).range(of: "Alpha note.")
        let footnoteFont = try XCTUnwrap(
            output.attribute(.font, at: alphaRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(footnoteFont.pointSize, 8, accuracy: 0.01)
        let footnoteParagraph = try XCTUnwrap(
            output.attribute(.paragraphStyle, at: alphaRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(footnoteParagraph.lineSpacing, 1.5, accuracy: 0.01)
        XCTAssertEqual(footnoteParagraph.headIndent, 18, accuracy: 0.01)

        let alphaDefinition = (output.string as NSString).range(of: "1. Alpha")
        XCTAssertEqual(
            output.attribute(.markdownFootnoteDefinition, at: alphaDefinition.location, effectiveRange: nil) as? String,
            "A"
        )
        assertAttribute(.font, text: "bold", in: output)
    }

    func testUndefinedFootnoteReferenceRemainsReadableLiteralText() {
        XCTAssertEqual(
            renderer.render(markdown: "Unresolved[^missing].").string,
            "Unresolved[^missing].\n"
        )
    }

    func testAllBlockTypesRenderReadableText() throws {
        let markdown = """
        > quoted

        - one
        - [x] done
        - [ ] todo

        4. four

        ```swift
        let x = 1
        ```

        ---
        """
        let output = renderer.render(markdown: markdown)
        XCTAssertTrue(output.string.contains("quoted"))
        XCTAssertFalse(output.string.contains("│"))
        XCTAssertTrue(output.string.contains("•  one"))
        XCTAssertTrue(output.string.contains("☑︎  done"))
        XCTAssertTrue(output.string.contains("☐  todo"))
        XCTAssertTrue(output.string.contains("4.  four"))
        XCTAssertTrue(output.string.contains("let x = 1"))
        XCTAssertTrue(output.string.contains("────"))

        let codeRange = (output.string as NSString).range(of: "let x = 1")
        let codeFont = output.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(try XCTUnwrap(codeFont).isFixedPitch)
        XCTAssertEqual(codeFont?.pointSize, 9)
        let codeParagraph = output.attribute(.paragraphStyle, at: codeRange.location, effectiveRange: nil) as? NSParagraphStyle
        let codeBlock = try XCTUnwrap(codeParagraph?.textBlocks.first)
        XCTAssertEqual(codeBlock.contentWidth, 100)
        XCTAssertEqual(codeBlock.width(for: .padding, edge: .minX), 8)
        XCTAssertEqual(codeBlock.width(for: .padding, edge: .maxX), 8)
        XCTAssertEqual(codeBlock.backgroundColor, renderer.configuration.codeBackgroundColor)

        let quoteRange = (output.string as NSString).range(of: "quoted")
        let quoteParagraph = output.attribute(.paragraphStyle, at: quoteRange.location, effectiveRange: nil) as? NSParagraphStyle
        let quoteBlock = try XCTUnwrap(quoteParagraph?.textBlocks.first)
        XCTAssertEqual(quoteBlock.width(for: .border, edge: .minX), 1.5)
        XCTAssertEqual(quoteBlock.width(for: .border, edge: .maxX), 0)
        XCTAssertEqual(quoteBlock.width(for: .padding, edge: .minX), 12)
        XCTAssertEqual(quoteBlock.borderColor(for: .minX), renderer.configuration.secondaryTextColor)
    }

    func testLooseListsUseMoreParagraphSpacingThanTightLists() throws {
        let tight = renderer.render(markdown: "- first\n- second")
        let loose = renderer.render(markdown: "- first\n\n- second")
        let tightRange = (tight.string as NSString).range(of: "first")
        let looseRange = (loose.string as NSString).range(of: "first")
        let tightStyle = try XCTUnwrap(
            tight.attribute(.paragraphStyle, at: tightRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        let looseStyle = try XCTUnwrap(
            loose.attribute(.paragraphStyle, at: looseRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )

        XCTAssertEqual(tightStyle.paragraphSpacing, 4)
        XCTAssertEqual(looseStyle.paragraphSpacing, 10)
    }

    func testNestedListsIndentBeyondTheirParent() throws {
        let output = renderer.render(markdown: "- parent\n  - nested")
        let parentRange = (output.string as NSString).range(of: "parent")
        let nestedRange = (output.string as NSString).range(of: "nested")
        let parentStyle = try XCTUnwrap(
            output.attribute(.paragraphStyle, at: parentRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        let nestedStyle = try XCTUnwrap(
            output.attribute(.paragraphStyle, at: nestedRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )

        XCTAssertGreaterThan(nestedStyle.firstLineHeadIndent, parentStyle.firstLineHeadIndent)
        XCTAssertGreaterThan(nestedStyle.headIndent, parentStyle.headIndent)
    }

    func testLooseListContinuationAlignsWithItemText() throws {
        let output = renderer.render(markdown: "- first paragraph\n\n  continuation paragraph")
        let continuationRange = (output.string as NSString).range(of: "continuation")
        let continuationStyle = try XCTUnwrap(
            output.attribute(.paragraphStyle, at: continuationRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )

        XCTAssertEqual(continuationStyle.firstLineHeadIndent, continuationStyle.headIndent)
    }

    func testTableUsesNativeTextBlocksAndAlignment() throws {
        let output = renderer.render(markdown: "| Left | Right |\n| :--- | ---: |\n| A | 2 |")
        XCTAssertEqual(output.string, "Left\nRight\nA\n2\n")
        let left = (output.string as NSString).range(of: "Left")
        let right = (output.string as NSString).range(of: "Right")
        let leftStyle = output.attribute(.paragraphStyle, at: left.location, effectiveRange: nil) as? NSParagraphStyle
        let rightStyle = output.attribute(.paragraphStyle, at: right.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(leftStyle?.alignment, .left)
        XCTAssertEqual(rightStyle?.alignment, .right)
        XCTAssertEqual(leftStyle?.textBlocks.count, 1)
        let leftBlock = try XCTUnwrap(leftStyle?.textBlocks.first as? NSTextTableBlock)
        let rightBlock = try XCTUnwrap(rightStyle?.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(leftBlock.table.layoutAlgorithm, .fixedLayoutAlgorithm)
        XCTAssertEqual(leftBlock.contentWidthValueType, .percentageValueType)
        XCTAssertEqual(leftBlock.contentWidth, 50, accuracy: 5)
        XCTAssertEqual(rightBlock.contentWidth, 50, accuracy: 5)
        XCTAssertEqual(leftBlock.contentWidth + rightBlock.contentWidth, 100, accuracy: 0.01)
    }

    func testTableGivesContentHeavyColumnsMoreWidth() throws {
        let output = renderer.render(markdown: """
        | Case | Required total | Current status |
        | --- | --- | --- |
        | Base | Cancellable furnished unit plus flights, local transport, primary and backup internet, power contingency, insurance, food, professional costs, and continued fixed costs. | source_pending |
        | Exit | Return costs and cancellation penalty. | source_pending |
        """)

        let caseRange = (output.string as NSString).range(of: "Case")
        let totalRange = (output.string as NSString).range(of: "Required total")
        let statusRange = (output.string as NSString).range(of: "Current status")
        let caseStyle = output.attribute(.paragraphStyle, at: caseRange.location, effectiveRange: nil) as? NSParagraphStyle
        let totalStyle = output.attribute(.paragraphStyle, at: totalRange.location, effectiveRange: nil) as? NSParagraphStyle
        let statusStyle = output.attribute(.paragraphStyle, at: statusRange.location, effectiveRange: nil) as? NSParagraphStyle
        let caseBlock = try XCTUnwrap(caseStyle?.textBlocks.first as? NSTextTableBlock)
        let totalBlock = try XCTUnwrap(totalStyle?.textBlocks.first as? NSTextTableBlock)
        let statusBlock = try XCTUnwrap(statusStyle?.textBlocks.first as? NSTextTableBlock)

        XCTAssertLessThan(caseBlock.contentWidth, 25)
        XCTAssertGreaterThan(totalBlock.contentWidth, 55)
        XCTAssertLessThan(statusBlock.contentWidth, 25)
        XCTAssertEqual(
            caseBlock.contentWidth + totalBlock.contentWidth + statusBlock.contentWidth,
            100,
            accuracy: 0.01
        )
    }

    func testExistingImageBecomesScaledAttachment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("wide image.png")
        try makePNG(size: NSSize(width: 1000, height: 500)).write(to: imageURL)

        let output = renderer.render(markdown: "![Wide](wide%20image.png)", baseURL: directory)
        XCTAssertEqual(output.string, "\u{fffc}\n")
        let attachment = output.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertEqual(attachment?.bounds.width, 504)
        XCTAssertEqual(attachment?.bounds.height, 252)
    }

    func testTableImagesFitTheirColumnsIncludingNestedAndHTMLImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePNG(size: NSSize(width: 1000, height: 500))
            .write(to: directory.appendingPathComponent("wide.png"))
        let source = "https://example.com/cached.png"
        let cache = RemoteImageCache(directoryURL: directory.appendingPathComponent("cache"))
        try cache.store(makePNG(size: NSSize(width: 1000, height: 500)), for: source)

        for pageWidth: CGFloat in [612, 360] {
            let configuration = RendererConfiguration(pageSize: CGSize(width: pageWidth, height: 792))
            let output = MarkdownRenderer(configuration: configuration, remoteImageCache: cache).render(
                markdown: """
                | ![Header](wide.png) | A longer description column | Third |
                | --- | --- | --- |
                | [**![Linked](wide.png)**](https://example.com) | <u>*![Nested](wide.png)*</u> | <img src='wide.png' width='900'> |
                | ![A](wide.png)![B](wide.png) | ~~![Cached](\(source))~~ | ![Missing](missing.png) |
                """,
                baseURL: directory
            )
            var imageCount = 0
            output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                imageCount += 1
                let style = output.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                    as? NSParagraphStyle
                guard let block = style?.textBlocks.first as? NSTextTableBlock else {
                    return XCTFail("Image must remain in its table cell")
                }
                let horizontalInsets = [NSRectEdge.minX, .maxX].reduce(CGFloat.zero) { total, edge in
                    total + block.width(for: .padding, edge: edge) + block.width(for: .border, edge: edge)
                }
                let availableWidth = configuration.contentWidth * block.contentWidth / 100 - horizontalInsets
                XCTAssertLessThanOrEqual(attachment.bounds.width, availableWidth + 0.01)
                XCTAssertGreaterThan(attachment.bounds.width, 0)
                XCTAssertEqual(attachment.bounds.width / attachment.bounds.height, 2, accuracy: 0.001)
            }
            XCTAssertEqual(imageCount, 7)
            XCTAssertTrue(output.string.contains("[Image: Missing]"))
        }
    }

    func testTableImageSizingPreservesSmallImagesAndRequestedLimits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePNG(size: NSSize(width: 20, height: 10))
            .write(to: directory.appendingPathComponent("small.png"))
        try makePNG(size: NSSize(width: 1000, height: 500))
            .write(to: directory.appendingPathComponent("wide.png"))
        let output = MarkdownRenderer(configuration: RendererConfiguration(maximumImageWidth: 80)).render(
            markdown: """
            | Small | Requested | Configured |
            | --- | --- | --- |
            | ![Small](small.png) | <img src='wide.png' width='30'> | ![Wide](wide.png) |
            """,
            baseURL: directory
        )
        var sizes: [NSSize] = []
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { sizes.append(attachment.bounds.size) }
        }
        XCTAssertEqual(sizes, [NSSize(width: 20, height: 10), NSSize(width: 30, height: 15), NSSize(width: 80, height: 40)])
    }

    func testReferenceImageUsesTheSameLocalOnlyAttachmentPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("reference.png")
        try makePNG(size: NSSize(width: 160, height: 80)).write(to: imageURL)

        let output = renderer.render(
            markdown: "![Reference][asset]\n\n[asset]: reference.png \"Local title\"",
            baseURL: directory
        )

        XCTAssertEqual(output.string, "\u{fffc}\n")
        XCTAssertNotNil(output.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testReferenceAutolinkRawHTMLAndHTMLImageRenderingAreHandledSafely() throws {
        let output = renderer.render(markdown: """
        [Guide][guide] and <reader@example.com>. Raw <span data-x="1">text</span>.

        <div data-x="2">Literal block HTML</div>

        <img src="https://example.com/never-fetch.png">

        [guide]: https://example.com/guide "Guide title"
        """)

        assertAttribute(.link, text: "Guide", in: output)
        assertAttribute(.link, text: "reader@example.com", in: output)
        assertAttribute(.backgroundColor, text: "<span data-x=\"1\">", in: output)

        let rawLinkRange = (output.string as NSString).range(of: "<span data-x=\"1\">")
        let rawBlockRange = (output.string as NSString).range(of: "<div data-x=\"2\">")
        XCTAssertNil(output.attribute(.link, at: rawLinkRange.location, effectiveRange: nil))
        XCTAssertNil(output.attribute(.attachment, at: rawLinkRange.location, effectiveRange: nil))
        XCTAssertFalse((0..<output.length).contains {
            output.attribute(.attachment, at: $0, effectiveRange: nil) != nil
        })
        XCTAssertFalse(output.string.contains("<img"))
        XCTAssertTrue(output.string.contains("[Image: https://example.com/never-fetch.png]"))
        let rawFont = try XCTUnwrap(
            output.attribute(.font, at: rawLinkRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(rawFont.isFixedPitch)
        let rawBlockParagraph = try XCTUnwrap(
            output.attribute(.paragraphStyle, at: rawBlockRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(
            rawBlockParagraph.textBlocks.first?.backgroundColor,
            renderer.configuration.codeBackgroundColor
        )
    }

    func testLocalHTMLImageTagUsesRequestedWidthForBlockAndTableImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("reference.png")
        try makePNG(size: NSSize(width: 160, height: 80)).write(to: imageURL)

        let output = renderer.render(markdown: """
        <img src="reference.png" alt="Block" width="80">

        | Image |
        | --- |
        | <img alt='Table' src='reference.png' width='60px'> |
        """, baseURL: directory)
        let attachments = (0..<output.length).compactMap {
            output.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment
        }

        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments[0].bounds.size, NSSize(width: 80, height: 40))
        XCTAssertEqual(attachments[1].bounds.size, NSSize(width: 60, height: 30))
        XCTAssertFalse(output.string.contains("<img"))
    }

    func testMissingRemoteAndAbsoluteImagesBecomePlaceholders() {
        let remote = renderer.render(markdown: "![Remote](https://example.com/a.png)")
        XCTAssertEqual(remote.string, "[Image: Remote]\n")
        let missing = renderer.render(markdown: "![](missing.png)")
        XCTAssertEqual(missing.string, "[Image: missing.png]\n")
        let absolute = renderer.render(markdown: "![Nope](/does/not/exist.png)")
        XCTAssertEqual(absolute.string, "[Image: Nope]\n")
    }

    func testRemoteImagePlaceholderOffersDownloadAndUsesCachedImage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = RemoteImageCache(directoryURL: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "https://example.com/remote.png"
        let interactiveRenderer = MarkdownRenderer(remoteImageCache: cache)

        let placeholder = interactiveRenderer.render(markdown: "![Remote art](\(source))")
        XCTAssertEqual(placeholder.string, "[Remote image — click to download: Remote art]\n")
        let link = placeholder.attribute(.link, at: 0, effectiveRange: nil)
        XCTAssertEqual(RemoteImageActionURL.downloadSource(from: link as Any), source)

        try cache.store(makePNG(size: NSSize(width: 40, height: 20)), for: source)
        let cached = interactiveRenderer.render(markdown: "![Remote art](\(source))")
        XCTAssertNotNil(cached.attribute(.attachment, at: 0, effectiveRange: nil))
        XCTAssertFalse(cached.string.contains("Remote image"))
    }

    private func assertAttribute(_ key: NSAttributedString.Key, text: String, in output: NSAttributedString) {
        let range = (output.string as NSString).range(of: text)
        XCTAssertNotNil(
            output.attribute(key, at: range.location, effectiveRange: nil),
            "Missing \(key.rawValue) for \(text)"
        )
    }

    private func makePNG(size: NSSize) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return representation.representation(using: .png, properties: [:])!
    }
}

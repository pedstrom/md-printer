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

    func testTableUsesNativeTextBlocksAndAlignment() {
        let output = renderer.render(markdown: "| Left | Right |\n| :--- | ---: |\n| A | 2 |")
        XCTAssertEqual(output.string, "Left\nRight\nA\n2\n")
        let left = (output.string as NSString).range(of: "Left")
        let right = (output.string as NSString).range(of: "Right")
        let leftStyle = output.attribute(.paragraphStyle, at: left.location, effectiveRange: nil) as? NSParagraphStyle
        let rightStyle = output.attribute(.paragraphStyle, at: right.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(leftStyle?.alignment, .left)
        XCTAssertEqual(rightStyle?.alignment, .right)
        XCTAssertEqual(leftStyle?.textBlocks.count, 1)
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

    func testMissingRemoteAndAbsoluteImagesBecomePlaceholders() {
        let remote = renderer.render(markdown: "![Remote](https://example.com/a.png)")
        XCTAssertEqual(remote.string, "[Image: Remote]\n")
        let missing = renderer.render(markdown: "![](missing.png)")
        XCTAssertEqual(missing.string, "[Image: missing.png]\n")
        let absolute = renderer.render(markdown: "![Nope](/does/not/exist.png)")
        XCTAssertEqual(absolute.string, "[Image: Nope]\n")
    }

    private func assertAttribute(_ key: NSAttributedString.Key, text: String, in output: NSAttributedString) {
        let range = (output.string as NSString).range(of: text)
        XCTAssertNotNil(output.attribute(key, at: range.location, effectiveRange: nil))
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

import XCTest
import PDFKit
import UIKit
import MarkdownPrinterCore
@testable import MarkdownPrinterMobileSupport

@MainActor
final class MobilePDFExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobilePDFExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testAllHeadingLevelsUseSharedPrintHierarchyAndTotalSpacing() throws {
        let names = ["AvenirNext-Bold", "AvenirNext-Bold", "AvenirNext-DemiBold",
                     "AvenirNext-DemiBold", "AvenirNext-DemiBold", "AvenirNext-DemiBoldItalic"]
        for level in 1...6 {
            let markdown = "Before.\n\n\(String(repeating: "#", count: level)) Heading\n\nAfter."
            let output = try MobilePrintRenderer(configuration: .letter).render(
                document: MarkdownDocument(title: "Headings", markdown: markdown)
            )
            XCTAssertEqual(output.string, "Before.\nHeading\nAfter.\n")
            let index = (output.string as NSString).range(of: "Heading").location
            let font = try XCTUnwrap(output.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
            let paragraph = try XCTUnwrap(output.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(font.fontName, names[level - 1])
            XCTAssertEqual(font.pointSize, [26, 20, 16, 13, 11, 10][level - 1])
            XCTAssertEqual(paragraph.paragraphSpacingBefore + 8, [24, 18, 14, 11, 9, 8][level - 1])
            XCTAssertEqual(paragraph.paragraphSpacing, [8, 6, 5, 4, 3, 3][level - 1])
        }
    }

    func testReaderHeadingFontsRetainHierarchyAcrossDynamicTypeAndFallbacks() {
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let fonts = (1...6).map { MobileHeadingTypography.readerFont(level: $0, compatibleWith: traits) }
            for (larger, smaller) in zip(fonts, fonts.dropFirst()) {
                XCTAssertGreaterThan(larger.pointSize, smaller.pointSize)
            }
            XCTAssertEqual(fonts[0].fontName, "AvenirNext-Bold")
            XCTAssertEqual(fonts[1].fontName, "AvenirNext-Bold")
            XCTAssertEqual(fonts[2].fontName, "AvenirNext-DemiBold")
            XCTAssertEqual(fonts[5].fontName, "AvenirNext-DemiBoldItalic")
            let body = UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits)
            XCTAssertEqual(fonts[5].pointSize, body, accuracy: 0.01)
            if category == .large {
                XCTAssertEqual(fonts.map(\.pointSize), [40, 32, 26, 22, 19, 17])
            }
        }
        for level in 1...6 {
            let fallback = MobileHeadingTypography.font(level: level, size: 20, family: "Missing Font")
            XCTAssertEqual(fallback.pointSize, 20)
            XCTAssertEqual(fallback.fontDescriptor.symbolicTraits.contains(.traitItalic), level == 6)
        }
    }

    func testInlineStylesPreserveHeadingWeightAndSixthLevelItalic() throws {
        for level in [1, 2, 6] {
            let output = try MobilePrintRenderer(configuration: .letter).render(document: MarkdownDocument(
                title: "Heading", markdown: "\(String(repeating: "#", count: level)) Plain **strong** *emphasis* ***both***"
            ))
            for text in ["Plain", "strong", "emphasis", "both"] {
                let index = (output.string as NSString).range(of: text).location
                let font = try XCTUnwrap(output.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
                let italic = level == 6 || text == "emphasis" || text == "both"
                XCTAssertEqual(font.fontName, level == 6 ? "AvenirNext-DemiBoldItalic" : "AvenirNext-Bold\(italic ? "Italic" : "")")
            }
            let firstParagraph = try XCTUnwrap(output.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(firstParagraph.paragraphSpacingBefore, 0)
        }
    }

    func testReaderHeadingSpacingAccountsForEveryPrecedingBlockKind() throws {
        let examples: [(String, CGFloat)] = [
            ("## Heading", 6 * 1.7), ("Paragraph", 11), ("- Item", 11),
            ("> Quote", 13), ("```\nCode\n```", 14), ("---", 14),
            ("<div>HTML</div>", 10), ("| A |\n| --- |\n| B |", 17),
            ("[^note]: Note", 0)
        ]
        XCTAssertEqual(MobileHeadingTypography.spacingBefore(level: 1, after: nil), 0)
        for (markdown, previousSpacing) in examples {
            let block = try XCTUnwrap(MarkdownParser().parse(markdown).first)
            XCTAssertEqual(MobileHeadingTypography.spacingBefore(level: 2, after: block) + previousSpacing, 18 * 1.7, accuracy: 0.01)
        }
        XCTAssertEqual(MobileHeadingTypography.spacingBefore(level: 6, after: .thematicBreak), 0)
    }

    func testHeadingHierarchyPDFIsSearchableAndProducesVisualFixture() async throws {
        let markdown = (1...6).map {
            "\(String(repeating: "#", count: $0)) Heading level \($0)\n\nBody text follows this heading, with **strong** text for comparison."
        }.joined(separator: "\n\n") + "\n\n### A longer subsection heading that wraps naturally across multiple lines to check line spacing and following content\n\nFollowing paragraph."
        let data = try await MobilePDFExporter().pdfData(for: MarkdownDocument(title: "Headings", markdown: markdown))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        for level in 1...6 { XCTAssertTrue(pdfText(pdf).contains("Heading level \(level)")) }
        XCTAssertTrue(pdfText(pdf).contains("Following paragraph."))
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try data.write(to: documents.appendingPathComponent("mobile-headings.pdf"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "All six heading levels"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testShareablePDFVisualFixture() async throws {
        let paragraphs = (1...35).map { "Section \($0): A readable document keeps its typography, searchable text, and page layout when shared from any window." }.joined(separator: "\n\n")
        let markdown = """
        # Markdown Printer on iPad

        ## One document, ready to share

        **Avenir Next**, *emphasis*, <u>underlining</u>, and `monospaced code` remain clear in the exported PDF.

        > A quote stays together visually across wrapped lines, with a continuous rule beside the text.

        | Document | Status | Notes |
        | --- | --- | --- |
        | Field notes | Ready | Readable columns and searchable text |
        | Project outline | Reviewed | Long descriptions wrap inside their own cells without changing other columns |

        ```swift
        let actions = ["Read", "Find", "Share", "Print"]
        ```

        Unicode: café, 東京, and ✓. [Apple](https://www.apple.com/).

        \(paragraphs)
        """
        let data = try await MobilePDFExporter().pdfData(for: MarkdownDocument(title: "iPad fixture", markdown: markdown))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "iPad exported PDF fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLetterConfigurationUsesFixedMacStyleDefaults() {
        let configuration = MobilePDFConfiguration.letter
        XCTAssertEqual(configuration.pageSize, CGSize(width: 612, height: 792))
        XCTAssertEqual(configuration.margins.top, 54)
        XCTAssertEqual(configuration.margins.left, 54)
        XCTAssertEqual(configuration.margins.bottom, 54)
        XCTAssertEqual(configuration.margins.right, 54)
        XCTAssertEqual(configuration.contentWidth, 504)
        XCTAssertEqual(configuration.contentHeight, 684)
        XCTAssertEqual(configuration, MobilePDFConfiguration())
        XCTAssertNotEqual(
            configuration,
            MobilePDFConfiguration(bodyFontSize: configuration.bodyFontSize + 1)
        )
    }

    func testPDFIsLetterSizedSearchableAndContainsUnicodeLinksFootnotesAndPageNumbers() async throws {
        let sourceURL = directory.appendingPathComponent("Features.md")
        let markdown = """
        # Printable Markdown ✓

        Unicode survives: café, 東京, and 😀.

        Inline styles include *emphasis*, **strong**, **_bold italic_**, <u>underline</u>, ~~deleted~~, and `code`.
        A soft break
        continues here, while a hard break\("  ")
        starts a new line. Inline <span>HTML</span> stays literal.

        Read the [Apple documentation](https://developer.apple.com/documentation/) and note[^detail].

        - [x] Searchable text
        - [ ] Clickable links
          - Nested list content

        > Quotations remain visually distinct.

        ---

        ```swift
        let answer = 42
        ```

        <mark>Literal HTML</mark>

        [^detail]: Footnote text is searchable too.
        """
        try Data(markdown.utf8).write(to: sourceURL)
        let data = try await MobilePDFExporter().pdfData(for: try MarkdownDocument.load(from: sourceURL))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let mediaBox = page.bounds(for: .mediaBox)
        XCTAssertEqual(mediaBox.width, 612, accuracy: 0.1)
        XCTAssertEqual(mediaBox.height, 792, accuracy: 0.1)

        let text = pdfText(pdf)
        XCTAssertTrue(text.contains("Printable Markdown ✓"))
        XCTAssertTrue(text.contains("café"))
        XCTAssertTrue(text.contains("東京"))
        XCTAssertTrue(text.contains("😀"))
        XCTAssertTrue(text.contains("let answer = 42"))
        XCTAssertTrue(text.contains("Literal HTML"))
        XCTAssertTrue(text.contains("emphasis"))
        XCTAssertTrue(text.contains("bold italic"))
        XCTAssertTrue(text.contains("Nested list content"))
        XCTAssertTrue(text.contains("Footnote text is searchable too."))
        XCTAssertTrue(text.contains("1"), "The PDF should include a page number.")

        let annotations = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }
        XCTAssertTrue(
            annotations.contains { $0.url?.absoluteString == "https://developer.apple.com/documentation/" },
            "The rendered PDF should preserve web link annotations."
        )
        XCTAssertTrue(
            annotations.contains { $0.destination != nil || $0.action != nil },
            "The rendered footnote should include an internal PDF navigation action."
        )
    }

    func testLongProseAndTableFlowAcrossMultiplePages() async throws {
        let paragraphs = (1...110).map {
            "Paragraph \($0) provides enough searchable prose to validate native multi-page TextKit flow."
        }.joined(separator: "\n\n")
        let rows = (1...75).map { "| Row \($0) | Value \($0) |" }.joined(separator: "\n")
        let markdown = """
        # Long Document

        \(paragraphs)

        | Item | Value |
        | --- | ---: |
        \(rows)
        """
        let data = try await MobilePDFExporter().pdfData(
            for: MarkdownDocument(title: "Long", markdown: markdown)
        )
        let pdf = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertGreaterThan(pdf.pageCount, 3)
        XCTAssertTrue(pdfText(pdf).contains("Paragraph 110"))
        XCTAssertTrue(pdfText(pdf).contains("Row 75"))
        for index in 0..<pdf.pageCount {
            let bounds = try XCTUnwrap(pdf.page(at: index)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, 612, accuracy: 0.1)
            XCTAssertEqual(bounds.height, 792, accuracy: 0.1)
        }
    }

    func testTableHonorsLeadingCenterAndTrailingColumnAlignment() async throws {
        let markdown = """
        | Left | Center | Right |
        | :--- | :---: | ---: |
        | alpha | middle | omega |
        """
        let data = try await MobilePDFExporter().pdfData(
            for: MarkdownDocument(title: "Aligned Table", markdown: markdown)
        )
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let alpha = try XCTUnwrap(pdf.findString("alpha", withOptions: []).first).bounds(for: page)
        let middle = try XCTUnwrap(pdf.findString("middle", withOptions: []).first).bounds(for: page)
        let omega = try XCTUnwrap(pdf.findString("omega", withOptions: []).first).bounds(for: page)

        XCTAssertEqual(alpha.minX, 58, accuracy: 2)
        XCTAssertGreaterThan(middle.minX, alpha.maxX)
        XCTAssertLessThan(middle.maxX, omega.minX)
        XCTAssertEqual(omega.maxX, 554, accuracy: 2)
    }

    func testWrappedTableCellsStayTopAlignedAndAdvanceAsOneRow() async throws {
        let markdown = """
        | Time | Map | Stop | What To Do |
        | --- | ---: | --- | --- |
        | 10:52-11:05 | 1 to 2 | Lübeck Hbf to Holstentor | Walk straight toward the old town. The station-to-gate leg is about 700 m. |
        | 11:05-11:20 | 2 | Holstentor | Take the classic lawn-side Holstentor view. |

        ## Representative Images

        | Idea | Representative Image | Source |
        | --- | --- | --- |
        | Kiellinie waterfront | <img src="https://commons.wikimedia.org/wiki/Special:FilePath/Kiellinie%2C%20Kiel.jpg" alt="Kiellinie waterfront in Kiel" width="220"> | [Wiki](https://commons.wikimedia.org/) |
        """
        let data = try await MobilePDFExporter().pdfData(
            for: MarkdownDocument(title: "Wrapped Table", markdown: markdown)
        )
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let time = try XCTUnwrap(pdf.findString("10:52-11:05", withOptions: []).first).bounds(for: page)
        let stop = try XCTUnwrap(pdf.findString("Lübeck Hbf", withOptions: []).first).bounds(for: page)
        let action = try XCTUnwrap(pdf.findString("Walk straight", withOptions: []).first).bounds(for: page)
        let finalLine = try XCTUnwrap(pdf.findString("about 700 m.", withOptions: []).first).bounds(for: page)
        let nextRow = try XCTUnwrap(pdf.findString("11:05-11:20", withOptions: []).first).bounds(for: page)

        XCTAssertEqual(time.midY, stop.midY, accuracy: 2)
        XCTAssertEqual(time.midY, action.midY, accuracy: 2)
        XCTAssertLessThan(nextRow.maxY, finalLine.minY)
        XCTAssertFalse(pdfText(pdf).contains("<img"))
        XCTAssertFalse(pdf.findString("Remote", withOptions: []).isEmpty)
        XCTAssertFalse(pdf.findString("loaded", withOptions: []).isEmpty)

        let documentsURL = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        try data.write(to: documentsURL.appendingPathComponent("mobile-table-images.pdf"), options: .atomic)
    }

    func testLocalImageRendersWhileRemoteMissingAndCorruptImagesUseReadablePlaceholders() async throws {
        let imageURL = directory.appendingPathComponent("local.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        try XCTUnwrap(image.pngData()).write(to: imageURL)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.png"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("unreadable.png"),
            withIntermediateDirectories: false
        )
        let sourceURL = directory.appendingPathComponent("Images.md")
        let markdown = """
        # Images

        ![Local diagram](local.png)

        ![Missing diagram](missing.png)

        ![Broken diagram](broken.png)

        ![Unavailable diagram](unreadable.png)

        ![Remote diagram](https://example.com/remote.png)
        """
        try Data(markdown.utf8).write(to: sourceURL)
        let data = try await MobilePDFExporter().pdfData(for: try MarkdownDocument.load(from: sourceURL))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = pdfText(pdf)

        XCTAssertFalse(text.contains("Image not found: Local diagram"))
        XCTAssertTrue(text.contains("Image not found: Missing diagram"))
        XCTAssertTrue(text.contains("Image could not be displayed: Broken diagram"))
        XCTAssertTrue(text.contains("Image unavailable from this file provider: Unavailable diagram"))
        XCTAssertTrue(text.contains("Remote image not loaded: Remote diagram"))
    }

    func testHTMLImageTagsUseTheLocalOnlyImagePipelineInsteadOfPrintingMarkup() throws {
        let imageURL = directory.appendingPathComponent("local.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        try XCTUnwrap(image.pngData()).write(to: imageURL)
        let sourceURL = directory.appendingPathComponent("HTML Images.md")
        let markdown = """
        <img src="local.png" alt="Local HTML" width="32">

        | Idea | Representative Image |
        | --- | --- |
        | Harbor | <img src="https://example.com/harbor.jpg" alt="Remote harbor" width="220"> |
        """
        try Data(markdown.utf8).write(to: sourceURL)
        let attributed = try MobilePrintRenderer(configuration: .letter).render(
            document: try MarkdownDocument.load(from: sourceURL)
        )
        let attachments = (0..<attributed.length).compactMap {
            attributed.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment
        }

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].bounds.size, CGSize(width: 32, height: 16))
        XCTAssertTrue(attributed.string.contains("Remote image not loaded: Remote harbor"))
        XCTAssertFalse(attributed.string.contains("<img"))
    }

    func testInteractiveRemoteImagesExposeDownloadLinksAndRenderFromCache() async throws {
        let source = "https://example.com/remote.png"
        let cache = RemoteImageCache(directoryURL: directory.appendingPathComponent("remote-cache"))
        let document = MarkdownDocument(
            title: "Remote",
            markdown: "<img src='\(source)' alt='Remote art' width='48'>"
        )
        let unresolved = try MobilePrintRenderer(
            configuration: .letter,
            remoteImageCache: cache
        ).render(document: document)
        XCTAssertTrue(unresolved.string.contains("Remote image — tap to download: Remote art"))
        let action = try XCTUnwrap(unresolved.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(RemoteImageActionURL.downloadSource(from: action), source)

        let unresolvedPDF = try await MobilePDFExporter(
            remoteImageCache: cache
        ).pdfData(for: document)
        let annotationURL = try XCTUnwrap(
            PDFDocument(data: unresolvedPDF)?.page(at: 0)?.annotations.compactMap(\.url).first
        )
        XCTAssertEqual(RemoteImageActionURL.downloadSource(from: annotationURL), source)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
        }
        try cache.store(try XCTUnwrap(image.pngData()), for: source)
        let cached = try MobilePrintRenderer(
            configuration: .letter,
            remoteImageCache: cache
        ).render(document: document)
        let attachment = try XCTUnwrap(
            (0..<cached.length).compactMap {
                cached.attribute(.attachment, at: $0, effectiveRange: nil) as? NSTextAttachment
            }.first
        )
        XCTAssertEqual(attachment.bounds.size, CGSize(width: 48, height: 24))
        XCTAssertFalse(cached.string.contains("tap to download"))
    }

    func testEmptyDocumentStillProducesOneValidPage() async throws {
        let data = try await MobilePDFExporter().pdfData(
            for: MarkdownDocument(title: "Empty", markdown: "")
        )
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertNotNil(MobilePDFExporterError.renderingFailed.errorDescription)
    }

    func testCancelledExportThrowsCancellation() async {
        let document = MarkdownDocument(
            title: "Cancelled",
            markdown: String(repeating: "A paragraph that takes space.\n\n", count: 1_000)
        )
        let task = Task { @MainActor in
            try await MobilePDFExporter().pdfData(for: document)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testShowcaseFixtureProducesInspectablePDF() async throws {
        let showcaseURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "showcase", withExtension: "md")
        )
        let data = try await MobilePDFExporter().pdfData(
            for: try MarkdownDocument.load(from: showcaseURL)
        )
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = pdfText(pdf)

        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        XCTAssertTrue(text.contains("Markdown Printer Showcase"))
        XCTAssertTrue(text.contains("Headings"))
        XCTAssertTrue(text.contains("Local images"))
        XCTAssertTrue(text.contains("Image not found: A deliberately missing sample image"))
        XCTAssertFalse(text.contains("────"), "The thematic break should be a vector rule, not text glyphs.")

        let documentsURL = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        try data.write(to: documentsURL.appendingPathComponent("mobile-showcase.pdf"), options: .atomic)
    }

    private func pdfText(_ document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }
}

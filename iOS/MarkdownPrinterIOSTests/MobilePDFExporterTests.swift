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

import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class ReportedTablePaginationTests: XCTestCase {
    func testReportedTallImagePairKeepsBothEndsHeadersAndCaptionsWithoutEmptyPages() async throws {
        let directory = try temporaryDirectory()
        try writeImage(width: 1055, height: 4067, top: .red, bottom: .blue, name: "analysis.png", in: directory)
        try writeImage(width: 1158, height: 1500, top: .green, bottom: .magenta, name: "recommendation.png", in: directory)
        let text = MarkdownRenderer().render(markdown: """
        | Analysis report | Assistant recommendation |
        | --- | --- |
        | ![Analysis](analysis.png) | ![Recommendation](recommendation.png) |
        | *Analysis caption.* | *Recommendation caption.* |
        """, baseURL: directory)
        let exporter = PDFExporter()
        let synchronous = try exporter.pdfData(from: text)
        let asynchronous = try await exporter.pdfDataAsync(from: text)
        for data in [synchronous, asynchronous] {
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, 1, "Oversized table images must not create footer-only pages")
            let regions = try checkedRegions(in: document)
            let figurePage = try assertCompleteImage(top: .red, bottom: .blue, ratio: 1055.0 / 4067, regions: regions)
            XCTAssertEqual(try assertCompleteImage(top: .green, bottom: .magenta, ratio: 1158.0 / 1500, regions: regions), figurePage)
            try assertText(["Analysis report", "Assistant recommendation", "Analysis caption.", "Recommendation caption."], on: figurePage, in: document)
        }
        let sync = try XCTUnwrap(PDFDocument(data: synchronous))
        let asyncDocument = try XCTUnwrap(PDFDocument(data: asynchronous))
        XCTAssertEqual(sync.pageCount, asyncDocument.pageCount)
        XCTAssertEqual(sync.string, asyncDocument.string)
    }

    func testReportedScheduleImageAndExplanatoryCellMoveTogetherFromMidPage() throws {
        let directory = try temporaryDirectory()
        try writeImage(width: 1098, height: 1859, top: .red, bottom: .blue, name: "schedule.png", in: directory)
        let introduction = String(repeating: "Background before the schedule comparison.\n\n", count: 13)
        let text = MarkdownRenderer().render(markdown: """
        \(introduction)
        | Schedule configuration | Future review workflow |
        | --- | --- |
        | ![Schedule](schedule.png) | This example contains a date field and a choice of follow-up action. The description is deliberately long enough to wrap across several lines while the full illustration remains in the neighboring cell. |
        | *Schedule editor caption.* | *The future review became its own trackable workflow.* |
        """, baseURL: directory)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Background before") == true)
        let regions = try checkedRegions(in: document)
        let figurePage = try assertCompleteImage(top: .red, bottom: .blue, ratio: 1098.0 / 1859, regions: regions)
        XCTAssertEqual(figurePage, 1)
        try assertText(["Schedule configuration", "Future review workflow", "This example contains", "Schedule editor caption.", "trackable workflow"], on: figurePage, in: document)
    }

    func testSeveralReportedImageTablesDoNotLeaveStalePageBreaksOrOrphanHeaders() async throws {
        let directory = try temporaryDirectory()
        try writeImage(width: 1055, height: 4067, top: .red, bottom: .blue, name: "analysis.png", in: directory)
        try writeImage(width: 1158, height: 1500, top: .green, bottom: .magenta, name: "recommendation.png", in: directory)
        try writeImage(width: 1098, height: 1859, top: .cyan, bottom: .yellow, name: "schedule.png", in: directory)
        let text = MarkdownRenderer().render(markdown: """
        # Reported pagination cases

        This synthetic document recreates the reported image sizes without including workplace content.

        ## Tall report and recommendation

        A short explanatory paragraph introduces the comparison and its intended result.

        | Analysis report | Assistant recommendation |
        | --- | --- |
        | ![Tall analysis](analysis.png) | ![Recommendation](recommendation.png) |
        | *The complete report remains visible, including the red end marker.* | *The recommendation remains intact with its caption.* |

        Text after the tall comparison.

        ## Schedule review

        A short explanatory paragraph introduces the comparison and its intended result.

        A short explanatory paragraph introduces the comparison and its intended result.

        A short explanatory paragraph introduces the comparison and its intended result.

        A short explanatory paragraph introduces the comparison and its intended result.

        A short explanatory paragraph introduces the comparison and its intended result.

        A short explanatory paragraph introduces the comparison and its intended result.

        | Schedule configuration | How future reviews were created |
        | --- | --- |
        | ![Schedule editor](schedule.png) | The reviewer selected a future date and a workflow. This explanatory text shares the image row. |
        | *The complete schedule editor and its end marker stay visible.* | *The future review remains connected to its workflow.* |

        ## End of review

        All image markers, headers, and captions should remain intact.
        """, baseURL: directory)
        let exporter = PDFExporter()
        for data in [try exporter.pdfData(from: text), try await exporter.pdfDataAsync(from: text)] {
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertLessThanOrEqual(document.pageCount, 5, "Pagination corrections must not leave obsolete shortened containers behind")
            let regions = try checkedRegions(in: document)
            let figurePage = try assertCompleteImage(top: .red, bottom: .blue, ratio: 1055.0 / 4067, regions: regions)
            XCTAssertEqual(try assertCompleteImage(top: .green, bottom: .magenta, ratio: 1158.0 / 1500, regions: regions), figurePage)
            try assertText(["Analysis report", "Assistant recommendation", "The complete report remains visible, including the red end marker.", "The recommendation remains intact with its caption."], on: figurePage, in: document)
            let schedulePage = try assertCompleteImage(top: .cyan, bottom: .yellow, ratio: 1098.0 / 1859, regions: regions)
            try assertText(["Schedule configuration", "How future reviews were created", "The complete schedule editor and its end marker stay visible.", "The future review remains connected to its workflow."], on: schedulePage, in: document)
            for marker in ["Reported pagination cases", "Tall report and recommendation", "Text after the tall comparison.", "Schedule review", "End of review", "All image markers, headers, and captions should remain intact."] {
                XCTAssertTrue(document.string?.contains(marker) == true, "Missing surrounding content: \(marker)")
            }
        }
    }

    func testCaptionOnlyOverflowMovesItsImageWhenKeepingItWouldRequireExcessiveShrinking() async throws {
        let directory = try temporaryDirectory()
        try writeImage(width: 500, height: 400, top: .red, bottom: .blue, name: "figure.png", in: directory)
        let source = captionBoundarySource(in: directory, italic: true)
        let text = try placingCaptionAcrossNaturalBoundary(source)
        let exporter = PDFExporter()
        for data in [try exporter.pdfData(from: text), try await exporter.pdfDataAsync(from: text)] {
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, 2)
            XCTAssertTrue(document.page(at: 0)?.string?.contains("Existing table data") == true)
            let regions = try checkedRegions(in: document)
            let figurePage = try assertCompleteImage(top: .red, bottom: .blue, ratio: 1.25, regions: regions)
            XCTAssertEqual(figurePage, 1)
            try assertText(["Figure companion", "CAPTION-GAP-LEFT", "CAPTION-GAP-RIGHT", "Second caption line.", "Extra right caption line."], on: figurePage, in: document)
            let top = try XCTUnwrap(regions[figurePage][.red])
            let bottom = try XCTUnwrap(regions[figurePage][.blue])
            XCTAssertEqual(top.union(bottom).width, 100, accuracy: 2, "Moving the figure must preserve its requested size")
        }
    }

    func testOrdinaryFollowingRowIsNotMistakenForAnExtendedItalicCaption() throws {
        let directory = try temporaryDirectory()
        try writeImage(width: 500, height: 400, top: .red, bottom: .blue, name: "figure.png", in: directory)
        let source = captionBoundarySource(in: directory, italic: false)
        let text = try placingCaptionAcrossNaturalBoundary(source)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 2)
        let regions = try checkedRegions(in: document)
        let figurePage = try assertCompleteImage(top: .red, bottom: .blue, ratio: 1.25, regions: regions)
        XCTAssertEqual(figurePage, 0, "A substantial ordinary data row should retain its natural pagination")
        try assertText(["Figure companion"], on: 0, in: document)
        try assertText(["CAPTION-GAP-LEFT", "CAPTION-GAP-RIGHT"], on: 1, in: document)
        let top = try XCTUnwrap(regions[0][.red])
        let bottom = try XCTUnwrap(regions[0][.blue])
        XCTAssertEqual(top.union(bottom).width, 100, accuracy: 2)
    }

    func testTallItalicFollowingRowFlowsNaturallyWithoutCollapsingTheImage() throws {
        let directory = try temporaryDirectory()
        try writeImage(width: 500, height: 400, top: .red, bottom: .blue, name: "figure.png", in: directory)
        let longNote = (1...38).map { "Long italic note \($0)" }.joined(separator: "<br>")
        let text = MarkdownRenderer().render(markdown: """
        | Figure | Explanatory note |
        | --- | --- |
        | <img src='figure.png' width='100'> | Figure companion |
        | *\(longNote)* | *\(longNote)* |
        """, baseURL: directory)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertGreaterThan(document.pageCount, 1)
        let regions = try checkedRegions(in: document)
        let figurePage = try assertCompleteImage(top: .red, bottom: .blue, ratio: 1.25, regions: regions)
        XCTAssertEqual(figurePage, 0)
        let top = try XCTUnwrap(regions[0][.red])
        let bottom = try XCTUnwrap(regions[0][.blue])
        XCTAssertEqual(top.union(bottom).width, 100, accuracy: 2, "Oversized following prose must not reduce the preceding image to a sliver")
        XCTAssertTrue(document.string?.contains("Long italic note 38") == true)
    }

    private func captionBoundarySource(in directory: URL, italic: Bool) -> NSAttributedString {
        let emphasis = italic ? "*" : ""
        return MarkdownRenderer().render(markdown: """
        Boundary introduction.

        | Earlier context | Earlier value |
        | --- | --- |
        | Context already on this page | Existing table data |
        | <img src='figure.png' width='100'> | Figure companion |
        | \(emphasis)CAPTION-GAP-LEFT<br>Second caption line.\(emphasis) | \(emphasis)CAPTION-GAP-RIGHT<br>Second caption line.<br>Extra right caption line.\(emphasis) |
        """, baseURL: directory)
    }

    // Position a real native table boundary without repeatedly exporting PDFs.
    // The image fits on page one; its two-line caption needs more than the 15%
    // discretionary image reduction. A preceding body row avoids relying on
    // the separate first-row/header protection to repair this caption case.
    private func placingCaptionAcrossNaturalBoundary(_ source: NSAttributedString) throws -> NSAttributedString {
        let imageCharacter = try XCTUnwrap(source.string.firstIndex(of: "\u{fffc}"))
        let imageIndex = source.string.utf16.distance(from: source.string.utf16.startIndex, to: imageCharacter)
        let captionIndex = (source.string as NSString).range(of: "CAPTION-GAP-LEFT").location
        let imageStyle = try XCTUnwrap(source.attribute(.paragraphStyle, at: imageIndex, effectiveRange: nil) as? NSParagraphStyle)
        let cell = try XCTUnwrap(imageStyle.textBlocks.last as? NSTextTableBlock)
        let firstParagraph = (source.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let originalStyle = try XCTUnwrap(source.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let base = nativeLayout(source)
        let imageGlyph = base.manager.glyphIndexForCharacter(at: imageIndex)
        let initialBottom = base.manager.boundsRect(for: cell, at: imageGlyph, effectiveRange: nil).maxY
        for gap in stride(from: CGFloat(2), through: 18, by: 2) {
            let text = NSMutableAttributedString(attributedString: source)
            let style = try XCTUnwrap(originalStyle.mutableCopy() as? NSMutableParagraphStyle)
            style.paragraphSpacing += 684 - initialBottom - gap
            text.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
            let layout = nativeLayout(text)
            let firstPage = layout.manager.glyphRange(for: layout.container)
            let imageGlyph = layout.manager.glyphIndexForCharacter(at: imageIndex)
            let captionGlyph = layout.manager.glyphIndexForCharacter(at: captionIndex)
            let imageBounds = layout.manager.boundsRect(for: cell, at: imageGlyph, effectiveRange: nil)
            if NSLocationInRange(imageGlyph, firstPage), !NSLocationInRange(captionGlyph, firstPage),
               imageBounds.maxY <= 684 {
                return text
            }
        }
        return try XCTUnwrap(nil, "Could not construct a caption-only native page boundary")
    }

    private func nativeLayout(_ text: NSAttributedString) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: NSSize(width: 504, height: 684))
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }

    private enum Marker: CaseIterable {
        case red, green, blue, magenta, cyan, yellow

        var color: NSColor {
            switch self {
            case .red: return NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            case .green: return NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            case .blue: return NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            case .magenta: return NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            case .cyan: return NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
            case .yellow: return NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeImage(width: Int, height: Int, top: Marker, bottom: Marker, name: String, in directory: URL) throws {
        let size = NSSize(width: CGFloat(width), height: CGFloat(height))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor(white: 0.9, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let band = CGFloat(height) * 0.08
        top.color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: CGFloat(height) - band, width: CGFloat(width), height: band)).fill()
        bottom.color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: CGFloat(width), height: band)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }

    private func checkedRegions(in document: PDFDocument) throws -> [[Marker: CGRect]] {
        guard document.pageCount <= 5 else {
            XCTFail("Small image fixture produced \(document.pageCount) pages, indicating futile pagination")
            return []
        }
        return try (0..<document.pageCount).map { index in
            let page = try XCTUnwrap(document.page(at: index))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox).tiffRepresentation)))
            var regions: [Marker: CGRect] = [:]
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    let marker: Marker
                    if r > 0.5, b > 0.5, r > g + 0.3, b > g + 0.3 { marker = .magenta }
                    else if g > 0.5, b > 0.5, g > r + 0.3, b > r + 0.3 { marker = .cyan }
                    else if r > 0.5, g > 0.5, r > b + 0.3, g > b + 0.3 { marker = .yellow }
                    else if r > 0.5, r > g + 0.3, r > b + 0.3 { marker = .red }
                    else if g > 0.5, g > r + 0.3, g > b + 0.3 { marker = .green }
                    else if b > 0.5, b > r + 0.3, b > g + 0.3 { marker = .blue }
                    else { continue }
                    let pixel = CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
                    regions[marker] = regions[marker].map { $0.union(pixel) } ?? pixel
                }
            }
            for bounds in regions.values {
                XCTAssertGreaterThanOrEqual(bounds.minX, 54)
                XCTAssertLessThanOrEqual(bounds.maxX, 558)
                XCTAssertGreaterThanOrEqual(bounds.minY, 54)
                XCTAssertLessThanOrEqual(bounds.maxY, 738, "Image end marker painted into the footer on page \(index + 1)")
            }
            let bodyLines = (page.string ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != String(index + 1) }
            XCTAssertTrue(!bodyLines.isEmpty || !regions.isEmpty, "Page \(index + 1) contains only its footer")
            return regions
        }
    }

    @discardableResult
    private func assertCompleteImage(top: Marker, bottom: Marker, ratio: CGFloat, regions: [[Marker: CGRect]]) throws -> Int {
        let page = try XCTUnwrap(regions.firstIndex { $0[top] != nil })
        let first = try XCTUnwrap(regions[page][top])
        let last = try XCTUnwrap(regions[page][bottom], "The complete image must retain its bottom marker on the same page")
        XCTAssertGreaterThan(first.width, 20)
        XCTAssertGreaterThan(last.height, 3)
        XCTAssertLessThan(first.minY, last.minY)
        let bounds = first.union(last)
        XCTAssertEqual(bounds.width / bounds.height, ratio, accuracy: 0.025, "Image end markers must retain the complete original aspect ratio")
        return page
    }

    private func assertText(_ markers: [String], on page: Int, in document: PDFDocument) throws {
        let text = try XCTUnwrap(document.page(at: page)?.string)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for marker in markers { XCTAssertTrue(text.contains(marker), "Missing \(marker) on the image's page: \(text)") }
    }
}

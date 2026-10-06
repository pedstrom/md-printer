import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionFooterTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var timeZone: TimeZone { TimeZone(identifier: "America/New_York")! }

    func testDatePreferencesResolveCurrentAboveOriginalWithSeasonalTimeZones() throws {
        let current = try document("2026-07-02T12:00:00Z")
        let original = try document("2026-01-02T12:00:00Z")
        for choice: FooterValue in [.date, .dateTime, .dateTimeWithTimeZone] {
            let lines = choice.resolvedLines(for: current, original: original, locale: locale, timeZone: timeZone)
            XCTAssertEqual(lines.map(\.style), [.current, .original])
            XCTAssertEqual(lines.map(\.text), [
                choice.resolved(for: current, locale: locale, timeZone: timeZone),
                choice.resolved(for: original, locale: locale, timeZone: timeZone)
            ])
        }
        let zoned = FooterValue.dateTimeWithTimeZone.resolvedLines(
            for: current, original: original, locale: locale, timeZone: timeZone)
        XCTAssertTrue(zoned[0].text.hasSuffix("EDT"))
        XCTAssertTrue(zoned[1].text.hasSuffix("EST"))
        let regional = FooterValue.dateTimeWithTimeZone.resolvedLines(
            for: current, original: original, locale: Locale(identifier: "de_DE"), timeZone: timeZone)
        XCTAssertFalse(regional[0].text.contains("AM"))
        XCTAssertTrue(regional[0].text.hasPrefix("02.07.2026"))
    }

    func testEqualDisplayedDatesAndUnavailableMetadataUseOrdinaryCurrentFooter() throws {
        let current = try document("2026-07-02T12:00:00Z")
        let earlier = try document("2026-07-02T10:00:00Z")
        let missing = MarkdownDocument(title: "No metadata", markdown: "Body")
        XCTAssertEqual(FooterValue.date.resolvedLines(for: current, original: earlier, locale: locale, timeZone: timeZone),
                       [ResolvedFooterLine(text: "Jul 2, 2026")])
        XCTAssertEqual(FooterValue.date.resolvedLines(for: current, original: current, locale: locale, timeZone: timeZone),
                       [ResolvedFooterLine(text: "Jul 2, 2026")])
        for original in [missing, nil] {
            XCTAssertEqual(FooterValue.date.resolvedLines(for: current, original: original, locale: locale, timeZone: timeZone),
                           [ResolvedFooterLine(text: "Jul 2, 2026")])
        }
        XCTAssertEqual(FooterValue.date.resolvedLines(for: missing, original: current), [])
        XCTAssertEqual(FooterValue.none.resolvedLines(for: current, original: earlier), [])
        XCTAssertEqual(FooterValue.custom("Author\nName").resolvedLines(for: current, original: earlier),
                       [ResolvedFooterLine(text: "Author Name")])
        XCTAssertEqual(FooterValue.documentTitle.resolvedLines(for: current, original: earlier),
                       [ResolvedFooterLine(text: "Footer fixture")])
        XCTAssertEqual(FooterValue.filename.resolvedLines(for: current, original: earlier),
                       [ResolvedFooterLine(text: "Fixture.md")])
    }

    func testPlainConfigurationAccessRemainsMutableAndClearsRevisionStyling() {
        var configuration = ResolvedFooterConfiguration(leftLines: revisionLines, rightLines: revisionLines)
        XCTAssertEqual(configuration.left, "Jul 2, 2026\nJan 2, 2026")
        XCTAssertEqual(configuration.right, configuration.left)
        configuration.left = "Author"
        configuration.right = ""
        XCTAssertEqual(configuration, ResolvedFooterConfiguration(left: "Author"))
        configuration.left = ""
        configuration.right = "Publisher"
        XCTAssertEqual(configuration, ResolvedFooterConfiguration(right: "Publisher"))
        XCTAssertEqual(ResolvedFooterConfiguration(), ResolvedFooterConfiguration(leftLines: [], rightLines: []))
    }

    func testEmptyStructuredFooterLinesLeavePageNumberAndBodyReadable() throws {
        let footers = ResolvedFooterConfiguration(
            leftLines: [ResolvedFooterLine(text: "", style: .current)],
            rightLines: [ResolvedFooterLine(text: "", style: .original)])
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(
            from: MarkdownRenderer().render(markdown: "Readable body"), footers: footers)))
        let text = try XCTUnwrap(pdf.page(at: 0)?.string)
        XCTAssertTrue(text.contains("Readable body"))
        XCTAssertTrue(text.contains("1"))
    }

    func testPDFRevisionFooterIsSearchableStyledAndPreservesBodyPagination() throws {
        let renderer = MarkdownRenderer()
        let body = renderer.render(markdown: "# Footer fixture\n\n" + (0..<70).map { "Paragraph \($0). Body text remains unchanged." }.joined(separator: "\n\n"))
        let exporter = PDFExporter()
        let plain = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: body)))
        let marked = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: body,
            footers: ResolvedFooterConfiguration(leftLines: revisionLines, rightLines: revisionLines))))
        XCTAssertGreaterThan(marked.pageCount, 1)
        XCTAssertEqual(plain.pageCount, marked.pageCount)
        for index in 0..<marked.pageCount {
            let page = try XCTUnwrap(marked.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))
            let current = marked.findString("Jul 2, 2026", withOptions: []).filter { $0.pages.contains(page) }
            let original = marked.findString("Jan 2, 2026", withOptions: []).filter { $0.pages.contains(page) }
            XCTAssertEqual(current.count, 2)
            XCTAssertEqual(original.count, 2)
            let bounds = current.map { $0.bounds(for: page) }.sorted { $0.minX < $1.minX }
            let originalBounds = original.map { $0.bounds(for: page) }.sorted { $0.minX < $1.minX }
            for side in 0..<2 {
                XCTAssertGreaterThan(bounds[side].minY, originalBounds[side].maxY)
                XCTAssertLessThan(bounds[side].maxY, 54)
                XCTAssertGreaterThan(originalBounds[side].minY, 0)
            }
            let plainPage = try XCTUnwrap(plain.page(at: index))
            let plainBody = plain.findString("Paragraph", withOptions: []).filter { $0.pages.contains(plainPage) }
            let markedBody = marked.findString("Paragraph", withOptions: []).filter { $0.pages.contains(page) }
            XCTAssertEqual(plainBody.map { $0.bounds(for: plainPage) }, markedBody.map { $0.bounds(for: page) })
        }
        let page = try XCTUnwrap(marked.page(at: 0))
        let bitmap = try pixels(page)
        let yellow = try XCTUnwrap(pixelBounds(bitmap) { $0.redComponent > 0.8 && $0.greenComponent > 0.7 && $0.blueComponent < 0.7 && $0.greenComponent > $0.blueComponent + 0.2 })
        let red = try XCTUnwrap(pixelBounds(bitmap) { $0.redComponent > 0.5 && $0.greenComponent < 0.35 && $0.blueComponent < 0.35 })
        XCTAssertLessThan(yellow.maxY, red.minY, "Current yellow date must be above original red date")
        XCTAssertGreaterThan(yellow.minY, CGFloat(bitmap.pixelsHigh) - 54 * 3)
        XCTAssertGreaterThan(longestRedRun(bitmap), 90, "The original date has a continuous red strike through its spaces")
        if let fixturePath = ProcessInfo.processInfo.environment["MDPRINTER_FOOTER_FIXTURES"] {
            let directory = URL(fileURLWithPath: fixturePath, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try exporter.pdfData(from: body).write(to: directory.appendingPathComponent("ordinary.pdf"))
            let current = try document("2026-07-02T12:00:00Z")
            let original = try document("2026-01-02T12:00:00Z")
            let lines = FooterValue.dateTimeWithTimeZone.resolvedLines(
                for: current, original: original, locale: locale, timeZone: timeZone)
            let footers = ResolvedFooterConfiguration(leftLines: lines, rightLines: lines)
            let data = try exporter.pdfData(from: body, footers: footers)
            try data.write(to: directory.appendingPathComponent("revision.pdf"))
            try WordExporter().wordData(from: body, footers: footers).write(to: directory.appendingPathComponent("revision.docx"))
            let fixturePDF = try XCTUnwrap(PDFDocument(data: data))
            for index in 0..<min(fixturePDF.pageCount, 2) {
                let image = try pixels(XCTUnwrap(fixturePDF.page(at: index)))
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("revision-page-\(index + 1).png"))
            }
        }
    }

    func testNarrowPDFClipsAndTruncatesEachRevisionLineWithinItsColumn() throws {
        let setup = DocumentPageSetup(paperName: "Small", paperSize: CGSize(width: 190, height: 300), orientation: .portrait, scale: 1)
        let renderer = MarkdownRenderer(configuration: RendererConfiguration().applying(setup))
        let footers = ResolvedFooterConfiguration(leftLines: revisionLines, rightLines: revisionLines)
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter(configuration: renderer.configuration).pdfData(
            from: renderer.render(markdown: "Body"), footers: footers)))
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertFalse(try XCTUnwrap(page.string).contains("Jul 2, 2026"))
        let bitmap = try pixels(page)
        let yellow = try XCTUnwrap(pixelBounds(bitmap) { $0.redComponent > 0.8 && $0.greenComponent > 0.7 && $0.blueComponent < 0.7 && $0.greenComponent > $0.blueComponent + 0.2 })
        XCTAssertGreaterThanOrEqual(yellow.minX, 54 * 3)
        XCTAssertLessThanOrEqual(yellow.maxX, (190 - 54) * 3)
        // The middle column stays free of either revision color.
        let center = CGRect(x: (54 + 32.8) * 3, y: 0, width: 16.4 * 3, height: CGFloat(bitmap.pixelsHigh))
        XCTAssertNil(pixelBounds(bitmap, region: center.insetBy(dx: 2, dy: 0)) {
            ($0.redComponent > 0.8 && $0.greenComponent > 0.7 && $0.blueComponent < 0.7 && $0.greenComponent > $0.blueComponent + 0.2)
                || ($0.redComponent > 0.5 && $0.greenComponent < 0.35 && $0.blueComponent < 0.35)
        })
        if let fixturePath = ProcessInfo.processInfo.environment["MDPRINTER_FOOTER_FIXTURES"] {
            let directory = URL(fileURLWithPath: fixturePath, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let current = try document("2026-07-02T12:00:00Z")
            let original = try document("2026-01-02T12:00:00Z")
            let zoned = FooterValue.dateTimeWithTimeZone.resolvedLines(
                for: current, original: original, locale: Locale(identifier: "de_DE"), timeZone: timeZone)
            let footers = ResolvedFooterConfiguration(leftLines: zoned, rightLines: zoned)
            let body = renderer.render(markdown: "Body")
            let data = try PDFExporter(configuration: renderer.configuration).pdfData(from: body, footers: footers)
            try data.write(to: directory.appendingPathComponent("narrow.pdf"))
            try WordExporter().wordData(from: body, pageSetup: setup, footers: footers).write(
                to: directory.appendingPathComponent("narrow.docx"))
            try XCTUnwrap(try pixels(XCTUnwrap(PDFDocument(data: data)?.page(at: 0))).representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent("narrow-page.png"))
        }
    }

    func testWordFootersUseEditableStyledRunsWithCurrentAboveOriginal() throws {
        let xml = try wordFooter(footers: ResolvedFooterConfiguration(leftLines: revisionLines, rightLines: revisionLines))
        XCTAssertEqual(xml.components(separatedBy: "<w:highlight w:val=\"yellow\"/>").count - 1, 2)
        XCTAssertEqual(xml.components(separatedBy: "<w:strike/>").count - 1, 2)
        XCTAssertEqual(xml.components(separatedBy: "<w:color w:val=\"C70F14\"/>").count - 1, 2)
        for cell in xml.components(separatedBy: "<w:tc>").dropFirst() where cell.contains("Jul 2, 2026") {
            XCTAssertLessThan(try XCTUnwrap(cell.range(of: "Jul 2, 2026")).lowerBound,
                              try XCTUnwrap(cell.range(of: "Jan 2, 2026")).lowerBound)
            XCTAssertTrue(cell.contains("w:line=\"240\" w:lineRule=\"exact\""))
        }
        XCTAssertTrue(xml.contains("w:ascii=\"Avenir Next\""))
        XCTAssertTrue(xml.contains("<w:sz w:val=\"16\"/>"))
        XCTAssertTrue(xml.contains(" PAGE "))
        XCTAssertFalse(xml.contains("<w:pict>"))
        XCTAssertFalse(xml.contains("Current saved"))
        XCTAssertFalse(xml.contains("^"))
        let blank = try wordFooter(footers: ResolvedFooterConfiguration())
        XCTAssertFalse(blank.contains("<w:strike/>"))
        XCTAssertFalse(blank.contains("<w:highlight"))
        let plain = try wordFooter(footers: ResolvedFooterConfiguration(left: "Pete & Co.", right: "Title"))
        XCTAssertTrue(plain.contains("Pete &amp; Co."))
        XCTAssertFalse(plain.contains("<w:strike/>"))
    }

    func testNarrowWordFooterTruncatesBothLinesAndKeepsFixedColumns() throws {
        let setup = DocumentPageSetup(paperName: "Small", paperSize: CGSize(width: 190, height: 300), orientation: .portrait, scale: 1)
        let xml = try wordFooter(footers: ResolvedFooterConfiguration(leftLines: revisionLines, rightLines: revisionLines), setup: setup)
        XCTAssertTrue(xml.contains("w:type=\"fixed\""))
        XCTAssertEqual(xml.components(separatedBy: "<w:noWrap/>").count - 1, 2)
        XCTAssertFalse(xml.contains("Jul 2, 2026"))
        XCTAssertFalse(xml.contains("Jan 2, 2026"))
        XCTAssertTrue(xml.contains("…"))
        XCTAssertTrue(xml.contains("<w:tblW w:w=\"1640\""))
    }

    private var revisionLines: [ResolvedFooterLine] {
        [ResolvedFooterLine(text: "Jul 2, 2026", style: .current), ResolvedFooterLine(text: "Jan 2, 2026", style: .original)]
    }

    private func document(_ timestamp: String) throws -> MarkdownDocument {
        MarkdownDocument(sourceURL: URL(fileURLWithPath: "/tmp/Fixture.md"),
            sourceModificationDate: try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp)),
            title: "Footer fixture", markdown: "Body")
    }

    private func pixels(_ page: PDFPage) throws -> NSBitmapImageRep {
        let size = page.bounds(for: .mediaBox).size
        let image = page.thumbnail(of: CGSize(width: size.width * 3, height: size.height * 3), for: .mediaBox)
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
    }

    private func pixelBounds(_ bitmap: NSBitmapImageRep, region: CGRect? = nil, matching predicate: (NSColor) -> Bool) -> CGRect? {
        let area = region ?? CGRect(x: 0, y: bitmap.pixelsHigh - 54 * 3, width: bitmap.pixelsWide, height: 54 * 3)
        var bounds = CGRect.null
        for y in max(0, Int(area.minY))..<min(bitmap.pixelsHigh, Int(area.maxY)) {
            for x in max(0, Int(area.minX))..<min(bitmap.pixelsWide, Int(area.maxX)) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) {
                    bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return bounds.isNull ? nil : bounds
    }

    private func longestRedRun(_ bitmap: NSBitmapImageRep) -> Int {
        var longest = 0
        for y in (bitmap.pixelsHigh - 54 * 3)..<bitmap.pixelsHigh {
            var run = 0
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent > 0.5, color.greenComponent < 0.35, color.blueComponent < 0.35 {
                    run += 1
                    longest = max(longest, run)
                } else { run = 0 }
            }
        }
        return longest
    }

    private func wordFooter(footers: ResolvedFooterConfiguration, setup: DocumentPageSetup = .letter) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Footer.docx")
        try WordExporter().wordData(from: MarkdownRenderer().render(markdown: "Editable body"), pageSetup: setup, footers: footers).write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/footer1.xml"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

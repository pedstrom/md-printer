import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionOverflowTests: XCTestCase {
    func testNarrowGapCanShowOnlyACaretAndEllipsis() throws {
        let font = NSFont.systemFont(ofSize: 7)
        let width = ceil(("^ …" as NSString).size(withAttributes: [.font: font]).width)
        let cell = CGRect(x: 20, y: 20, width: width, height: 30)
        let placed = RevisionAnnotationLayout.place(label: "^ earlier wording that cannot fit",
            anchor: CGPoint(x: cell.minX, y: 25), line: CGRect(x: 20, y: 20, width: width, height: 5),
            content: cell, page: cell, occupied: [], notes: [], font: font, cellBounds: cell)
        XCTAssertEqual(placed.1, "^ …")
        XCTAssertTrue(cell.contains(placed.0))
    }

    func testCompletelyBlockedCalloutFallsBackToBoundaryEllipsis() throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let anchor = CGPoint(x: 100, y: 120)
        let placed = RevisionAnnotationLayout.place(label: "^ earlier wording",
            anchor: anchor, line: page, content: page, page: page,
            occupied: [page], notes: [], font: NSFont.systemFont(ofSize: 7))
        XCTAssertTrue(placed.0.isEmpty)
        XCTAssertEqual(placed.0.origin, anchor)
        XCTAssertEqual(placed.1, "…")
    }

    func testCrowdedComparisonStillRendersSynchronouslyAndAsynchronously() async throws {
        let configuration = RendererConfiguration(pageSize: CGSize(width: 144, height: 180),
            pageMargins: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        let text = MarkdownRenderer(configuration: configuration).render(markdown: "CURRENT BODY.\n\nUNCHANGED DETAILS.")
        var decorations = RevisionDecorations()
        decorations.highlights = [(text.string as NSString).range(of: "CURRENT")]
        decorations.deletions = (0..<80).map {
            RevisionDeletion(location: 0, text: "earlier requirement \($0) with supporting wording", isImage: $0 == 79)
        }
        let exporter = PDFExporter(configuration: configuration)
        let notes = try exporter.revisionNoteLayout(from: text, decorations: decorations)
        XCTAssertEqual(notes.count, decorations.deletions.count)
        XCTAssertTrue(notes.contains { $0.frame.isEmpty && $0.label == "…" })
        let plainData = try exporter.pdfData(from: text)
        let markedData = try exporter.pdfData(from: text, decorations: decorations)
        let asyncData = try await exporter.pdfDataAsync(from: text, decorations: decorations)
        let plain = try XCTUnwrap(PDFDocument(data: plainData))
        for data in [markedData, asyncData] {
            let marked = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(marked.pageCount, plain.pageCount)
            XCTAssertFalse(marked.findString("…", withOptions: []).isEmpty)
            for phrase in ["CURRENT BODY.", "UNCHANGED DETAILS."] {
                XCTAssertEqual(marked.findString(phrase, withOptions: []).count, plain.findString(phrase, withOptions: []).count)
            }
        }
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_OVERFLOW_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try plainData.write(to: output.appendingPathComponent("overflow-plain.pdf"))
            try markedData.write(to: output.appendingPathComponent("overflow-marked.pdf"))
        }
    }

    func testUnreachableCalloutExhaustsConnectorRetriesWithoutRejectingPDF() throws {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 8
        style.maximumLineHeight = 8
        let font = FontBook(configuration: RendererConfiguration()).regular(size: 10)
        let text = NSAttributedString(string: "IMMMMMMMMM\n" + String(repeating: String(repeating: "M", count: 40) + "\n", count: 18),
            attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
        var decorations = RevisionDecorations()
        decorations.deletions = [RevisionDeletion(location: 1, text: "an earlier requirement with a long supporting explanation")]
        let exporter = PDFExporter()
        let note = try XCTUnwrap(exporter.revisionNoteLayout(from: text, decorations: decorations).first)
        XCTAssertTrue(note.isBoundaryOnly)
        XCTAssertEqual(note.label, "…")
        XCTAssertTrue(note.leader.isEmpty)
        let plain = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: text)))
        let marked = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: text, decorations: decorations)))
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        XCTAssertEqual(marked.findString("IMMMMMMMMM", withOptions: []).count, 1)
        XCTAssertFalse(marked.findString("…", withOptions: []).isEmpty)
    }
}

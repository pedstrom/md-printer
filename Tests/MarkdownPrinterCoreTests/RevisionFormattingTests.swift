import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionFormattingTests: XCTestCase {
    private func revision(_ old: String, _ new: String) -> RevisionRenderedText {
        MarkdownRenderer().render(document: MarkdownDocument(title: "New", markdown: new),
                                  original: MarkdownDocument(title: "Old", markdown: old))
    }
    private func highlighted(_ result: RevisionRenderedText) -> String {
        result.decorations.highlights.map { (result.text.string as NSString).substring(with: $0) }.joined(separator: "|")
    }

    /// Opt-in visual review of local documents; generated content stays outside Git.
    func testLocalRevisionReviewFixtures() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let currentPath = environment["MDPRINTER_REVIEW_CURRENT"],
              let originalPath = environment["MDPRINTER_REVIEW_ORIGINAL"],
              let outputPath = environment["MDPRINTER_REVISION_FIXTURES"] else { return }
        let current = try MarkdownDocument.load(from: URL(fileURLWithPath: currentPath))
        let original = try MarkdownDocument.load(from: URL(fileURLWithPath: originalPath))
        let result = MarkdownRenderer().render(document: current, original: original)
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try PDFExporter().pdfData(from: result.text, decorations: result.decorations).write(to: output.appendingPathComponent("review.pdf"))
        try PDFExporter().pdfData(from: MarkdownRenderer().render(document: current)).write(to: output.appendingPathComponent("review-plain.pdf"))
        let string = result.text.string as NSString
        let notes = result.decorations.deletions.map { note in
            let start = max(0, note.location - 60), end = min(string.length, note.location + 100)
            return ["location": note.location, "removed": note.text, "image": note.isImage,
                    "currentContext": string.substring(with: NSRange(location: start, length: end - start))] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: notes, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("review-notes.json"))
        if environment["MDPRINTER_REVIEW_WORD"] == "1" {
            try WordExporter().wordData(from: result.text, decorations: result.decorations).write(to: output.appendingPathComponent("review.docx"))
        }
    }

    func testReplacementAdditionAndDeletedWords() {
        let result = revision("Payment is due Monday.", "Payment is due Tuesday.\n\nNew paragraph.")
        XCTAssertTrue(highlighted(result).contains("Tuesday"))
        XCTAssertTrue(highlighted(result).contains("New paragraph."))
        XCTAssertFalse(highlighted(result).contains("Payment"))
        XCTAssertEqual(result.decorations.deletions.map(\.text), ["Monday"])
    }
    func testMinorPunctuationDoesNotCreateDeletionCallouts() {
        for pair in [("Hello, world!", "Hello world."), ("one—two", "one two"), ("Quoted ‘word’.", "Quoted word.")] {
            XCTAssertTrue(revision(pair.0, pair.1).decorations.deletions.isEmpty)
        }
        XCTAssertEqual(revision("Updated: 2026-10-02", "Updated: 2026-10-05").decorations.deletions.map(\.text), ["02"])
        XCTAssertEqual(revision("Do not approve.", "Do approve.").decorations.deletions.map(\.text), ["not"])
        XCTAssertEqual(revision("Value 50%", "Value 50").decorations.deletions.map(\.text), ["%"])
        XCTAssertEqual(revision("`a < b`", "`a > b`").decorations.deletions.map(\.text), ["<"])
        XCTAssertFalse(revision("A 👩🏽‍💻", "A 👩🏽‍🚀").decorations.deletions.isEmpty)
    }
    func testInitialCapitalizationHasHighlightWithoutDeletionNoise() {
        for pair in [("Contract", "contract"), ("a Contract applies", "a contract applies"), ("café", "Café"),
                     ("Morning outing", "Pleasant morning outing")] {
            let result = revision(pair.0, pair.1)
            XCTAssertFalse(result.decorations.highlights.isEmpty)
            XCTAssertTrue(result.decorations.deletions.isEmpty)
        }
        XCTAssertEqual(revision("US market", "us market").decorations.deletions.map(\.text), ["US"])
        XCTAssertEqual(revision("`Value`", "`value`").decorations.deletions.map(\.text), ["Value"])
    }
    func testRewrittenPassagesUseCoherentDeletionPhrases() {
        let result = revision("The editor is preparing the travel-guide introduction and a proposed itinerary.",
                              "The editor is drafting multiple route-level recommendations that readers validate as useful destinations, including a proposed itinerary.")
        XCTAssertEqual(result.decorations.deletions.map(\.text), ["preparing the travel-guide introduction and"])
        XCTAssertTrue(highlighted(result).contains("drafting"))
        XCTAssertFalse(highlighted(result).contains("The editor is"))
        let twoSentences = revision("The red cat and blue dog wait. The green bird and white fish sleep.",
                                    "The orange cat and black dog run. The purple bird and gold fish swim.")
        // Both sentences are rewritten; incidental shared nouns should not
        // fragment either the highlight or its deletion callout.
        XCTAssertEqual(twoSentences.decorations.deletions.map(\.text), ["red cat and blue dog wait. The green bird and white fish sleep"])
        XCTAssertEqual(highlighted(twoSentences), "orange cat and black dog run. The purple bird and gold fish swim")
    }
    func testEditedBlockMatchingFavorsSharedContentOverRepeatedWords() {
        let result = revision("Shared common method ordinary context.\n\nUnrelated apple banana.",
                              "Shared common method revised context.\n\nShared method ordinary expanded reference supplemental updated model ordinary ordinary ordinary ordinary.")
        XCTAssertFalse(highlighted(result).hasPrefix("Shared common method"))
        XCTAssertTrue(highlighted(result).contains("revised"))
        XCTAssertTrue(result.decorations.deletions.contains { $0.text == "ordinary" })
    }
    func testIdenticalAndEquivalentSyntaxAndSoftWhitespace() {
        for pair in [("**Strong** text", "__Strong__ text"), ("One two three.", "One\ntwo three."), ("Text", "Text")] {
            let result = revision(pair.0, pair.1)
            XCTAssertEqual(result.decorations, RevisionDecorations())
        }
        let document = MarkdownDocument(title: "T", markdown: "Text")
        XCTAssertEqual(MarkdownRenderer().render(document: document, original: nil).text.string, "Text\n")
    }
    func testFormattingLinkHeadingQuoteAndTableAlignmentChanges() {
        for pair in [("Text", "**Text**"), ("# Heading", "## Heading"), ("Text", "> Text"),
                     ("[Link](first.md)", "[Link](second.md)"),
                     ("| A |\n| --- |\n| B |", "| A |\n| ---: |\n| B |")] {
            XCTAssertFalse(revision(pair.0, pair.1).decorations.highlights.isEmpty)
        }
    }
    func testNestedContainersPreserveSemanticFormattingChanges() {
        for pair in [("> Text", "> > Text"), ("> *Text*", "> Text"),
                     ("> **Text**", "> Text"), ("> `Text`", "> Text"),
                     ("- Outer\n- Child", "- Outer\n  - Child")] {
            XCTAssertFalse(revision(pair.0, pair.1).decorations.highlights.isEmpty, "\(pair)")
        }
        XCTAssertEqual(revision("> ***Text***", "> **_Text_**").decorations, RevisionDecorations())
        XCTAssertTrue(revision("![Same](same.png)", "> ![Same](same.png)").decorations.images.isEmpty)
    }
    func testPartialWordFormattingDoesNotDeleteText() {
        let result = revision("Hello world", "Hel**lo** world")
        XCTAssertTrue(highlighted(result).contains("Hello"))
        XCTAssertTrue(result.decorations.deletions.isEmpty)
    }
    func testMovedAndRepeatedParagraphs() {
        let result = revision("First paragraph.\n\nSecond paragraph.\n\nThird paragraph.",
                              "Third paragraph.\n\nFirst paragraph.\n\nSecond paragraph.")
        XCTAssertTrue(highlighted(result).contains("Third paragraph."))
        XCTAssertTrue(result.decorations.deletions.contains { $0.text == "Third paragraph." })
        XCTAssertEqual(revision("Same.\n\nSame.", "Same.\n\nSame.").decorations, RevisionDecorations())
    }
    func testImageReferencesOnlyAndHTMLImages() {
        for pair in [("![Photo](old.png)", "![Photo](new.png)"),
                     ("<img src=\"old.png\" width=\"40\">", "<img src=\"new.png\" width=\"40\">")] {
            XCTAssertFalse(revision(pair.0, pair.1).decorations.images.isEmpty)
        }
        let removed = revision("![Photo](does-not-exist.png)", "Text")
        XCTAssertEqual(removed.decorations.deletions.first?.label, "^ removed image")
        XCTAssertTrue(revision("![Photo](same.png)", "![Photo](same.png)").decorations.images.isEmpty)
        XCTAssertEqual(revision("", "![First](first.png)![Second](second.png)").decorations.images.count, 2)
    }
    func testCodeHardBreakListsFootnotesAndUnicode() {
        for pair in [("`a b`", "`a  b`"), ("one two", "one  \ntwo"),
                     ("- [ ] Task", "- [x] Task"),
                     ("Text[^a]\n\n[^a]: Before", "Text[^a]\n\n[^a]: After"),
                     ("Café 東京 👩🏽‍💻", "Café 東京 👩🏽‍🚀")] {
            XCTAssertFalse(revision(pair.0, pair.1).decorations.highlights.isEmpty)
        }
    }
    func testAllRemovedAndTrailingRemovalPDF() throws {
        for pair in [("Entire document", ""), ("Keep trailing words", "Keep")] {
            let result = revision(pair.0, pair.1)
            XCTAssertFalse(result.decorations.deletions.isEmpty)
            let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: result.text, decorations: result.decorations)))
            XCTAssertEqual(pdf.pageCount, 1)
            XCTAssertTrue(pdf.string?.contains(result.decorations.deletions[0].text) == true)
            XCTAssertFalse(pdf.string?.contains("deleted") == true)
        }
    }
    func testPDFBodyGeometryAndAsyncMatch() async throws {
        let current = "# Title\n\n" + (0..<120).map { "Unique paragraph [\($0)] has a changed Tuesday deadline and many ordinary words." }.joined(separator: "\n\n")
        let result = revision(current.replacingOccurrences(of: "Tuesday", with: "Monday"), current)
        let exporter = PDFExporter()
        let marked = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: result.text, decorations: result.decorations)))
        let plain = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: MarkdownRenderer().render(markdown: current))))
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        for index in 0..<120 {
            let phrase = "Unique paragraph [\(index)]"
            let ar = try XCTUnwrap(plain.findString(phrase, withOptions: []).first)
            let br = try XCTUnwrap(marked.findString(phrase, withOptions: []).first)
            let a = try XCTUnwrap(ar.pages.first), b = try XCTUnwrap(br.pages.first)
            XCTAssertEqual(plain.index(for: a), marked.index(for: b))
            XCTAssertEqual(ar.bounds(for: a).minX, br.bounds(for: b).minX, accuracy: 0.01)
            XCTAssertEqual(ar.bounds(for: a).minY, br.bounds(for: b).minY, accuracy: 0.01)
        }
        let async = try await exporter.pdfDataAsync(from: result.text, decorations: result.decorations)
        XCTAssertEqual(PDFDocument(data: async)?.pageCount, marked.pageCount)
    }
    func testAnnotationTruncationPlacementMarginsAndBoundaryFallback() throws {
        let font = NSFont.systemFont(ofSize: 7)
        XCTAssertEqual(RevisionAnnotationLayout.truncate("Short", width: 100, font: font), "Short")
        XCTAssertTrue(RevisionAnnotationLayout.truncate("A very long deletion label", width: 35, font: font).hasSuffix("…"))
        let page = CGRect(x: 0, y: 0, width: 612, height: 792), content = CGRect(x: 54, y: 54, width: 504, height: 684)
        let empty = RevisionAnnotationLayout.place(label: "^ words", anchor: CGPoint(x: 54, y: 54),
            line: CGRect(x: 54, y: 54, width: 0, height: 0), content: content, page: page, occupied: [], notes: [], font: font)
        XCTAssertTrue(content.contains(empty.0))
        let margin = RevisionAnnotationLayout.place(label: "^ words", anchor: CGPoint(x: 54, y: 54),
            line: content, content: content, page: page, occupied: [content], notes: [], font: font)
        XCTAssertGreaterThan(margin.0.minX, content.maxX)
        let anchorLine = CGRect(x: 54, y: 100, width: 504, height: 20)
        let nearest = RevisionAnnotationLayout.place(label: "^ words", anchor: CGPoint(x: 54, y: 120),
            line: anchorLine, content: content, page: page,
            occupied: [CGRect(x: 54, y: 70, width: 504, height: 10), anchorLine,
                       CGRect(x: 54, y: 121, width: 504, height: 20)], notes: [], font: font)
        XCTAssertEqual(nearest.0.minY, 140)
        let fallback = RevisionAnnotationLayout.place(label: "^ words", anchor: .zero,
            line: page, content: page, page: page, occupied: [page], notes: [], font: font)
        XCTAssertTrue(fallback.0.isEmpty)
        XCTAssertEqual(fallback.1, "…")
    }
}

import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionDeletionSummaryTests: XCTestCase {
    private func revision(_ old: String, _ current: String) -> RevisionRenderedText {
        MarkdownRenderer().render(document: MarkdownDocument(title: "Current", markdown: current),
                                  original: MarkdownDocument(title: "Original", markdown: old))
    }

    func testWholeParagraphCountsPreserveEvidenceAndTakePriorityOverSentences() {
        let removed = "Retired policy. Earlier guidance.\n\nObsolete recommendation."
        let result = revision("Opening stays.\n\n\(removed)\n\nClosing stays.", "Opening stays.\n\nClosing stays.")
        XCTAssertEqual(result.decorations.deletions.map(\.label), ["^ removed 2 paragraphs"])
        XCTAssertEqual(result.decorations.deletions.first?.summary, .paragraphs(2))
        XCTAssertEqual(result.decorations.deletions.first?.text, "Retired policy. Earlier guidance. Obsolete recommendation.")
        XCTAssertFalse(result.decorations.deletions[0].strikesWording)
        XCTAssertEqual(revision("Whole document.", "").decorations.deletions.first?.label, "^ removed 1 paragraph")
    }

    func testSeparateParagraphRemovalsDoNotMergeAcrossSurvivingContent() {
        let result = revision("Retired beginning.\n\nKept middle.\n\nRetired ending.", "Kept middle.")
        XCTAssertEqual(result.decorations.deletions.map(\.label), ["^ removed 1 paragraph", "^ removed 1 paragraph"])
        XCTAssertNotEqual(result.decorations.deletions[0].location, result.decorations.deletions[1].location)
    }

    func testCompleteSentencesWithinSurvivingParagraphUseSingularAndPluralCounts() {
        let opening = "The opening sentence has several stable words."
        let closing = "The closing sentence also keeps its original wording."
        for (removed, count) in [("Retired advice.", 1), ("Retired advice. Obsolete policy! Earlier guidance?", 3)] {
            let result = revision("\(opening) \(removed) \(closing)", "\(opening) \(closing)")
            XCTAssertEqual(result.decorations.deletions.map(\.summary), [.sentences(count)])
            XCTAssertEqual(result.decorations.deletions.first?.label, "^ removed \(count) sentence\(count == 1 ? "" : "s")")
            XCTAssertEqual(result.decorations.deletions.first?.location, (result.text.string as NSString).range(of: closing).location)
        }
    }

    func testSentenceBoundariesHandleAbbreviationsDecimalsUnicodeAndSoftLineBreaks() {
        let opening = "These opening words remain stable and unchanged."
        let closing = "These closing words remain stable and unchanged."
        for removed in ["Dr. Smith charged $3.50 for the **café** visit.", "An obsolete\nrecommendation mentions 東京 and café.", "“Retired advice!”", "「廃止された案内です。」"] {
            let result = revision("\(opening) \(removed) \(closing)", "\(opening) \(closing)")
            XCTAssertEqual(result.decorations.deletions.map(\.summary), [.sentences(1)], removed)
        }
    }

    func testShortFragmentsStayStruckAndLongFragmentsCountOnlyDeletedWords() {
        let words = ["retired", "obsolete", "outdated", "expired", "abandoned", "superseded", "previous", "former", "earlier", "historic", "redundant", "unused", "old"]
        for count in [1, 12, 13] {
            let fragment = words.prefix(count).joined(separator: " ")
            let result = revision("Keep this \(fragment) recommendation for careful review.", "Keep this recommendation for careful review.")
            XCTAssertEqual(result.decorations.deletions.first?.summary, count > 12 ? .words(count) : nil)
            XCTAssertEqual(result.decorations.deletions.first?.strikesWording, count <= 12)
            XCTAssertEqual(result.decorations.deletions.first?.label, count > 12 ? "^ removed 13 words" : "^ \(fragment)")
        }
        let rewrite = revision("The red cat and blue dog wait. The green bird and white fish sleep.",
                               "The orange cat and black dog run. The purple bird and gold fish swim.")
        XCTAssertFalse(rewrite.decorations.deletions.contains { if case .sentences = $0.summary { return true }; return false })
        // Broad excerpts include surviving words; their length must not inflate
        // the exact deleted-word count into a removal summary.
        XCTAssertTrue(rewrite.decorations.deletions.allSatisfy { $0.summary == nil })
    }

    func testLongRewriteWordCountExcludesSurvivingExcerptAnchors() {
        let prefix = "This stable introductory passage keeps its full original wording. "
        let old = prefix + "The ancient cat and tired dog admire faded maps beside cracked windows while weary birds circle dusty towers."
        let current = prefix + "The young cat and lively dog explore fresh paths near bright doors as cheerful birds cross modern bridges."
        let result = revision(old, current)
        XCTAssertFalse(result.decorations.deletions.isEmpty)
        XCTAssertFalse(result.decorations.deletions.contains { if case .sentences = $0.summary { return true }; return false })
        XCTAssertEqual(result.decorations.deletions.map(\.summary), [.words(13)])
    }

    func testHeadingsAndLiteralCodeDoNotClaimParagraphOrSentenceRemoval() {
        for old in ["# Retired heading.", "```\nretired.code();\n```"] {
            let result = revision(old + "\n\nKept body.", "Kept body.")
            XCTAssertFalse(result.decorations.deletions.isEmpty)
            XCTAssertTrue(result.decorations.deletions.allSatisfy { $0.summary == nil }, old)
        }
        XCTAssertEqual(revision("> Retired quotation.\n\nKept body.", "Kept body.").decorations.deletions.first?.summary, .paragraphs(1))
        let list = "- " + Array(repeating: "retired", count: 13).joined(separator: " ")
        XCTAssertEqual(revision(list + "\n\nKept body.", "Kept body.").decorations.deletions.first?.summary, .listItems(1))
        let heading = "# " + Array(repeating: "outdated", count: 13).joined(separator: " ")
        XCTAssertEqual(revision(heading + "\n\n" + list + "\n\nKept body.", "Kept body.").decorations.deletions.map(\.summary), [.words(13), .listItems(1)])
    }

    func testSentencesInListsCellsAndBesideInlineCodeUseSentenceCounts() {
        for (old, summary) in [("- Retired list sentence.", RevisionDeletion.Summary.listItems(1)), ("| Topic |\n| --- |\n| Retired cell sentence. |", .tables(1))] {
            let result = revision(old + "\n\nKept body.", "Kept body.")
            XCTAssertTrue(result.decorations.deletions.contains { $0.summary == summary }, old)
            XCTAssertFalse(result.decorations.deletions.contains { if case .paragraphs = $0.summary { return true }; return false })
        }
        let current = "Keep the `originalCode` in this opening sentence. Keep this closing sentence unchanged."
        let old = current.replacingOccurrences(of: " Keep this closing", with: " Retired advice. Keep this closing")
        XCTAssertEqual(revision(old, current).decorations.deletions.map(\.summary), [.sentences(1)])
    }

    func testImageAndTextMetadataStayDistinctEvenWithTheSameLabel() {
        let image = RevisionDeletion(location: 0, text: "", isImage: true)
        let text = RevisionDeletion(location: 0, text: "removed image")
        XCTAssertEqual(image.label, text.label)
        XCTAssertFalse(image.strikesWording)
        XCTAssertTrue(text.strikesWording)
        let result = revision("Retired prose. ![Photo](missing.png)\n\nMore retired prose.\n\nKept body.", "Kept body.")
        XCTAssertEqual(result.decorations.deletions.map(\.label), ["^ removed 2 paragraphs", "^ removed image"])
        XCTAssertTrue(result.decorations.deletions.allSatisfy { !$0.strikesWording })
    }

    func testSummaryPlacementPrefersACompleteLabelAndFallsBackWithoutReflow() {
        let font = NSFont.systemFont(ofSize: 7)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let content = CGRect(x: 54, y: 54, width: 504, height: 684)
        let line = CGRect(x: 54, y: 100, width: 504, height: 15)
        let note = RevisionAnnotationLayout.place(label: "^ removed 3 sentences", anchor: CGPoint(x: 535, y: 115),
            line: line, content: content, page: page, occupied: [line], notes: [], font: font, isSummary: true)
        XCTAssertEqual(note.1, "^ removed 3 sentences")
        let blocked = RevisionAnnotationLayout.place(label: "^ removed 3 sentences", anchor: content.origin,
            line: content, content: content, page: page, occupied: [page], notes: [], font: font, isSummary: true)
        XCTAssertTrue(blocked.0.isEmpty)
        XCTAssertEqual(blocked.1, "…")
    }

    func testSummaryPDFKeepsBodyGeometryCaretsAndUnstruckRedWording() async throws {
        let opening = "These opening words remain stable and unchanged."
        let closing = "These closing words remain stable and unchanged."
        let current = "# Removal summaries\n\n\(opening) \(closing)\n\nKept final paragraph."
        let original = "# Removal summaries\n\n\(opening) Retired advice. Obsolete policy! Earlier guidance? \(closing)\n\nRetired paragraph one.\n\nRetired paragraph two.\n\nKept final paragraph."
        let result = revision(original, current)
        let exporter = PDFExporter()
        let layouts = try exporter.revisionNoteLayout(from: result.text, decorations: result.decorations)
        XCTAssertEqual(layouts.count, 2)
        XCTAssertTrue(layouts.allSatisfy { !$0.strikeWording && !$0.isImage && !$0.isBoundaryOnly })
        let data = try exporter.pdfData(from: result.text, decorations: result.decorations)
        let marked = try XCTUnwrap(PDFDocument(data: data))
        let plainData = try exporter.pdfData(from: result.text)
        let plain = try XCTUnwrap(PDFDocument(data: plainData))
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        XCTAssertTrue(marked.string?.contains("removed 3 sentences") == true)
        XCTAssertTrue(marked.string?.contains("removed 2 paragraphs") == true)
        XCTAssertFalse(marked.string?.contains("Retired advice") == true)
        for phrase in [opening, closing, "Kept final paragraph."] {
            let a = try XCTUnwrap(plain.findString(phrase, withOptions: []).first)
            let b = try XCTUnwrap(marked.findString(phrase, withOptions: []).first)
            XCTAssertEqual(a.bounds(for: try XCTUnwrap(a.pages.first)), b.bounds(for: try XCTUnwrap(b.pages.first)))
        }
        let asyncData = try await exporter.pdfDataAsync(from: result.text, decorations: result.decorations)
        XCTAssertEqual(PDFDocument(data: asyncData)?.string, marked.string)
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("removal-summaries.pdf"))
            try plainData.write(to: output.appendingPathComponent("removal-summaries-plain.pdf"))
            try WordExporter().wordData(from: result.text, decorations: result.decorations).write(to: output.appendingPathComponent("removal-summaries.docx"))
        }
    }

    func testMixedSummaryFixturePreservesMultiplePagesTablesAndExactBodyPositions() throws {
        let fragment = "retired obsolete outdated expired abandoned superseded previous former earlier historic redundant unused old"
        let tail = (1...45).map { "Continued paragraph \($0) keeps its original wording and gives the comparison several pages of stable searchable prose." }.joined(separator: "\n\n")
        let current = """
        # Removal summaries

        ## Complete sentences

        These opening words remain stable and unchanged. These closing words remain stable and unchanged.

        ## Whole paragraphs

        Kept final paragraph.

        ## Short edits and long fragments

        The deadline is Tuesday.

        Keep this requirement active after careful review.

        ## Table and image removals

        | Topic | Guidance |
        | --- | --- |
        | Review | Stable beginning. Stable ending. |

        This paragraph follows the removed image.

        ## Continued content

        \(tail)
        """
        let original = current.replacingOccurrences(of: "These closing words", with: "Retired advice. Obsolete policy! Earlier guidance? These closing words")
            .replacingOccurrences(of: "Kept final paragraph.", with: "Retired paragraph one. Its second sentence also disappears.\n\nRetired paragraph two.\n\nKept final paragraph.")
            .replacingOccurrences(of: "Tuesday", with: "Monday")
            .replacingOccurrences(of: "Keep this requirement", with: "Keep this \(fragment) requirement")
            .replacingOccurrences(of: "Stable ending.", with: "Retired cell advice. Stable ending.")
            .replacingOccurrences(of: "This paragraph follows", with: "![Old photograph](missing.png)\n\nThis paragraph follows")
        let result = revision(original, current)
        let labels = result.decorations.deletions.map(\.label)
        for label in ["^ removed 3 sentences", "^ removed 2 paragraphs", "^ Monday", "^ removed 13 words", "^ removed 1 sentence", "^ removed image"] {
            XCTAssertTrue(labels.contains(label), label)
        }
        let exporter = PDFExporter()
        let data = try exporter.pdfData(from: result.text, decorations: result.decorations)
        let marked = try XCTUnwrap(PDFDocument(data: data))
        let plainData = try exporter.pdfData(from: result.text)
        let plain = try XCTUnwrap(PDFDocument(data: plainData))
        XCTAssertGreaterThan(marked.pageCount, 1)
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        for index in 1...45 {
            let phrase = "Continued paragraph \(index) keeps"
            let a = try XCTUnwrap(plain.findString(phrase, withOptions: []).first)
            let b = try XCTUnwrap(marked.findString(phrase, withOptions: []).first)
            let aPage = try XCTUnwrap(a.pages.first), bPage = try XCTUnwrap(b.pages.first)
            XCTAssertEqual(plain.index(for: aPage), marked.index(for: bPage))
            XCTAssertEqual(a.bounds(for: aPage), b.bounds(for: bPage))
        }
        let notes = try exporter.revisionNoteLayout(from: result.text, decorations: result.decorations)
        XCTAssertEqual(notes.count, labels.count)
        XCTAssertEqual(notes.filter(\.strikeWording).count, 1)
        for note in notes where note.cellBounds != nil {
            XCTAssertFalse(note.isBoundaryOnly)
            XCTAssertEqual(note.label, "^ removed 1 sentence")
            XCTAssertTrue(try XCTUnwrap(note.cellBounds).contains(note.frame))
        }
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("mixed-removal-summaries.pdf"))
            try plainData.write(to: output.appendingPathComponent("mixed-removal-summaries-plain.pdf"))
            try WordExporter().wordData(from: result.text, decorations: result.decorations).write(to: output.appendingPathComponent("mixed-removal-summaries.docx"))
        }
    }
}

import AppKit
import Foundation
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class WordRevisionRegressionTests: XCTestCase {
    func testTablesPreserveFollowingHeadingsAndProseWithRevisionFormatting() throws {
        let original = """
        # Report

        | Topic | Status |
        | --- | --- |
        | Alpha | Pending |

        ## Next Section

        Follow the [guide](https://example.com/guide).

        | Owner |
        | --- |
        | Team |

        Plain text after the final table.
        """
        let current = original.replacingOccurrences(of: "Pending", with: "Ready")
            .replacingOccurrences(of: "Next Section", with: "Updated Section")
        let document = MarkdownDocument(title: "Report", markdown: current)
        let rendered = MarkdownRenderer().render(document: document,
            original: MarkdownDocument(title: "Original", markdown: original))
        let data = try WordExporter().wordData(from: rendered.text, decorations: rendered.decorations)
        let xml = try documentXML(from: data)
        XCTAssertFalse(xml.contains("MDPRINTER"))
        let parsed = try parseXML(xml)
        let body = try parsed.nodes(forXPath: "//w:body//w:t[not(ancestor::w:txbxContent)]")
            .compactMap(\.stringValue).joined()
        XCTAssertEqual(body, "ReportTopicStatusAlphaReadyUpdated SectionFollow the guide.OwnerTeamPlain text after the final table.")
        XCTAssertEqual(try parsed.nodes(forXPath: "//w:body/w:tbl").count, 2)
        XCTAssertEqual(try parsed.nodes(forXPath: "//w:bookmarkStart").count, 2)
        XCTAssertTrue(try parsed.nodes(forXPath: "//w:r[w:rPr/w:highlight]/w:t").compactMap(\.stringValue).joined().contains("Ready"))
        XCTAssertFalse(try parsed.nodes(forXPath: "//w:pict").isEmpty)
        XCTAssertFalse(try parsed.nodes(forXPath: "//*[local-name()='wrap' and @type='none']").isEmpty)

        let plain = try WordExporter().wordData(from: MarkdownRenderer().render(document: document))
        let plainXML = try parseXML(documentXML(from: plain))
        XCTAssertEqual(try plainXML.nodes(forXPath: "//w:body//w:t").compactMap(\.stringValue).joined(), body)
        XCTAssertEqual(try bodyParagraphs(in: parsed), try bodyParagraphs(in: plainXML))
    }

    func testHighlightedMultilineCodePreservesBodyParagraphsAndWhitespace() throws {
        let original = MarkdownDocument(title: "Code", markdown: "```\na = 1\nb = 2\n```")
        let current = MarkdownDocument(title: "Code", markdown: "```\n\tx = 3\ny = 4\n```")
        let renderer = MarkdownRenderer()
        let rendered = renderer.render(document: current, original: original)
        let marked = try parseXML(documentXML(from: WordExporter().wordData(
            from: rendered.text, decorations: rendered.decorations)))
        let plain = try parseXML(documentXML(from: WordExporter().wordData(
            from: renderer.render(document: current))))
        if let outputPath = ProcessInfo.processInfo.environment["MDPRINTER_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try Data(marked.xmlString.utf8).write(to: output.appendingPathComponent("review-code-marked.xml"))
            try Data(plain.xmlString.utf8).write(to: output.appendingPathComponent("review-code-plain.xml"))
        }
        var highlightsOnly = rendered.decorations
        highlightsOnly.deletions = []
        let withoutNotes = try parseXML(documentXML(from: WordExporter().wordData(
            from: rendered.text, decorations: highlightsOnly)))
        XCTAssertEqual(try bodyParagraphs(in: withoutNotes), try bodyParagraphs(in: plain), "Highlight-only body")
        XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
        XCTAssertEqual(try marked.nodes(forXPath: "//w:body//w:tab").count,
                       try plain.nodes(forXPath: "//w:body//w:tab").count)
        XCTAssertEqual(try marked.nodes(forXPath: "//w:body//w:br").count,
                       try plain.nodes(forXPath: "//w:body//w:br").count)
    }

    func testDeletionCalloutSurvivesAnEmptyCurrentCodeBlock() throws {
        let renderer = MarkdownRenderer()
        for contents in ["", "\t"] {
            let current = MarkdownDocument(title: "Code", markdown: "```\n\(contents)\n```")
            let original = MarkdownDocument(title: "Original", markdown: "```\nremoved code\n```")
            let rendered = renderer.render(document: current, original: original)
            let marked = try parseXML(documentXML(from: WordExporter().wordData(from: rendered.text, decorations: rendered.decorations)))
            let plain = try parseXML(documentXML(from: WordExporter().wordData(from: renderer.render(document: current))))
            XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
            XCTAssertFalse(try marked.nodes(forXPath: "//w:txbxContent//w:t").isEmpty)
        }
    }

    func testDecorationMetadataExportsHighlightsWithoutRendererPrivateAttributes() throws {
        let text = NSAttributedString(string: "one\n\ttwo\nthree", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
        var decorations = RevisionDecorations()
        decorations.highlights = [NSRange(location: 0, length: text.length)]
        let marked = try parseXML(documentXML(from: WordExporter().wordData(from: text, decorations: decorations)))
        let plain = try parseXML(documentXML(from: WordExporter().wordData(from: text)))
        XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
        let highlighted = try marked.nodes(forXPath: "//w:r[w:rPr/w:highlight]/w:t").compactMap(\.stringValue).joined()
        XCTAssertEqual(highlighted, "onetwothree")
    }

    func testChangedImagePlaceholdersHaveBordersInOrdinaryLinkedAndTableRuns() throws {
        let currentMarkdown = """
        ![Ordinary](new-missing.png)

        [![Linked](new-linked-missing.png)](https://example.com)

        | Image |
        | --- |
        | ![Table](new-table-missing.png) |
        """
        let originalMarkdown = currentMarkdown.replacingOccurrences(of: "new-", with: "old-")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("MissingImages-\(UUID().uuidString).md")
        let renderer = MarkdownRenderer()
        let current = MarkdownDocument(sourceURL: source, title: "Images", markdown: currentMarkdown)
        let rendered = renderer.render(document: current,
            original: MarkdownDocument(sourceURL: source, title: "Original", markdown: originalMarkdown))
        let marked = try parseXML(documentXML(from: WordExporter().wordData(from: rendered.text, decorations: rendered.decorations)))
        let plain = try parseXML(documentXML(from: WordExporter().wordData(from: renderer.render(document: current))))
        XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
        XCTAssertEqual(try marked.nodes(forXPath: "//w:rPr/w:bdr[@w:color='EBBA00' and @w:sz='16' and @w:space='0']").count, 3)
        XCTAssertEqual(try marked.nodes(forXPath: "//w:hyperlink//w:rPr/w:bdr").count, 1)
        XCTAssertEqual(try marked.nodes(forXPath: "//w:tbl//w:rPr/w:bdr").count, 1)
    }

    func testTableDeletionLabelsTruncateInsideTheirCurrentWordCell() throws {
        let markdown = """
        | Wider heading for the first column | Narrow | Other |
        | --- | --- | --- |
        | Readable anchor | \(String(repeating: "i", count: 100)) | Unchanged |
        """
        let renderer = MarkdownRenderer()
        let text = renderer.render(markdown: markdown)
        let source = text.string as NSString
        let first = source.range(of: "Readable anchor").location
        let second = source.range(of: String(repeating: "i", count: 100)).location
        let font = try XCTUnwrap(text.attribute(.font, at: second, effectiveRange: nil) as? NSFont)
        let advance = ("i" as NSString).size(withAttributes: [.font: font]).width
        let contentWidth: CGFloat = 150 - 10.8 - 1
        let nearRight = max(0, Int((contentWidth - 1) / advance) - 1)
        var decorations = RevisionDecorations()
        let removed = String(repeating: "retired wording and details ", count: 20)
        decorations.deletions = [RevisionDeletion(location: first, text: removed),
                                RevisionDeletion(location: second + nearRight, text: removed)]
        let data = try WordExporter().wordData(from: text, decorations: decorations)
        let marked = try parseXML(documentXML(from: data))
        let plain = try parseXML(documentXML(from: WordExporter().wordData(from: text)))
        XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
        let boxes = try marked.nodes(forXPath: "//w:tbl//*[local-name()='rect']")
        XCTAssertEqual(boxes.count, 3, "Two labels and a caret for the displaced label")
        let labelFont = FontBook(configuration: RendererConfiguration()).regular(size: 7)
        for box in boxes {
            let element = try XCTUnwrap(box as? XMLElement)
            let style = try XCTUnwrap(element.attribute(forName: "style")?.stringValue)
            let values = Dictionary(uniqueKeysWithValues: style.split(separator: ";").compactMap { pair -> (String, Double)? in
                let fields = pair.split(separator: ":", maxSplits: 1)
                guard fields.count == 2, let number = Double(fields[1].replacingOccurrences(of: "pt", with: "")) else { return nil }
                return (String(fields[0]), number)
            })
            let x = try XCTUnwrap(values["margin-left"])
            let width = try XCTUnwrap(values["width"])
            XCTAssertLessThanOrEqual(width, contentWidth)
            // Native Word at 250% left about 132pt from this first-cell
            // anchor to its border; a 138pt label visibly crossed that edge.
            XCTAssertLessThanOrEqual(width, 132)
            let label = box.stringValue ?? ""
            if label != "^" {
                XCTAssertTrue(label.hasSuffix("…"))
                XCTAssertFalse(label.contains("deleted"))
                XCTAssertTrue(label.contains("retire"), "The label must retain removed wording")
                XCTAssertLessThanOrEqual((label as NSString).size(withAttributes: [.font: labelFont]).width, width + 0.01)
            }
            if x < 0 {
                let anchorX = CGFloat(nearRight) * advance
                XCTAssertGreaterThanOrEqual(anchorX + x, -0.01)
                XCTAssertLessThanOrEqual(anchorX + x + width, contentWidth + 0.01)
            }
        }
        XCTAssertEqual(try marked.nodes(forXPath: "//w:tbl//w:txbxContent//w:r[not(w:rPr/w:sz[@w:val='14'])]").count, 0)
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("table-contained-callouts.docx"))
        }
    }

    func testTextDeletionWordingIsStruckWhileCaretAndImageCalloutsAreUnstruck() throws {
        let text = NSAttributedString(string: "Alpha\nBeta\nGamma", attributes: [.font: FontBook(configuration: RendererConfiguration()).regular(size: 10)])
        var decorations = RevisionDecorations()
        decorations.deletions = [RevisionDeletion(location: 0, text: "prior wording"),
                                RevisionDeletion(location: 6, text: "removed image"),
                                RevisionDeletion(location: 11, text: "", isImage: true)]
        let data = try WordExporter().wordData(from: text, decorations: decorations)
        let marked = try parseXML(documentXML(from: data))
        let plain = try parseXML(documentXML(from: WordExporter().wordData(from: text)))
        XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
        let struck = try marked.nodes(forXPath: "//w:txbxContent//w:r[w:rPr/w:strike]/w:t").compactMap(\.stringValue)
        XCTAssertEqual(struck, ["prior wording", "removed image"])
        let unstruck = try marked.nodes(forXPath: "//w:txbxContent//w:r[not(w:rPr/w:strike)]/w:t").compactMap(\.stringValue)
        XCTAssertEqual(unstruck, ["^ ", "^ ", "^ removed image"])
        XCTAssertEqual(try marked.nodes(forXPath: "//w:txbxContent//w:r[not(w:rPr/w:color[@w:val='C70F14']) or not(w:rPr/w:sz[@w:val='14'])]").count, 0)
        XCTAssertEqual(try marked.nodes(forXPath: "//*[local-name()='rect']").count, 3)
        XCTAssertEqual(try marked.nodes(forXPath: "//*[local-name()='wrap' and @type='none']").count, 3)
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("struck-deletion-callouts.docx"))
        }
    }

    func testRemovalSummaryWordRunsAreRedAndUnstruckInBodyAndNarrowCells() throws {
        for markdown in ["Current wording.\n\nKept paragraph.", "| First | Second |\n| --- | --- |\n| Current wording. | Kept cell. |"] {
            let text = MarkdownRenderer().render(markdown: markdown)
            let location = (text.string as NSString).range(of: "Current wording.").location
            var decorations = RevisionDecorations()
            decorations.deletions = [RevisionDeletion(location: location, text: "obsolete sentences", summary: .sentences(3)),
                                    RevisionDeletion(location: location, text: "obsolete paragraphs", summary: .paragraphs(2)),
                                    RevisionDeletion(location: location, text: "obsolete fragment", summary: .words(18)),
                                    RevisionDeletion(location: location, text: "old")]
            let data = try WordExporter().wordData(from: text, decorations: decorations)
            let marked = try parseXML(documentXML(from: data))
            let plain = try parseXML(documentXML(from: WordExporter().wordData(from: text)))
            XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
            let struck = try marked.nodes(forXPath: "//w:txbxContent//w:r[w:rPr/w:strike]/w:t").compactMap(\.stringValue)
            XCTAssertEqual(struck, ["old"])
            let unstruck = try marked.nodes(forXPath: "//w:txbxContent//w:r[not(w:rPr/w:strike)]/w:t").compactMap(\.stringValue).joined()
            for label in ["removed 3 sentences", "removed 2 paragraphs", "removed 18 words"] { XCTAssertTrue(unstruck.contains(label)) }
            XCTAssertEqual(try marked.nodes(forXPath: "//w:txbxContent//w:r[not(w:rPr/w:color[@w:val='C70F14'])]").count, 0)
        }
    }

    func testWordTableTooNarrowForRemovedWordingTruncatesInsteadOfRejectingExport() throws {
        for columnCount in [12, 14, 20] {
            let columns = (1...columnCount).map { "Column \($0)" }
            let markdown = "| " + columns.joined(separator: " | ") + " |\n| "
                + Array(repeating: "---", count: columns.count).joined(separator: " | ") + " |\n| "
                + Array(repeating: "Current", count: columns.count).joined(separator: " | ") + " |"
            let text = MarkdownRenderer().render(markdown: markdown)
            var decorations = RevisionDecorations()
            decorations.deletions = [RevisionDeletion(location: (text.string as NSString).range(of: "Current").location + 5,
                                                       text: "old wording")]
            let marked = try parseXML(documentXML(from: WordExporter().wordData(from: text, decorations: decorations)))
            let plain = try parseXML(documentXML(from: WordExporter().wordData(from: text)))
            XCTAssertEqual(try bodyParagraphs(in: marked), try bodyParagraphs(in: plain))
            let labels = try marked.nodes(forXPath: "//w:txbxContent").compactMap(\.stringValue)
            XCTAssertFalse(labels.isEmpty)
            XCTAssertTrue(labels.contains { $0.hasSuffix("…") })
        }
    }

    /// Opt-in QA for local documents; no source content or generated artifacts enters Git.
    func testLocalWordRevisionBodyFlow() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let currentPath = environment["MDPRINTER_REVIEW_CURRENT"],
              let originalPath = environment["MDPRINTER_REVIEW_ORIGINAL"],
              let outputPath = environment["MDPRINTER_REVISION_FIXTURES"] else { return }
        let current = try MarkdownDocument.load(from: URL(fileURLWithPath: currentPath))
        let original = try MarkdownDocument.load(from: URL(fileURLWithPath: originalPath))
        let renderer = MarkdownRenderer()
        let rendered = renderer.render(document: current, original: original)
        let marked = try WordExporter().wordData(from: rendered.text, decorations: rendered.decorations)
        let plain = try WordExporter().wordData(from: renderer.render(document: current))
        let output = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try marked.write(to: output.appendingPathComponent("review-word.docx"))
        try plain.write(to: output.appendingPathComponent("review-word-plain.docx"))
        let markedXML = try parseXML(documentXML(from: marked))
        let plainXML = try parseXML(documentXML(from: plain))
        let markedParagraphs = try bodyParagraphs(in: markedXML)
        let plainParagraphs = try bodyParagraphs(in: plainXML)
        try JSONSerialization.data(withJSONObject: ["marked": markedParagraphs, "plain": plainParagraphs])
            .write(to: output.appendingPathComponent("review-word-paragraphs.json"))
        XCTAssertEqual(markedParagraphs.count, plainParagraphs.count)
        XCTAssertEqual(zip(markedParagraphs, plainParagraphs).filter { $0 != $1 }.count, 0, "Body paragraphs differ")
        XCTAssertEqual(try markedXML.nodes(forXPath: "//w:body//w:tbl").count,
                       try plainXML.nodes(forXPath: "//w:body//w:tbl").count)
    }

    private func bodyParagraphs(in xml: XMLDocument) throws -> [String] {
        // SAX preserves whitespace-only w:t contents that XMLNode.stringValue
        // omits, while excluding all floating textbox paragraphs from the body.
        let collector = WordBodyParagraphCollector()
        let parser = XMLParser(data: Data(xml.xmlString.utf8))
        parser.delegate = collector
        XCTAssertTrue(parser.parse())
        return collector.paragraphs
    }

    private func parseXML(_ source: String) throws -> XMLDocument {
        // OOXML often stores meaningful spaces in their own text runs.
        try XMLDocument(xmlString: source, options: .nodePreserveWhitespace)
    }

    private func documentXML(from data: Data) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WordRevisionRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("revision.docx")
        try data.write(to: archive)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, "word/document.xml"]
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(String(data: output, encoding: .utf8))
    }
}

private final class WordBodyParagraphCollector: NSObject, XMLParserDelegate {
    var paragraphs: [String] = []
    private var inBody = false
    private var inText = false
    private var textboxDepth = 0
    private var paragraphIndex: Int?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "w:body" { inBody = true }
        guard inBody else { return }
        if elementName == "w:txbxContent" { textboxDepth += 1 }
        guard textboxDepth == 0 else { return }
        if elementName == "w:p" {
            paragraphIndex = paragraphs.count
            paragraphs.append("")
        }
        if elementName == "w:t" { inText = true }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:txbxContent" { textboxDepth -= 1; return }
        guard textboxDepth == 0 else { return }
        if elementName == "w:t" { inText = false }
        if elementName == "w:p" { paragraphIndex = nil }
        if elementName == "w:body" { inBody = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inBody, inText, textboxDepth == 0, let paragraphIndex else { return }
        paragraphs[paragraphIndex] += string
    }
}

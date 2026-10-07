import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionLeaderRoutingTests: XCTestCase {
    private let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let content = CGRect(x: 54, y: 54, width: 504, height: 684)
    private var font: NSFont { NSFont(name: "Avenir Next", size: 7) ?? NSFont.systemFont(ofSize: 7) }

    func testShiftedLeftWordingConnectsAtItsRightEdgeBelowTheCaret() throws {
        let note = RevisionPDFNote(page: 0, anchor: CGPoint(x: 420, y: 120),
            frame: CGRect(x: 300, y: 119, width: 100, height: 8), label: "^ earlier wording")
        let body = CGRect(x: 54, y: 100, width: 504, height: 19)
        let path = try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
            occupied: [body], notes: [note], previous: [])
        let first = try XCTUnwrap(path.first), last = try XCTUnwrap(path.last)
        XCTAssertEqual(first.x, note.anchor.x)
        XCTAssertGreaterThan(first.y, RevisionAnnotationLayout.caretFrame(at: note.anchor, font: font).maxY)
        XCTAssertGreaterThanOrEqual(last.x, note.wordingFrame(font: font).maxX)
        XCTAssertLessThan(last.x, note.wordingFrame(font: font).maxX + 2)
        assertPath(path, avoids: [body, note.wordingFrame(font: font)])
    }

    func testLabelPlacementReservesOtherDeletionCarets() throws {
        let anchor = CGPoint(x: 550, y: 120)
        let markers = [CGPoint(x: 330, y: 120), CGPoint(x: 460, y: 120), anchor]
            .map { RevisionAnnotationLayout.caretFrame(at: $0, font: font) }
        let placed = RevisionAnnotationLayout.place(label: "^ an earlier statement with several explanatory conditions",
            anchor: anchor, line: CGRect(x: 54, y: 100, width: 504, height: 20), content: content,
            page: page, occupied: [CGRect(x: 54, y: 100, width: 504, height: 20)], notes: [],
            font: font, markers: markers)
        let note = RevisionPDFNote(page: 0, anchor: anchor, frame: placed.0, label: placed.1)
        XCTAssertTrue(content.contains(note.frame))
        XCTAssertTrue(note.label.contains("earlier"))
        for marker in markers {
            XCTAssertFalse(note.wordingFrame(font: font).intersects(marker.insetBy(dx: -1, dy: -1)))
        }
    }

    func testBlockedNearestEdgeFallsBackToAClearEdgeWithoutCrossingWording() throws {
        let note = RevisionPDFNote(page: 0, anchor: CGPoint(x: 420, y: 120),
            frame: CGRect(x: 300, y: 119, width: 100, height: 8), label: "^ earlier wording")
        let wording = note.wordingFrame(font: font)
        let blockedEdge = CGRect(x: wording.maxX + 0.2, y: wording.midY - 1, width: 1, height: 2)
        let body = CGRect(x: 54, y: 100, width: 504, height: 19)
        let path = try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
            occupied: [body, blockedEdge], notes: [note], previous: [])
        let last = try XCTUnwrap(path.last)
        XCTAssertTrue(last.x < wording.minX || last.y < wording.minY || last.y > wording.maxY)
        XCTAssertFalse(blockedEdge.contains(last))
        assertPath(path, avoids: [body, blockedEdge, wording])
    }

    func testTableMarginConnectorRoutesAroundNeighboringCellText() throws {
        let note = RevisionPDFNote(page: 0, anchor: CGPoint(x: 400, y: 120),
            frame: CGRect(x: 564, y: 140, width: 42, height: 24), label: "prior\nreview\ncriteria",
            cellBounds: CGRect(x: 350, y: 100, width: 145, height: 50), isMargin: true)
        let ownBody = CGRect(x: 350, y: 100, width: 145, height: 19)
        let neighbor = CGRect(x: 495, y: 100, width: 63, height: 50)
        let path = try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
            occupied: [ownBody, neighbor], notes: [note], previous: [])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(path.map(\.y).max()), neighbor.maxY)
        XCTAssertLessThan(try XCTUnwrap(path.last).x, note.frame.minX)
        assertPath(path, avoids: [ownBody, neighbor, note.frame])
    }

    func testConnectorRejectsBlockedRoutesInsteadOfCrossingBodyText() {
        let note = RevisionPDFNote(page: 0, anchor: CGPoint(x: 420, y: 120),
            frame: CGRect(x: 300, y: 150, width: 100, height: 8), label: "^ earlier wording")
        XCTAssertThrowsError(try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
            occupied: [page], notes: [note], previous: [])) { error in
            guard case RevisionAnnotationError.noSpace = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testConnectorCannotCrossAnExistingLeader() {
        let note = RevisionPDFNote(page: 0, anchor: CGPoint(x: 420, y: 120),
            frame: CGRect(x: 300, y: 160, width: 100, height: 8), label: "^ earlier wording")
        let barrier = [CGPoint(x: 1, y: 135), CGPoint(x: 611, y: 135)]
        XCTAssertThrowsError(try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
            occupied: [], notes: [note], previous: [barrier]))
    }

    func testUnshiftedCalloutNeedsNoConnectorAndImageLabelStaysUnchanged() throws {
        let anchor = CGPoint(x: 100, y: 120)
        for isImage in [false, true] {
            let note = RevisionPDFNote(page: 0, anchor: anchor, frame: CGRect(x: 100, y: 119, width: 70, height: 8),
                label: isImage ? "^ removed image" : "^ earlier wording", isImage: isImage)
            XCTAssertTrue(try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
                occupied: [], notes: [note], previous: []).isEmpty)
        }
        let text = MarkdownRenderer().render(markdown: "CURRENT IMAGE LOCATION.")
        var decorations = RevisionDecorations()
        decorations.deletions = [RevisionDeletion(location: 0, text: "", isImage: true)]
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text, decorations: decorations)))
        XCTAssertEqual(document.findString("^ removed image", withOptions: []).count, 1)
    }

    func testShiftedImageLabelCoveringItsBoundaryDoesNotRejectItsOwnWording() throws {
        let note = RevisionPDFNote(page: 0, anchor: CGPoint(x: 550, y: 120),
            frame: CGRect(x: 510, y: 119, width: 48, height: 8), label: "^ removed image", isImage: true)
        XCTAssertTrue(try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
            occupied: [], notes: [note], previous: []).isEmpty)
        XCTAssertEqual(note.label, "^ removed image")
    }

    func testDisplacedImageMarginConnectorRemainsClearOfBodyAndLabel() throws {
        let note = RevisionPDFNote(page: 0, anchor: CGPoint(x: 500, y: 120),
            frame: CGRect(x: 564, y: 140, width: 42, height: 8), label: "removed image", isMargin: true, isImage: true)
        let body = CGRect(x: 54, y: 100, width: 504, height: 19)
        let path = try RevisionAnnotationLayout.leader(for: note, font: font, page: page, content: content,
            occupied: [body], notes: [note], previous: [])
        XCTAssertFalse(path.isEmpty)
        assertPath(path, avoids: [body, note.frame])
    }

    func testThreeSameLineRemovalsKeepDistinctCaretsAndUnchangedBodyPixels() throws {
        let markdown = "# Revision association\n\nALPHA TEAMS SHARE BETA REVIEW CRITERIA AND GAMMA RELEASE RESULTS.\n\nUNCHANGED BODY FOLLOWS."
        let text = MarkdownRenderer().render(markdown: markdown)
        let string = text.string as NSString
        var decorations = RevisionDecorations()
        decorations.deletions = zip(["ALPHA", "BETA", "GAMMA"],
            ["prior team", "an extended review statement with several earlier requirements", "older release"])
            .map { RevisionDeletion(location: string.range(of: $0.0).location, text: $0.1) }
        let exporter = PDFExporter()
        let notes = try exporter.revisionNoteLayout(from: text, decorations: decorations)
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(Set(notes.map { $0.anchor.x }).count, 3)
        for note in notes {
            let foreign = notes.filter { $0.anchor != note.anchor }
            for other in foreign {
                XCTAssertFalse(note.wordingFrame(font: font).intersects(
                    RevisionAnnotationLayout.caretFrame(at: other.anchor, font: font)))
            }
            assertPath(note.leader, avoids: foreign.map { $0.wordingFrame(font: font) }
                + foreign.map { RevisionAnnotationLayout.caretFrame(at: $0.anchor, font: font) })
        }
        let plainData = try exporter.pdfData(from: text)
        let markedData = try exporter.pdfData(from: text, decorations: decorations)
        let plain = try XCTUnwrap(PDFDocument(data: plainData)), marked = try XCTUnwrap(PDFDocument(data: markedData))
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        XCTAssertEqual(marked.findString("^", withOptions: []).count, 3)
        try assertBodyPixelsUnchanged(plain: plain, marked: marked, notes: notes)
        try writeFixtures(name: "same-line-prose", plainData: plainData, markedData: markedData, plain: plain, marked: marked)
    }

    func testCrowdedTableNotesShareOneCaretWithoutChangingBodyFlow() throws {
        let text = MarkdownRenderer().render(markdown: "| LEFT | MIDDLE | RIGHT |\n| --- | --- | --- |\n| STABLE | CURRENT REVIEW | CURRENT RESULT |")
        let location = NSMaxRange((text.string as NSString).range(of: "CURRENT RESULT"))
        var decorations = RevisionDecorations()
        decorations.deletions = ["earlier", "the prior review criteria and an extended explanation",
            "another original condition supporting the earlier result"]
            .map { RevisionDeletion(location: location, text: $0) }
        let exporter = PDFExporter()
        let notes = try exporter.revisionNoteLayout(from: text, decorations: decorations)
        XCTAssertEqual(notes.count, decorations.deletions.count)
        XCTAssertEqual(Set(notes.map { $0.anchor.x }).count, 1)
        let plainData = try exporter.pdfData(from: text), markedData = try exporter.pdfData(from: text, decorations: decorations)
        let plain = try XCTUnwrap(PDFDocument(data: plainData)), marked = try XCTUnwrap(PDFDocument(data: markedData))
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        XCTAssertEqual(marked.findString("^", withOptions: []).count, 1)
        for phrase in ["STABLE", "CURRENT REVIEW", "CURRENT RESULT"] {
            let a = try XCTUnwrap(plain.findString(phrase, withOptions: []).first)
            let b = try XCTUnwrap(marked.findString(phrase, withOptions: []).first)
            XCTAssertEqual(plain.index(for: try XCTUnwrap(a.pages.first)), marked.index(for: try XCTUnwrap(b.pages.first)))
        }
        try assertBodyPixelsUnchanged(plain: plain, marked: marked, notes: notes)
        try writeFixtures(name: "crowded-table", plainData: plainData, markedData: markedData, plain: plain, marked: marked)
    }

    func testCrowdedListRetriesAnUnconnectableLabelGapWithoutChangingBodyFlow() throws {
        let bodyFont = NSFont(name: "Avenir Next", size: 10) ?? NSFont.systemFont(ofSize: 10)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 14
        paragraph.maximumLineHeight = 14
        paragraph.headIndent = 13
        paragraph.firstLineHeadIndent = 13
        // The accented capital makes the second row's ink taller while its
        // matching prefix keeps the later result caret in the same column.
        let text = NSAttributedString(string: "EVENT teams a reliable goal\nÉVENT teams a reliable result and status.\nUNCHANGED DETAILS FOLLOW.",
            attributes: [.font: bodyFont, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
        let string = text.string as NSString
        var decorations = RevisionDecorations()
        decorations.deletions = zip(["EVENT", "teams", "a reliable", "goal", "result", "status"],
            ["previous planning guidance with an extended delivery explanation", "one", "a", "was", "also", "no"])
            .map { RevisionDeletion(location: string.range(of: $0.0).location, text: $0.1) }
        let exporter = PDFExporter()
        let notes = try exporter.revisionNoteLayout(from: text, decorations: decorations)
        XCTAssertEqual(notes.count, decorations.deletions.count)
        XCTAssertEqual(Set(notes.map { "\($0.anchor.x),\($0.anchor.y)" }).count, notes.count)
        XCTAssertEqual(notes[3].anchor.x, notes[4].anchor.x, accuracy: 0.01)
        XCTAssertGreaterThan(notes[4].anchor.y, notes[3].anchor.y)

        // Use actual glyph ink, since TextKit's complete line-fragment bounds
        // include the interline gaps that are available to an overlay.
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(size: content.size)
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var bodyInk: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
            for glyph in glyphs.location..<NSMaxRange(glyphs) {
                let bounds = bodyFont.boundingRect(forGlyph: manager.glyph(at: glyph))
                guard !bounds.isEmpty else { continue }
                let position = manager.location(forGlyphAt: glyph)
                let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                bodyInk.append(CGRect(x: fragment.minX + position.x + bounds.minX,
                    y: fragment.minY + position.y - bounds.maxY, width: bounds.width, height: bounds.height)
                    .offsetBy(dx: self.content.minX, dy: self.content.minY))
            }
        }
        for note in notes {
            let foreign = notes.filter { $0.anchor != note.anchor }
            let obstacles = foreign.map { $0.wordingFrame(font: font) }
                + foreign.map { RevisionAnnotationLayout.caretFrame(at: $0.anchor, font: font) }
            assertPath(note.leader, avoids: bodyInk + obstacles)
            for marker in foreign.map({ RevisionAnnotationLayout.caretFrame(at: $0.anchor, font: font) }) {
                XCTAssertFalse(note.wordingFrame(font: font).intersects(marker))
            }
        }
        let plainData = try exporter.pdfData(from: text), markedData = try exporter.pdfData(from: text, decorations: decorations)
        let plain = try XCTUnwrap(PDFDocument(data: plainData)), marked = try XCTUnwrap(PDFDocument(data: markedData))
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        XCTAssertEqual(marked.findString("^", withOptions: []).count, notes.count)
        try assertBodyPixelsUnchanged(plain: plain, marked: marked, notes: notes)
        try writeFixtures(name: "crowded-list", plainData: plainData, markedData: markedData, plain: plain, marked: marked)
    }

    private func assertPath(_ path: [CGPoint], avoids obstacles: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(path, path.dropFirst()) {
            XCTAssertTrue(a.x == b.x || a.y == b.y, "Connector must use orthogonal segments", file: file, line: line)
            let segment = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                width: max(0.01, abs(a.x - b.x)), height: max(0.01, abs(a.y - b.y)))
            for obstacle in obstacles {
                XCTAssertFalse(segment.intersects(obstacle), "Connector \(a) → \(b) crossed \(obstacle)", file: file, line: line)
            }
        }
    }

    private func pixels(_ page: PDFPage) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(page.thumbnail(of: page.bounds(for: .mediaBox).size,
            for: .mediaBox).tiffRepresentation)))
    }

    private func assertBodyPixelsUnchanged(plain: PDFDocument, marked: PDFDocument, notes: [RevisionPDFNote]) throws {
        for index in 0..<plain.pageCount {
            let plainPage = try XCTUnwrap(plain.page(at: index))
            let before = try pixels(plainPage), after = try pixels(XCTUnwrap(marked.page(at: index)))
            XCTAssertEqual(before.pixelsWide, after.pixelsWide)
            XCTAssertEqual(before.pixelsHigh, after.pixelsHigh)
            let scaleX = CGFloat(before.pixelsWide) / plainPage.bounds(for: .mediaBox).width
            let scaleY = CGFloat(before.pixelsHigh) / plainPage.bounds(for: .mediaBox).height
            let overlapBands = notes.filter { $0.page == index }.flatMap { note -> [CGRect] in
                let wording = note.wordingFrame(font: font)
                let marker = RevisionAnnotationLayout.caretFrame(at: note.anchor, font: font)
                return [wording, marker].map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: 1) }
            }
            var changed = 0, bodyInk = 0
            for y in 0..<before.pixelsHigh {
                for x in 0..<before.pixelsWide {
                    // Test the dark body glyph ink, rather than gray cell
                    // rules that a legitimate margin connector may cross.
                    guard let color = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3 else { continue }
                    bodyInk += 1
                    guard let markedColor = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        changed += 1
                        continue
                    }
                    if color == markedColor { continue }
                    // PDF font subsetting can change gray edge antialiasing
                    // slightly even on an entirely untouched body paragraph.
                    func grayscale(_ value: NSColor) -> Bool {
                        max(value.redComponent, value.greenComponent, value.blueComponent)
                            - min(value.redComponent, value.greenComponent, value.blueComponent) < 0.001
                    }
                    if grayscale(color), grayscale(markedColor), abs(color.redComponent - markedColor.redComponent) <= 0.06 { continue }
                    let point = CGPoint(x: (CGFloat(x) + 0.5) / scaleX, y: (CGFloat(y) + 0.5) / scaleY)
                    // Snug callouts may overlap the adjacent line by one
                    // point, only at their top edge or the caret's top edge.
                    let redTint = markedColor.redComponent > markedColor.greenComponent
                        && markedColor.redComponent > markedColor.blueComponent
                    if redTint, overlapBands.contains(where: { $0.contains(point) }) { continue }
                    changed += 1
                }
            }
            XCTAssertGreaterThan(bodyInk, 100)
            XCTAssertEqual(changed, 0, "Revision annotations must preserve the current body's ink pixels")
        }
    }

    private func writeFixtures(name: String, plainData: Data, markedData: Data, plain: PDFDocument, marked: PDFDocument) throws {
        guard let path = ProcessInfo.processInfo.environment["MDPRINTER_LEADER_REVISION_FIXTURES"] else { return }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (suffix, data, document) in [("plain", plainData, plain), ("marked", markedData, marked)] {
            try data.write(to: output.appendingPathComponent(name + "-" + suffix + ".pdf"))
            for index in 0..<document.pageCount {
                try XCTUnwrap(pixels(XCTUnwrap(document.page(at: index))).representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(name + "-" + suffix + "-\(index + 1).png"))
            }
        }
    }
}

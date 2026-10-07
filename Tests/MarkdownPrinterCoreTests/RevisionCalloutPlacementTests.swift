import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionCalloutPlacementTests: XCTestCase {
    func testNearbyBodyGapUsesFreeSpaceOutsideTheAnchorsColumn() throws {
        let font = NSFont(name: "Avenir Next", size: 7) ?? NSFont.systemFont(ofSize: 7)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let content = CGRect(x: 54, y: 54, width: 504, height: 684)
        let line = CGRect(x: 54, y: 100, width: 504, height: 20)
        let occupied = [line, CGRect(x: 54, y: 123, width: 504, height: 13),
                        CGRect(x: 54, y: 142, width: 504, height: 14),
                        CGRect(x: 54, y: 160, width: 504, height: 578)]
        let existing = CGRect(x: 440, y: 135, width: 110, height: 8)
        let placed = RevisionAnnotationLayout.place(label: "^ earlier wording with a substantial explanation",
            anchor: CGPoint(x: 540, y: 120), line: line, content: content, page: page,
            occupied: occupied, notes: [existing], font: font)
        XCTAssertTrue(content.contains(placed.0))
        XCTAssertLessThan(placed.0.maxX, existing.minX)
        XCTAssertEqual(placed.0.minY, 135)
        XCTAssertTrue(placed.1.contains("substantial"))
    }

    func testCaretStaysAtDeletionBoundaryWhenWordingMovesLeft() throws {
        let font = NSFont(name: "Avenir Next", size: 7) ?? NSFont.systemFont(ofSize: 7)
        let bodyFont = NSFont(name: "Avenir Next", size: 10) ?? NSFont.systemFont(ofSize: 10)
        let advance = ("i" as NSString).size(withAttributes: [.font: bodyFont]).width
        let prefix = String(repeating: "i", count: Int((504 - 20) / advance)) + " "
        let text = MarkdownRenderer().render(markdown: prefix + "Z new wording follows.")
        let location = (text.string as NSString).range(of: "Z").location
        var decorations = RevisionDecorations()
        decorations.deletions = [RevisionDeletion(location: location, text: "previous supporting wording and an extended earlier conclusion")]
        let exporter = PDFExporter()
        let notes = try exporter.revisionNoteLayout(from: text, decorations: decorations)
        let note = try XCTUnwrap(notes.first)
        let plain = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: text)))
        let selected = try XCTUnwrap(plain.findString("Z", withOptions: []).first)
        let page = try XCTUnwrap(selected.pages.first)
        XCTAssertEqual(note.anchor.x, selected.bounds(for: page).minX, accuracy: 0.1)
        let caret = RevisionAnnotationLayout.caretFrame(at: note.anchor, font: font)
        XCTAssertEqual(caret.midX, note.anchor.x, accuracy: 0.001)
        XCTAssertLessThan(note.frame.minX, note.anchor.x - 1)
        let marked = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: text, decorations: decorations)))
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        let plainBody = try XCTUnwrap(plain.findString("new wording", withOptions: []).first)
        // PDFKit can enlarge a selection rectangle to include a snug overlay.
        // Compare the actual current glyph ink, rather than that merged box.
        let size = NSSize(width: 1224, height: 1584)
        let a = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(page.thumbnail(of: size, for: .mediaBox).tiffRepresentation)))
        let markedPage = try XCTUnwrap(marked.page(at: 0))
        let b = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(markedPage.thumbnail(of: size, for: .mediaBox).tiffRepresentation)))
        let body = plainBody.bounds(for: page)
        let scale = CGFloat(a.pixelsWide) / 612
        for y in Int((792 - body.maxY) * scale)..<Int((792 - body.minY) * scale) {
            for x in Int(body.minX * scale)..<Int(body.maxX * scale) {
                if let color = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   max(color.redComponent, color.greenComponent, color.blueComponent) < 0.95 {
                    XCTAssertEqual(a.colorAt(x: x, y: y), b.colorAt(x: x, y: y))
                }
            }
        }
    }

    func testTrailingInlineCaretPinsBeforeGeneratedParagraphSeparator() throws {
        let text = MarkdownRenderer().render(markdown: "Kept words.\n\nNext paragraph.")
        let location = NSMaxRange((text.string as NSString).range(of: "Kept words."))
        var decorations = RevisionDecorations()
        decorations.deletions = [RevisionDeletion(location: location, text: "earlier ending")]
        let exporter = PDFExporter()
        let note = try XCTUnwrap(exporter.revisionNoteLayout(from: text, decorations: decorations).first)
        let plain = try XCTUnwrap(PDFDocument(data: exporter.pdfData(from: text)))
        let selected = try XCTUnwrap(plain.findString("Kept words.", withOptions: []).first)
        XCTAssertEqual(note.anchor.x, selected.bounds(for: try XCTUnwrap(selected.pages.first)).maxX, accuracy: 0.1)
    }

    func testImageRemovalKeepsItsExistingCompositeLabel() throws {
        let text = MarkdownRenderer().render(markdown: "Kept paragraph.")
        var decorations = RevisionDecorations()
        decorations.deletions = [RevisionDeletion(location: 0, text: "", isImage: true)]
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text, decorations: decorations)))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(pdf.findString("^ removed image", withOptions: []).count, 1)
    }
}

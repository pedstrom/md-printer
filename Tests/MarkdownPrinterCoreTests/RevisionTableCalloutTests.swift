import PDFKit
import CoreText
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionTableCalloutTests: XCTestCase {
    func testPDFStrikeAddsOnlyRemovedWordingPixelsAndLeavesCaretAndImagesUnchanged() throws {
        let font = NSFont(name: "Avenir Next", size: 7) ?? NSFont.systemFont(ofSize: 7)
        func bitmap(_ label: String, isImage: Bool, hasCaret: Bool = true) throws -> NSBitmapImageRep {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480, pixelsHigh: 80,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            let context = graphics.cgContext
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 80))
            context.translateBy(x: 0, y: 80); context.scaleBy(x: 4, y: -4)
            RevisionAnnotationLayout.draw(label: label, frame: CGRect(x: 10, y: 8, width: 100, height: 8),
                font: font, context: context, isImage: isImage, hasCaret: hasCaret)
            return bitmap
        }
        for (label, hasCaret, rtl) in [("^ mmmmmm", true, false), ("removed image", false, false),
                                     ("^ old مرحبا", true, false), ("^ مرحبا old", true, true)] {
            let plain = try bitmap(label, isImage: true, hasCaret: hasCaret)
            let struck = try bitmap(label, isImage: false, hasCaret: hasCaret)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font]))
            let prefixWidth = hasCaret ? CTLineGetOffsetForStringIndex(line, 2, nil) : 0
            let left = rtl ? 0 : prefixWidth
            let right = rtl ? prefixWidth : CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var changes = 0
            var furthest = -CGFloat.infinity
            for y in 0..<plain.pixelsHigh {
                for x in 0..<plain.pixelsWide where plain.colorAt(x: x, y: y) != struck.colorAt(x: x, y: y) {
                    changes += 1
                    XCTAssertGreaterThanOrEqual(CGFloat(x) / 4, 10 + left - 1)
                    XCTAssertLessThanOrEqual(CGFloat(x) / 4, 10 + right + 1)
                    furthest = max(furthest, CGFloat(x) / 4)
                    let color = try XCTUnwrap(struck.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    XCTAssertGreaterThan(color.redComponent, color.greenComponent)
                }
            }
            XCTAssertGreaterThan(changes, 20)
            XCTAssertGreaterThan(furthest, 10 + right - 2)
        }
        let image = RevisionDeletion(location: 0, text: "", isImage: true)
        XCTAssertEqual(image.label, "^ removed image")
        XCTAssertEqual(RevisionDeletion(location: 0, text: "removed image").label, image.label)
        let plainImage = try bitmap(image.label, isImage: true)
        let struckText = try bitmap(image.label, isImage: false)
        XCTAssertNotEqual(plainImage.tiffRepresentation, struckText.tiffRepresentation)
    }

    func testCellCalloutTruncatesAndShiftsLeftBeforeTheCellEdge() throws {
        let font = NSFont(name: "Avenir Next", size: 7) ?? NSFont.systemFont(ofSize: 7)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let content = CGRect(x: 54, y: 54, width: 504, height: 684)
        let cell = CGRect(x: 350, y: 100, width: 145, height: 50)
        let placed = RevisionAnnotationLayout.place(label: "^ a lengthy clause describing the original business validation outcome",
            anchor: CGPoint(x: cell.maxX - 2, y: 120), line: CGRect(x: 350, y: 108, width: 145, height: 12),
            content: content, page: page, occupied: [], notes: [], font: font, cellBounds: cell)
        XCTAssertTrue(cell.contains(placed.0))
        XCTAssertLessThan(placed.0.minX, cell.maxX - 20)
        XCTAssertLessThanOrEqual(placed.0.maxX, cell.maxX)
        XCTAssertTrue(placed.1.hasPrefix("^ "))
        XCTAssertTrue(placed.1.hasSuffix("…"))
        let previous = RevisionAnnotationLayout.truncate("^ deleted a lengthy clause describing the original business validation outcome",
            width: placed.0.width, font: font)
        XCTAssertGreaterThan(placed.1.dropFirst(2).count, previous.dropFirst("^ deleted ".count).count)
        for prefix in ["^ ", ""] {
            let width = (prefix + "…" as NSString).size(withAttributes: [.font: font]).width
            XCTAssertEqual(RevisionAnnotationLayout.truncate(prefix + "a long removed clause", width: width, font: font), prefix + "…")
        }
    }

    func testCellCalloutsUseActualPageMarginsAndKeepRemovedWording() throws {
        let font = NSFont.systemFont(ofSize: 7)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let content = CGRect(x: 54, y: 54, width: 504, height: 684)
        let occupiedCell = CGRect(x: 350, y: 100, width: 145, height: 30)
        let margin = RevisionAnnotationLayout.place(label: "^ preparing the development-environment review",
            anchor: CGPoint(x: 400, y: 110), line: occupiedCell, content: content, page: page,
            occupied: [occupiedCell], notes: [], font: font, cellBounds: occupiedCell)
        XCTAssertGreaterThan(margin.0.minX, content.maxX)
        XCTAssertFalse(margin.1.hasPrefix("^"))
        XCTAssertTrue(margin.1.hasPrefix("preparing"))
        XCTAssertTrue(margin.1.replacingOccurrences(of: "\n", with: "").contains("preparing"))
        XCTAssertTrue((2...4).contains(margin.1.components(separatedBy: "\n").count))
        let blocked = RevisionAnnotationLayout.place(label: "^ old words", anchor: occupiedCell.origin,
            line: occupiedCell, content: content, page: page, occupied: [page], notes: [], font: font, cellBounds: occupiedCell)
        XCTAssertTrue(blocked.0.isEmpty)
        XCTAssertEqual(blocked.1, "…")
        let narrowCell = CGRect(x: 350, y: 100, width: 12, height: 30)
        for isImage in [false, true] {
            let compact = RevisionAnnotationLayout.place(label: isImage ? "^ removed image" : "^ old words", anchor: narrowCell.origin,
                line: .zero, content: content, page: content, occupied: [], notes: [], font: font, cellBounds: narrowCell, isImage: isImage)
            XCTAssertTrue(narrowCell.contains(compact.0))
            XCTAssertTrue(compact.1.hasSuffix("…"))
        }
        let wideCell = CGRect(x: 350, y: 100, width: 145, height: 30)
        XCTAssertEqual(RevisionAnnotationLayout.place(label: "^ removed image", anchor: CGPoint(x: wideCell.maxX, y: 105),
            line: .zero, content: content, page: page, occupied: [], notes: [], font: font, cellBounds: wideCell, isImage: true).1, "^ removed image")
    }

    func testEmptyCellUsesItsCurrentCellButAnOutsideJoinDoesNot() throws {
        let text = MarkdownRenderer().render(markdown: "| First | Second |\n| --- | --- |\n| | Kept |\n\nOutside the table.")
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 504, height: 684))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        let string = text.string as NSString
        let empty = NSMaxRange(string.range(of: "Second")) + 1
        XCTAssertEqual(string.substring(with: NSRange(location: empty, length: 1)), "\n")
        XCTAssertNotNil(RevisionAnnotationLayout.tableCellBounds(at: empty, in: text, layoutManager: manager))
        let outside = string.range(of: "Outside").location
        XCTAssertNil(RevisionAnnotationLayout.tableCellBounds(at: outside, in: text, layoutManager: manager))
        XCTAssertNil(RevisionAnnotationLayout.tableCellBounds(at: text.length, in: text, layoutManager: manager))
    }

    func testPDFTableCalloutPixelsAndTextStayInsideTheirCurrentCell() throws {
        let markdown = "| First | Middle | Last |\n| --- | --- | ---: |\n| Unchanged | Current middle wording ends here. | Current right wording ends here. |"
        let renderer = MarkdownRenderer(), text = renderer.render(markdown: markdown)
        let plainData = try PDFExporter().pdfData(from: text)
        let plain = try XCTUnwrap(PDFDocument(data: plainData)), plainPage = try XCTUnwrap(plain.page(at: 0))
        let plainBitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(plainPage.thumbnail(of: plainPage.bounds(for: .mediaBox).size, for: .mediaBox).tiffRepresentation)))
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 504, height: 684))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        for (name, phrase) in [("middle", "Current middle wording ends here."), ("right", "Current right wording ends here.")] {
            let range = (text.string as NSString).range(of: phrase), location = NSMaxRange(range)
            let style = try XCTUnwrap(text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
            let cell = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
            let glyph = manager.glyphIndexForCharacter(at: location)
            let outer = manager.boundsRect(for: cell, at: glyph, effectiveRange: nil).offsetBy(dx: 54, dy: 54)
            let padded = manager.layoutRect(for: cell, at: glyph, effectiveRange: nil).offsetBy(dx: 54, dy: 54)
            var decorations = RevisionDecorations()
            decorations.deletions = [RevisionDeletion(location: location, text: "a long original clause with business validation criteria and an extended explanation that must fit this cell")]
            let markedData = try PDFExporter().pdfData(from: text, decorations: decorations)
            let marked = try XCTUnwrap(PDFDocument(data: markedData)), page = try XCTUnwrap(marked.page(at: 0))
            XCTAssertEqual(marked.pageCount, plain.pageCount)
            XCTAssertTrue(page.string?.contains("…") == true)
            let bodyPlain = try XCTUnwrap(plain.findString("Current", withOptions: []).first { padded.minX <= $0.bounds(for: plainPage).minX && $0.bounds(for: plainPage).maxX <= padded.maxX })
            XCTAssertFalse(marked.findString("a long", withOptions: []).isEmpty)
            let callout = try XCTUnwrap(PDFExporter().revisionNoteLayout(from: text, decorations: decorations).first)
            // Separate TextKit layouts can snap table content edges by one
            // point; the pixel check below enforces the actual cell border.
            XCTAssertGreaterThanOrEqual(callout.frame.minX, padded.minX - 1)
            XCTAssertLessThanOrEqual(callout.frame.maxX, padded.maxX + 0.1)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox).tiffRepresentation)))
            let scale = CGFloat(bitmap.pixelsWide) / page.bounds(for: .mediaBox).width
            // PDFKit can enlarge a whole line's selection rectangle to include
            // a snug overlay. Compare the body word's actual pixels instead.
            let body = bodyPlain.bounds(for: plainPage)
            let bodyTop = page.bounds(for: .mediaBox).height - body.maxY
            for y in Int(floor(bodyTop * scale))..<Int(ceil((bodyTop + body.height) * scale)) {
                for x in Int(floor(body.minX * scale))..<Int(ceil(body.maxX * scale)) {
                    // A snug overlay may occupy blank space inside a font's
                    // selection box; preserve every actual body-ink pixel.
                    if let color = plainBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.999 {
                        XCTAssertEqual(plainBitmap.colorAt(x: x, y: y), bitmap.colorAt(x: x, y: y),
                            "Body pixel changed at \(x),\(y); note \(callout.frame), anchor \(callout.anchor), leader \(callout.leader)")
                    }
                }
            }
            var redPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.redComponent > color.greenComponent + 0.08,
                          color.redComponent > color.blueComponent + 0.08 else { continue }
                    redPixels += 1
                    XCTAssertTrue(outer.insetBy(dx: -1 / scale, dy: -1 / scale).contains(CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale)),
                                  "\(name) callout pixel escaped its cell at \(x),\(y)")
                    XCTAssertLessThanOrEqual(CGFloat(x) / scale, outer.maxX + 1 / scale)
                }
            }
            XCTAssertGreaterThan(redPixels, 10)
            if let path = ProcessInfo.processInfo.environment["MDPRINTER_TABLE_REVISION_FIXTURES"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try markedData.write(to: output.appendingPathComponent(name + ".pdf"))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
            }
        }
    }

    func testMultiPageTableNotesKeepEachCurrentRowOnItsOriginalPage() throws {
        let markdown = "| ID | Value |\n| --- | ---: |\n" + (0..<60).map { "| Row [\($0)] | Current [\($0)] |" }.joined(separator: "\n")
        let text = MarkdownRenderer().render(markdown: markdown)
        var decorations = RevisionDecorations()
        for index in 0..<60 {
            let range = (text.string as NSString).range(of: "Current [\(index)]")
            decorations.deletions.append(RevisionDeletion(location: NSMaxRange(range), text: "old"))
        }
        let plain = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        let marked = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text, decorations: decorations)))
        XCTAssertGreaterThan(plain.pageCount, 1)
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        XCTAssertEqual(marked.findString("old", withOptions: []).count, 60)
        for index in 0..<60 {
            let a = try XCTUnwrap(plain.findString("Current [\(index)]", withOptions: []).first)
            let b = try XCTUnwrap(marked.findString("Current [\(index)]", withOptions: []).first)
            let ap = try XCTUnwrap(a.pages.first), bp = try XCTUnwrap(b.pages.first)
            XCTAssertEqual(plain.index(for: ap), marked.index(for: bp))
            XCTAssertEqual(a.bounds(for: ap), b.bounds(for: bp))
        }
    }

    func testCrowdedCellFallbackDrawsReadableWrappedMarginNotes() throws {
        let text = MarkdownRenderer().render(markdown: "| First | Last |\n| --- | ---: |\n| Unchanged | Current value |")
        let location = NSMaxRange((text.string as NSString).range(of: "Current value"))
        var decorations = RevisionDecorations()
        decorations.deletions = [RevisionDeletion(location: location, text: "old"),
            RevisionDeletion(location: location, text: "preparing the development-environment review and the prior execution criteria"),
            RevisionDeletion(location: location, text: "validating business execution and several additional original conditions")]
        let data = try PDFExporter().pdfData(from: text, decorations: decorations)
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        let layouts = try PDFExporter().revisionNoteLayout(from: text, decorations: decorations)
        XCTAssertTrue(layouts.contains { !$0.isMargin && $0.label.contains("preparing") })
        // Free space inside the cell is preferred; only remaining collisions
        // fall back to a wrapped page-margin note.
        for word in ["preparing", "validating"] {
            let selected = try XCTUnwrap(document.findString(word, withOptions: []).first)
            XCTAssertGreaterThan(selected.bounds(for: page).minX, 306)
            XCTAssertLessThanOrEqual(selected.bounds(for: page).maxX, 606)
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox).tiffRepresentation)))
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_TABLE_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("wrapped-margins.pdf"))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("wrapped-margins.png"))
        }
    }
}

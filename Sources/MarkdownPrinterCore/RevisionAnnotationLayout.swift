#if canImport(AppKit)
import AppKit
import CoreText

struct RevisionPDFNote {
    let page: Int
    let anchor: CGPoint
    let frame: CGRect
    let label: String
    var cellBounds: CGRect? = nil
    var isMargin = false
    var isImage = false
}

public enum RevisionAnnotationError: LocalizedError {
    case noSpace
    public var errorDescription: String? {
        "A deletion callout could not fit without obscuring the document. Try a different page size or scale."
    }
}

enum RevisionAnnotationLayout {
    static func place(label: String, anchor: CGPoint, line: CGRect, content: CGRect,
                      page: CGRect, occupied: [CGRect], notes: [CGRect], font: NSFont,
                      cellBounds: CGRect? = nil, isImage: Bool = false) throws -> (CGRect, String) {
        let pageContent = content
        let content = cellBounds.map { $0.intersection(pageContent) } ?? pageContent
        let height = ceil(inkBounds(label: label, font: font).height)
        let prefix = isImage ? label : "^ …"
        let fullWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let minimumWidth = min(fullWidth, ceil((prefix as NSString).size(withAttributes: [.font: font]).width))
        var positions = [max(content.minY, line.maxY - 1)]
        // Prefer a nearby gap over a margin. No changes to body geometry.
        let nearby = occupied.sorted { left, right in
            let a = abs(left.maxY - line.maxY), b = abs(right.maxY - line.maxY)
            if a != b { return a < b }
            return left.maxY > right.maxY
        }
        for rect in nearby where abs(rect.maxY - line.maxY) < 80 {
            positions.append(max(content.minY, rect.maxY - 1))
        }
        var candidates: [CGRect] = []
        for y in positions where y + height <= content.maxY {
            // A gap can be usable away from the anchor's column. Subtract all
            // text/note obstacles across this band, within the current cell.
            let band = CGRect(x: content.minX, y: y, width: content.width, height: height)
            let blockers = (occupied.map { $0.insetBy(dx: 0, dy: 1) }
                + notes.map { $0.insetBy(dx: -2, dy: -1) })
                .filter { $0.intersects(band) }.sorted { $0.minX < $1.minX }
            var gaps: [CGRect] = [], start = content.minX
            for blocker in blockers {
                if blocker.minX > start {
                    gaps.append(CGRect(x: start, y: y, width: min(blocker.minX, content.maxX) - start, height: height))
                }
                start = max(start, min(content.maxX, blocker.maxX))
            }
            if start < content.maxX { gaps.append(CGRect(x: start, y: y, width: content.maxX - start, height: height)) }
            gaps.sort { abs($0.midX - anchor.x) < abs($1.midX - anchor.x) }
            for gap in gaps {
                let alignedX = max(gap.minX, anchor.x)
                if alignedX < gap.maxX {
                    candidates.append(CGRect(x: alignedX, y: y, width: min(fullWidth, gap.maxX - alignedX), height: height))
                }
                let width = min(gap.width, fullWidth)
                candidates.append(CGRect(x: min(max(gap.minX, anchor.x), gap.maxX - width), y: y, width: width, height: height))
            }
        }
        for candidate in candidates where content.width >= minimumWidth && content.height >= height {
            let text = truncate(label, width: candidate.width, font: font)
            guard showsRemovedWording(text, original: label, isImage: isImage) else { continue }
            let actual = CGRect(origin: candidate.origin, size: CGSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width), height: height))
            if content.contains(actual), fits(actual, occupied: occupied, notes: notes) { return (actual, text) }
        }
        // Use actual page margins only, after exhausting the current cell's
        // gaps. Wrapped wording keeps a displaced note useful at seven points.
        let marginLabel = label.hasPrefix("^ ") ? String(label.dropFirst(2)) : label
        for maximumLines in stride(from: 4, through: 1, by: -1) {
            for x in [pageContent.maxX + 4, page.minX + 6] {
                let marginWidth = x > pageContent.maxX ? page.maxX - x - 6 : pageContent.minX - x - 4
                guard marginWidth >= 36 else { continue }
                let lines = wrapped(marginLabel, width: marginWidth, maximumLines: maximumLines, font: font)
                let text = lines.joined(separator: "\n")
                guard !lines.isEmpty, showsRemovedWording(text, original: label, isImage: isImage) else { continue }
                let noteHeight = lines.map { ceil(inkBounds(label: $0, font: font).height) }.max()!
                    + lineStep(font) * CGFloat(lines.count - 1)
                let nearbyY = max(pageContent.minY, min(line.maxY, pageContent.maxY - noteHeight))
                let positions = Array(stride(from: nearbyY, through: pageContent.maxY - noteHeight, by: noteHeight + 2))
                    + Array(stride(from: pageContent.minY, through: pageContent.maxY - noteHeight, by: noteHeight + 2))
                for y in positions {
                    let rect = CGRect(x: x, y: y, width: marginWidth, height: noteHeight)
                    if fits(rect, occupied: occupied, notes: notes) { return (rect, text) }
                }
            }
        }
        throw RevisionAnnotationError.noSpace
    }

    private static func showsRemovedWording(_ displayed: String, original: String, isImage: Bool) -> Bool {
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        let displayed = displayed.hasPrefix("^ ") ? String(displayed.dropFirst(2)) : displayed
        if isImage { return compact(displayed) == "removedimage" }
        let removed = compact(original.hasPrefix("^ ") ? String(original.dropFirst(2)) : original)
        return !removed.isEmpty && compact(displayed).hasPrefix(String(removed.prefix(4)))
    }

    private static func wrapped(_ label: String, width: CGFloat, maximumLines: Int, font: NSFont) -> [String] {
        let string = label as NSString
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font]))
        var start = 0, lines: [String] = []
        while start < string.length && lines.count < maximumLines {
            if lines.count == maximumLines - 1 {
                lines.append(truncate(string.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines), width: width, font: font))
                break
            }
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            lines.append(string.substring(with: NSRange(location: start, length: count)).trimmingCharacters(in: .whitespacesAndNewlines))
            start += count
        }
        return lines.filter { !$0.isEmpty }
    }

    private static func lineStep(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }

    static func tableCellBounds(at location: Int, in text: NSAttributedString,
                                layoutManager: NSLayoutManager, origin: CGPoint = .zero) -> CGRect? {
        guard location >= 0, location < text.length,
              let style = text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
              let cell = style.textBlocks.reversed().compactMap({ $0 as? NSTextTableBlock }).first else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let layout = layoutManager.layoutRect(for: cell, at: glyph, effectiveRange: nil)
        let bounds = layoutManager.boundsRect(for: cell, at: glyph, effectiveRange: nil)
        // The layout rectangle has the padded content width but extends to the
        // available page height. The bounds rectangle has the actual row height.
        // Keep vertical padding available for a snug note, inside the border.
        let top = max(1, cell.width(for: .border, edge: .minY))
        let bottom = max(1, cell.width(for: .border, edge: .maxY))
        return CGRect(x: origin.x + layout.minX, y: origin.y + bounds.minY + top,
                      width: layout.width, height: max(0, bounds.height - top - bottom))
    }

    static func truncate(_ label: String, width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard (label as NSString).size(withAttributes: attributes).width > width else { return label }
        var letters = Array(label)
        while !letters.isEmpty, (String(letters) + "…" as NSString).size(withAttributes: attributes).width > width { letters.removeLast() }
        let stem = String(letters).trimmingCharacters(in: .whitespaces)
        if stem == "^",
           (stem + " …" as NSString).size(withAttributes: attributes).width <= width {
            return stem + " …"
        }
        return stem + "…"
    }

    private static func inkBounds(label: String, font: NSFont) -> CGRect {
        CTLineGetBoundsWithOptions(labelLine(label, font: font), .useGlyphPathBounds)
    }

    private static func labelLine(_ label: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: label,
            attributes: [.font: font, .foregroundColor: RevisionFormatter.deletionColor]))
    }

    static func caretFrame(at anchor: CGPoint, font: NSFont) -> CGRect {
        let ink = inkBounds(label: "^", font: font)
        return CGRect(x: anchor.x - ink.width / 2, y: anchor.y - 1, width: ink.width, height: ink.height)
    }

    static func draw(label: String, frame: CGRect, font: NSFont, context: CGContext,
                     isImage: Bool = false, hasCaret: Bool = true) {
        for (index, text) in label.components(separatedBy: "\n").enumerated() {
            let line = labelLine(text, font: font)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            context.saveGState()
            context.translateBy(x: frame.minX - bounds.minX,
                y: frame.minY + lineStep(font) * CGFloat(index) + bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            if !isImage {
                // CoreText does not paint AppKit's strikethrough attribute.
                // Strike only the removed wording, retaining the caret marker.
                let start = index == 0 && hasCaret && text.hasPrefix("^ ") ? 2 : 0
                context.setStrokeColor(RevisionFormatter.deletionColor.cgColor)
                context.setLineWidth(max(0.3, font.underlineThickness))
                // Logical string endpoints can sit inside a bidi run. Use
                // its visual glyph advances so every removed glyph is struck.
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let count = CTRunGetGlyphCount(run)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    var advances = [CGSize](repeating: .zero, count: count)
                    var indices = [CFIndex](repeating: 0, count: count)
                    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                    CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                    CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                    let glyphs = (0..<count).filter { indices[$0] >= start }
                    guard let leading = glyphs.map({ min(positions[$0].x, positions[$0].x + advances[$0].width) }).min(),
                          let trailing = glyphs.map({ max(positions[$0].x, positions[$0].x + advances[$0].width) }).max() else { continue }
                    context.move(to: CGPoint(x: leading, y: font.xHeight / 2))
                    context.addLine(to: CGPoint(x: trailing, y: font.xHeight / 2))
                    context.strokePath()
                }
            }
            context.restoreGState()
        }
    }

    private static func fits(_ rect: CGRect, occupied: [CGRect], notes: [CGRect]) -> Bool {
        !occupied.contains { $0.insetBy(dx: 0, dy: 1).intersects(rect) }
            && !notes.contains { $0.insetBy(dx: -2, dy: -1).intersects(rect) }
    }
}
#endif

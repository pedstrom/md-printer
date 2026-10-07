#if canImport(AppKit)
import AppKit
import CoreText

struct RevisionPDFNote {
    let page: Int
    let anchor: CGPoint
    var frame: CGRect
    var label: String
    var cellBounds: CGRect? = nil
    var isMargin = false
    var isImage = false
    var strikeWording = true
    var leader: [CGPoint] = []

    var isBoundaryOnly: Bool { frame.isEmpty }

    func wordingFrame(font: NSFont) -> CGRect {
        guard !isImage, !isMargin, label.hasPrefix("^ ") else { return frame }
        let prefix = ("^ " as NSString).size(withAttributes: [.font: font]).width
        return CGRect(x: frame.minX + prefix, y: frame.minY,
                      width: max(0, frame.width - prefix), height: frame.height)
    }
}

enum RevisionAnnotationError: Error {
    case noSpace
}

enum RevisionAnnotationLayout {
    static func place(label: String, anchor: CGPoint, line: CGRect, content: CGRect,
                      page: CGRect, occupied: [CGRect], notes: [CGRect], font: NSFont,
                      cellBounds: CGRect? = nil, isImage: Bool = false, isSummary: Bool = false,
                      markers: [CGRect] = [], lineBounds: [CGRect]? = nil) -> (CGRect, String) {
        let pageContent = content
        let content = cellBounds.map { $0.intersection(pageContent) } ?? pageContent
        let height = ceil(inkBounds(label: label, font: font).height)
        let prefix = "^ …"
        let fullWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let minimumWidth = min(fullWidth, ceil((prefix as NSString).size(withAttributes: [.font: font]).width))
        var positions = [max(content.minY, line.maxY - 1)]
        // Prefer a nearby gap over a margin. No changes to body geometry.
        let nearby = (lineBounds ?? occupied).sorted { left, right in
            let a = abs(left.maxY - line.maxY), b = abs(right.maxY - line.maxY)
            if a != b { return a < b }
            return left.maxY > right.maxY
        }
        for rect in nearby where abs(rect.maxY - line.maxY) < 80 {
            positions.append(max(content.minY, rect.maxY - 1))
        }
        var seenPositions = Set<CGFloat>()
        positions = positions.filter { seenPositions.insert($0).inserted }
        var candidates: [CGRect] = []
        for y in positions where y + height <= content.maxY {
            // A gap can be usable away from the anchor's column. Subtract all
            // text/note obstacles across this band, within the current cell.
            let band = CGRect(x: content.minX, y: y, width: content.width, height: height)
            let ownMarker = isImage ? CGRect.null : caretFrame(at: anchor, font: font)
            let blockers = (occupied.map { $0.insetBy(dx: 0, dy: 1) }
                + notes.map { $0.insetBy(dx: -2, dy: -1) }
                + markers.filter { $0 != ownMarker }.map { $0.insetBy(dx: -1, dy: -1) })
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
        // Retain useful wording whenever possible. If that cannot fit, repeat
        // with progressively truncated labels, including just a caret/ellipsis.
        for informative in [true, false] {
            for candidate in candidates where candidate.width >= minimumWidth && content.height >= height {
                let text = truncate(label, width: candidate.width, font: font)
                guard !informative || showsRemovedWording(text, original: label, requiresCompleteLabel: isImage || isSummary) else { continue }
                let actual = CGRect(origin: candidate.origin, size: CGSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width), height: height))
                let prefix = !isImage && text.hasPrefix("^ ") ? ("^ " as NSString).size(withAttributes: [.font: font]).width : 0
                let wording = CGRect(x: actual.minX + prefix, y: actual.minY,
                                     width: max(0, actual.width - prefix), height: actual.height)
                if content.contains(actual), fits(actual, occupied: occupied, notes: notes),
                   !markers.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(wording) }) { return (actual, text) }
            }
            // Use actual page margins only, after exhausting the current cell's
            // gaps. Wrapped wording keeps a displaced note useful at seven points.
            let marginLabel = label.hasPrefix("^ ") ? String(label.dropFirst(2)) : label
            for maximumLines in stride(from: 4, through: 1, by: -1) {
                for x in [pageContent.maxX + 4, page.minX + 6] {
                    let marginWidth = x > pageContent.maxX ? page.maxX - x - 6 : pageContent.minX - x - 4
                    let minimumMarginWidth = informative ? 36 : ceil(("…" as NSString).size(withAttributes: [.font: font]).width)
                    guard marginWidth >= minimumMarginWidth else { continue }
                    let lines = wrapped(marginLabel, width: marginWidth, maximumLines: maximumLines, font: font)
                    let text = lines.joined(separator: "\n")
                    guard !lines.isEmpty, !informative || showsRemovedWording(text, original: label, requiresCompleteLabel: isImage || isSummary) else { continue }
                    let noteHeight = lines.map { ceil(inkBounds(label: $0, font: font).height) }.max()!
                        + lineStep(font) * CGFloat(lines.count - 1)
                    let nearbyY = max(pageContent.minY, min(line.maxY, pageContent.maxY - noteHeight))
                    let positions = Array(stride(from: nearbyY, through: pageContent.maxY - noteHeight, by: noteHeight + 2))
                        + Array(stride(from: pageContent.minY, through: pageContent.maxY - noteHeight, by: noteHeight + 2))
                    for y in positions {
                        let rect = CGRect(x: x, y: y, width: marginWidth, height: noteHeight)
                        if fits(rect, occupied: occupied, notes: notes),
                           !markers.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(rect) }) { return (rect, text) }
                    }
                }
            }
        }
        // No floating label can fit safely. Keep an ellipsis at the deletion
        // boundary instead of rejecting the already successful comparison.
        return (CGRect(origin: anchor, size: .zero), "…")
    }

    private static func showsRemovedWording(_ displayed: String, original: String, requiresCompleteLabel: Bool) -> Bool {
        func compact(_ value: String) -> String { value.filter { !$0.isWhitespace } }
        let displayed = displayed.hasPrefix("^ ") ? String(displayed.dropFirst(2)) : displayed
        let removed = compact(original.hasPrefix("^ ") ? String(original.dropFirst(2)) : original)
        if requiresCompleteLabel { return compact(displayed) == removed }
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

    /// Connect outside glyph ink and markers. A shifted-left label must meet
    /// its right edge, rather than drawing a line across its removed wording.
    static func leader(for note: RevisionPDFNote, font: NSFont, page: CGRect, content: CGRect,
                       occupied: [CGRect], notes: [RevisionPDFNote], previous: [[CGPoint]]) throws -> [CGPoint] {
        guard !note.isBoundaryOnly else { return [] }
        guard abs(note.frame.minX - note.anchor.x) > 3 || abs(note.frame.minY - note.anchor.y) > 16 else { return [] }
        let label = note.wordingFrame(font: font)
        let start = departure(for: note, font: font, notes: notes)
        // Image removals keep their composite label. If it already covers the
        // boundary, a connector would only draw across its own visible wording.
        if note.isImage, label.insetBy(dx: -0.3, dy: -0.3).contains(start) { return [] }
        let end: CGPoint
        if start.x > label.maxX {
            end = CGPoint(x: label.maxX + 0.6, y: label.midY)
        } else if start.x < label.minX {
            end = CGPoint(x: label.minX - 0.6, y: label.midY)
        } else {
            end = CGPoint(x: start.x, y: start.y < label.minY ? label.minY - 0.6 : label.maxY + 0.6)
        }
        let markers = notes.filter { !$0.isImage }.map { caretFrame(at: $0.anchor, font: font) }
        // An earlier connector must also leave room for the later connectors
        // to depart below their carets, outside the marker's own ink bounds.
        let departures = notes.filter { $0.anchor != note.anchor }.map { other in
            let point = departure(for: other, font: font, notes: notes)
            return CGRect(x: point.x - 0.3, y: point.y - 0.3, width: 0.6, height: 0.6)
        }
        let corridors = leaderObstacles(previous.filter { $0.first != start })
        let obstacles = occupied + notes.map { $0.wordingFrame(font: font) } + markers + departures + corridors
        // Index glyph ink by vertical bands so routing through real whitespace
        // does not scan every glyph on the page for every candidate segment.
        var bands: [Int: [CGRect]] = [:]
        for obstacle in obstacles {
            for band in Int(floor(obstacle.minY / 12))...Int(floor(obstacle.maxY / 12)) {
                bands[band, default: []].append(obstacle)
            }
        }
        func clear(_ path: [CGPoint]) -> Bool {
            path.allSatisfy { page.insetBy(dx: 1, dy: 1).contains($0) }
                && zip(path, path.dropFirst()).allSatisfy { a, b in
                    let segment = segmentBounds(a, b)
                    return (Int(floor(segment.minY / 12))...Int(floor(segment.maxY / 12))).allSatisfy { band in
                        !(bands[band] ?? []).contains { $0.intersects(segment) }
                    }
                }
        }
        var seenLanes = Set<CGFloat>()
        let lanes = ([label.maxY + 1, label.minY - 1, start.y]
            + obstacles.flatMap { [$0.maxY + 1, $0.minY - 1] }).filter { seenLanes.insert($0).inserted }
        // The page gutters provide a safe vertical route between distant gaps.
        // Cell-edge routes are considered too, but must pass the same ink check.
        let columns = [content.minX - 2, content.maxX + 2]
            + (note.cellBounds.map { [$0.minX - 2, $0.maxX + 2] } ?? [])
        func length(_ path: [CGPoint]) -> CGFloat {
            zip(path, path.dropFirst()).reduce(0) { $0 + abs($1.0.x - $1.1.x) + abs($1.0.y - $1.1.y) }
        }
        let alternatives = [CGPoint(x: label.maxX + 0.6, y: label.midY), CGPoint(x: label.minX - 0.6, y: label.midY),
                            CGPoint(x: label.midX, y: label.maxY + 0.6), CGPoint(x: label.midX, y: label.minY - 0.6)]
            .sorted { hypot($0.x - start.x, $0.y - start.y) < hypot($1.x - start.x, $1.y - start.y) }
        let ends = [end] + alternatives.filter { $0 != end }
        for end in ends {
            var candidates: [[CGPoint]] = []
            if abs(start.x - end.x) < 1 { candidates.append([start, end]) }
            for y in lanes {
                candidates.append([start, CGPoint(x: start.x, y: y), CGPoint(x: end.x, y: y), end])
            }
            for x in columns {
                for sourceY in lanes {
                    for targetY in [label.maxY + 1, label.minY - 1] {
                        candidates.append([start, CGPoint(x: start.x, y: sourceY), CGPoint(x: x, y: sourceY),
                            CGPoint(x: x, y: targetY), CGPoint(x: end.x, y: targetY), end])
                    }
                }
            }
            if let path = candidates.filter(clear).min(by: { length($0) < length($1) }) {
                return path.enumerated().compactMap { index, point in index > 0 && point == path[index - 1] ? nil : point }
            }
        }
        throw RevisionAnnotationError.noSpace
    }

    static func leaderObstacles(_ paths: [[CGPoint]]) -> [CGRect] {
        paths.flatMap { path in zip(path, path.dropFirst()).map { segmentBounds($0, $1) } }
    }

    private static func departure(for note: RevisionPDFNote, font: NSFont, notes: [RevisionPDFNote]) -> CGPoint {
        let hasTextCaret = !note.isImage || notes.contains { !$0.isImage && $0.anchor == note.anchor }
        return CGPoint(x: note.anchor.x, y: hasTextCaret ? caretFrame(at: note.anchor, font: font).maxY + 0.4 : note.anchor.y + 0.4)
    }

    private static func segmentBounds(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(0.2, abs(a.x - b.x)), height: max(0.2, abs(a.y - b.y)))
            .insetBy(dx: -0.1, dy: -0.1)
    }

    static func draw(label: String, frame: CGRect, font: NSFont, context: CGContext,
                     isImage: Bool = false, hasCaret: Bool = true, strikeWording: Bool = true) {
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
            if !isImage && strikeWording {
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

#if canImport(AppKit)
import AppKit

/// Fits PDF table images against TextKit's measured cells, without changing the
/// renderer's attachments shared by Word export or continuous Quick Look.
@MainActor
final class TableImageLayout {
    enum Adjustment {
        case resized
        case pageBreak(NSTextContainer, CGFloat)
        case none
    }

    private struct RowKey: Hashable {
        let table: ObjectIdentifier
        let row: Int
    }

    private struct Image {
        let range: NSRange
        let cell: NSTextTableBlock
        let attachment: NSTextAttachment
        var minimumHeight: CGFloat = 0
    }

    private struct Row {
        let key: RowKey
        let cell: NSTextTableBlock
        var range: NSRange
        var images: [Image] = []
    }

    private let text: NSTextStorage
    private var rows: [Row] = []
    private var attemptedBreaks: Set<RowKey> = []

    init(text: NSTextStorage) {
        self.text = text
        var images: [RowKey: [Image]] = [:]
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let source = value as? NSTextAttachment, let image = source.image,
                  source.bounds.width > 0, source.bounds.height > 0,
                  let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let cell = style.textBlocks.last as? NSTextTableBlock else { return }
            let copy = NSTextAttachment()
            copy.image = image
            copy.bounds = source.bounds
            let key = RowKey(table: ObjectIdentifier(cell.table), row: cell.startingRow)
            images[key, default: []].append(Image(range: range, cell: cell, attachment: copy))
        }
        guard !images.isEmpty else { return }
        var indices: [RowKey: Int] = [:]
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let cell = style.textBlocks.last as? NSTextTableBlock else { return }
            let key = RowKey(table: ObjectIdentifier(cell.table), row: cell.startingRow)
            if let index = indices[key] {
                rows[index].range = NSUnionRange(rows[index].range, range)
            } else {
                indices[key] = rows.count
                rows.append(Row(key: key, cell: cell, range: range, images: images[key] ?? []))
            }
        }
        for row in rows {
            for image in row.images { text.addAttribute(.attachment, value: image.attachment, range: image.range) }
        }
    }

    func fitWidths(using manager: NSLayoutManager, pageHeight: CGFloat) -> Bool {
        var adjustments: [(Image, CGFloat)] = []
        for rowIndex in rows.indices {
            let caption = captionHeight(after: rowIndex, using: manager)
            for imageIndex in rows[rowIndex].images.indices {
                let image = rows[rowIndex].images[imageIndex]
                let glyph = manager.glyphIndexForCharacter(at: image.range.location)
                let cell = manager.layoutRect(for: image.cell, at: glyph, effectiveRange: nil)
                let original = image.attachment.bounds
                // Round inward, retaining padding and room for the baseline and
                // any following caption even for very tall portrait images.
                let width = max(1, floor(cell.width) - 0.5)
                let height = max(1, pageHeight - 24 - caption)
                let scale = min(1, width / original.width, height / original.height)
                if scale < 1 { adjustments.append((image, scale)) }
                rows[rowIndex].images[imageIndex].minimumHeight = original.height * scale * 0.85
            }
        }
        // Measure every cell before editing. Editing the first attachment
        // invalidates the native geometry for later cells in the same row.
        text.beginEditing()
        for (image, scale) in adjustments { resize(image, scale: scale) }
        text.endEditing()
        return !adjustments.isEmpty
    }

    func nextAdjustment(using manager: NSLayoutManager) -> Adjustment {
        for rowIndex in rows.indices where !rows[rowIndex].images.isEmpty {
            let row = rows[rowIndex]
            let start = manager.glyphIndexForCharacter(at: row.range.location)
            guard let container = manager.textContainer(forGlyphAt: start, effectiveRange: nil) else { continue }
            let bounds = manager.boundsRect(for: row.cell, at: start, effectiveRange: nil)
            var inkBottom = bounds.minY
            var tallest: CGFloat = 0
            for image in row.images {
                let glyph = manager.glyphIndexForCharacter(at: image.range.location)
                let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let position = manager.location(forGlyphAt: glyph)
                let imageCell = manager.boundsRect(for: image.cell, at: glyph, effectiveRange: nil)
                inkBottom = max(inkBottom, bounds.minY + fragment.minY + position.y
                                - image.attachment.bounds.minY - imageCell.minY)
                tallest = max(tallest, image.attachment.bounds.height)
            }
            guard tallest > 0 else { continue }
            let padding = row.cell.width(for: .padding, edge: .maxY) + row.cell.width(for: .border, edge: .maxY)
            let rowHeight = max(bounds.height, inkBottom - bounds.minY + padding)
            let desired = rowHeight + captionHeight(after: rowIndex, using: manager)
            var available = container.containerSize.height - bounds.minY

            // TextKit may already have moved the row. Try a modest reduction
            // into the space following the previous row of the same table.
            if bounds.minY < 20, let index = manager.textContainers.firstIndex(where: { $0 === container }), index > 0 {
                let previous = manager.textContainers[index - 1]
                let preceding = row.range.location - 1
                if preceding >= 0,
                   let style = text.attribute(.paragraphStyle, at: preceding, effectiveRange: nil) as? NSParagraphStyle,
                   let cell = style.textBlocks.last as? NSTextTableBlock,
                   cell.table === row.cell.table {
                    let remaining = previous.containerSize.height - manager.usedRect(for: previous).maxY - 2
                    let scale = (tallest - (desired - remaining) - 1) / tallest
                    if remaining < desired, scale >= 0.85 { available = remaining }
                }
            }
            guard desired > available + 0.5 else { continue }
            let scale = (tallest - (desired - available) - 1) / tallest
            if scale < 1, scale > 0,
               row.images.allSatisfy({ $0.attachment.bounds.height * scale >= $0.minimumHeight }) {
                text.beginEditing()
                for image in row.images { resize(image, scale: scale) }
                text.endEditing()
                return .resized
            }
            // Larger reductions sacrifice too much detail. Move the row intact
            // when it has preceding content, rather than painting into a footer.
            if bounds.minY > 20, !attemptedBreaks.contains(row.key),
               inkBottom + padding > container.containerSize.height + 0.5 {
                attemptedBreaks.insert(row.key)
                return .pageBreak(container, bounds.minY)
            }
        }
        return .none
    }

    private func captionHeight(after index: Int, using manager: NSLayoutManager) -> CGFloat {
        guard index + 1 < rows.count else { return 0 }
        let row = rows[index], next = rows[index + 1]
        guard next.key.table == row.key.table, next.key.row == row.key.row + 1,
              next.images.isEmpty else { return 0 }
        let glyph = manager.glyphIndexForCharacter(at: next.range.location)
        let height = manager.boundsRect(for: next.cell, at: glyph, effectiveRange: nil).height
        return height <= 60 ? height : 0
    }

    private func resize(_ image: Image, scale: CGFloat) {
        var bounds = image.attachment.bounds
        bounds.size.width *= scale
        bounds.size.height *= scale
        image.attachment.bounds = bounds
        text.addAttribute(.attachment, value: image.attachment, range: image.range)
    }
}
#endif

import AppKit

/// A screen-only attachment; the shared renderer keeps its existing print/export fallback.
package final class QuickLookImagePlaceholder: NSTextAttachment {
    package let filename: String

    package init(source: String, maximumWidth: CGFloat) {
        let path = URLComponents(string: source)?.path ?? source.removingPercentEncoding ?? source
        let name = (path as NSString).lastPathComponent
        filename = name.isEmpty || name == "/" ? "Image" : name
        super.init(data: nil, ofType: nil)
        bounds = Self.frame(width: max(1, maximumWidth))
        attachmentCell = QuickLookImagePlaceholderCell(textCell: filename)
    }

    package required init?(coder: NSCoder) {
        nil
    }

    package override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        let availableWidth = lineFrag.width - 2 * (textContainer?.lineFragmentPadding ?? 0)
        return Self.frame(width: max(1, min(bounds.width, availableWidth)))
    }

    package override func image(
        forBounds imageBounds: CGRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> NSImage? {
        let label = filename
        let image = NSImage(size: imageBounds.size, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            NSColor.labelColor.withAlphaComponent(0.035).setFill()
            box.fill()
            NSColor.separatorColor.setStroke()
            box.lineWidth = 1
            box.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingMiddle
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont(name: "Avenir Next", size: 13) ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ])
            let height = ceil(text.size().height)
            let inset = min(20, rect.width / 4)
            text.draw(with: NSRect(
                x: rect.minX + inset,
                y: rect.midY - height / 2,
                width: max(1, rect.width - inset * 2),
                height: height
            ), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        image.accessibilityDescription = "Unavailable image: \(filename)"
        return image
    }

    private static func frame(width: CGFloat) -> CGRect {
        CGRect(x: 0, y: -4, width: width, height: min(180, max(64, width * 0.4)))
    }
}

private final class QuickLookImagePlaceholderCell: NSTextAttachmentCell {
    override func cellSize() -> NSSize {
        attachment?.bounds.size ?? .zero
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        attachment?.attachmentBounds(
            for: textContainer, proposedLineFragment: lineFrag,
            glyphPosition: position, characterIndex: charIndex
        ) ?? .zero
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        attachment?.image(forBounds: cellFrame, textContainer: nil, characterIndex: 0)?
            .draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

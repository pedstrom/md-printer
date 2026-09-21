import AppKit
import MarkdownPrinterCore
import PDFKit

@MainActor
enum ExportDragThumbnail {
    static let size = NSSize(width: 110, height: 142)

    static func image(page: PDFPage?, format: ExportFormat) -> NSImage {
        let icon = NSWorkspace.shared.icon(for: format.contentType)
        let preview = page?.thumbnail(of: size, for: .cropBox) ?? icon
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let scale = min(size.width / preview.size.width, size.height / preview.size.height)
        let previewSize = NSSize(width: preview.size.width * scale, height: preview.size.height * scale)
        preview.draw(in: NSRect(
            x: (size.width - previewSize.width) / 2,
            y: (size.height - previewSize.height) / 2,
            width: previewSize.width,
            height: previewSize.height
        ))

        let badgeRect = NSRect(x: size.width - 74, y: 4, width: 70, height: 30)
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 7, yRadius: 7)
        NSColor.white.setFill()
        badge.fill()
        NSColor(white: 0.7, alpha: 1).setStroke()
        badge.lineWidth = 1
        badge.stroke()
        icon.draw(in: NSRect(x: badgeRect.minX + 5, y: badgeRect.minY + 4, width: 22, height: 22))

        let label = format == .pdf ? "PDF" : "Word"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: badgeRect.minX + 30, y: badgeRect.midY - labelSize.height / 2),
            withAttributes: attributes
        )
        image.accessibilityDescription = "\(format.displayName) export"
        return image
    }
}

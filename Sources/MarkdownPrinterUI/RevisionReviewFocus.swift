import AppKit
import PDFKit
import MarkdownPrinterCore

struct RevisionReviewFocus: Equatable {
    let id: String
    let number: Int
    let destination: PDFReviewDestination
}

/// Coordinates increase downwards, independent of PDFKit's view orientation.
enum RevisionReviewScrollPlacement {
    static func targetTop(passage: CGRect, viewport: CGRect) -> CGFloat? {
        guard viewport.height > 0 else { return nil }
        let breathingRoom = min(40, viewport.height * 0.08)
        let tall = passage.height > viewport.height * 0.65
        let comfortableStart = passage.minY >= viewport.minY + breathingRoom
            && passage.minY <= viewport.minY + viewport.height * 0.6
        if comfortableStart && (tall || passage.maxY <= viewport.maxY - breathingRoom) { return nil }
        var context = viewport.height * (tall ? 0.15 : 0.25)
        if !tall { context = min(context, max(24, viewport.height - passage.height - breathingRoom)) }
        return passage.minY - context
    }

    @MainActor
    static func navigate(to destination: PDFReviewDestination, in view: PDFView) {
        guard let page = view.document?.page(at: destination.destination.pageIndex) else { return }
        // PDFKit has no settled clip geometry before window attachment.
        guard view.window != nil else {
            let target = PDFDestination(page: page, at: destination.destination.point)
            target.zoom = view.scaleFactor
            view.go(to: target)
            return
        }
        guard
              let documentView = view.documentView,
              let scroll = documentView.enclosingScrollView else { return }
        let clip = scroll.contentView
        let passage = destination.fragments.first(where: { $0.pageIndex == destination.destination.pageIndex })?.passageBounds
            ?? CGRect(x: destination.destination.point.x, y: destination.destination.point.y - 12, width: 1, height: 12)
        let rect = documentView.convert(view.convert(passage, from: page), from: view)
        let flipped = documentView.isFlipped
        func downward(_ rect: CGRect) -> CGRect {
            flipped ? rect : CGRect(x: rect.minX, y: documentView.bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        guard let top = targetTop(passage: downward(rect), viewport: downward(clip.bounds)) else { return }
        let y = flipped ? top : documentView.bounds.maxY - top - clip.bounds.height
        let proposed = CGRect(x: clip.bounds.minX, y: y, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
    }
}

/// PDFKit owns only the visible page views. The overlay never enters exported PDF data.
@MainActor
final class RevisionReviewFocusProvider: NSObject, PDFPageOverlayViewProvider {
    private(set) var focus: RevisionReviewFocus?
    private var overlays: [ObjectIdentifier: RevisionReviewFocusView] = [:]

    func update(_ focus: RevisionReviewFocus?) {
        guard self.focus != focus else { return }
        self.focus = focus
        for overlay in overlays.values { overlay.focus = focus; overlay.needsDisplay = true }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = RevisionReviewFocusView()
        overlay.pdfView = view; overlay.page = page; overlay.focus = focus
        overlay.setAccessibilityHidden(true)
        overlays[ObjectIdentifier(page)] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        if overlays[ObjectIdentifier(page)] === overlayView { overlays.removeValue(forKey: ObjectIdentifier(page)) }
    }
}

@MainActor
final class RevisionReviewFocusView: NSView {
    weak var pdfView: PDFView?
    weak var page: PDFPage?
    var focus: RevisionReviewFocus?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let view = pdfView, let page, let focus,
              let index = view.document.map({ $0.index(for: page) }),
              let fragment = focus.destination.fragments.first(where: { $0.pageIndex == index }) else { return }
        func rect(_ source: CGRect) -> CGRect { convert(view.convert(source, from: page), from: view) }
        let band = rect(fragment.bandBounds)
        let passage = rect(fragment.passageBounds)
        guard !band.isEmpty else { return }
        let amber = NSColor(calibratedRed: 0.88, green: 0.61, blue: 0.04, alpha: 1)
        let shape = NSBezierPath(roundedRect: band.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.multiply)
        NSColor(calibratedRed: 1, green: 0.87, blue: 0.35, alpha: 0.14).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        amber.withAlphaComponent(0.65).setStroke(); shape.lineWidth = 0.8; shape.stroke()
        amber.setFill()
        NSBezierPath(rect: CGRect(x: band.minX + 0.5, y: band.minY + 3, width: 2.5, height: max(0, band.height - 6))).fill()
        let diameter: CGFloat = 18
        let top = isFlipped ? passage.minY : passage.maxY - diameter
        let badge = CGRect(x: band.minX + 6,
                           y: min(max(top, band.minY + 3), max(band.minY + 3, band.maxY - diameter - 3)),
                           width: diameter, height: diameter)
        NSColor(calibratedRed: 1, green: 0.84, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let label = String(focus.number) as NSString
        let font = NSFont.systemFont(ofSize: focus.number >= 1000 ? 6 : (focus.number >= 100 ? 8 : 11), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
    }
}

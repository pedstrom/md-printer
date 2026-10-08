import AppKit
import PDFKit
import MarkdownPrinterCore

/// Observes ordinary clicks without delaying or consuming PDFKit's mouse events.
@MainActor
final class RevisionReviewClickRecognizer: NSGestureRecognizer {
    var onClick: (NSEvent) -> Void = { _ in }
    var onPress: () -> Void = {}
    var maximumClickDuration: () -> TimeInterval = { NSEvent.doubleClickInterval }
    private var press: NSEvent?
    private(set) var sequence: UInt64 = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysPrimaryMouseButtonEvents = false
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delaysPrimaryMouseButtonEvents = false
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        sequence &+= 1
        onPress()
        press = event.clickCount == 1 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty ? event : nil
    }
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        // Even a small drag belongs to native text selection or export.
        press = nil
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { press = nil }
        guard let press, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              event.timestamp - press.timestamp < maximumClickDuration(),
              hypot(event.locationInWindow.x - press.locationInWindow.x,
                    event.locationInWindow.y - press.locationInWindow.y) <= 3 else { state = .failed; return }
        state = .ended
        onClick(event)
    }
    override func reset() { super.reset(); press = nil }
    override func canPrevent(_ preventedGestureRecognizer: NSGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool { false }
}

enum RevisionReviewHitTest {
    static func item(at point: CGPoint, pageIndex: Int, items: [RevisionReviewItem], destinations: [String: PDFReviewDestination]) -> String? {
        var best: (id: String, priority: Int, area: CGFloat)?
        for item in items {
            for fragment in destinations[item.id]?.fragments ?? [] where fragment.pageIndex == pageIndex {
                let priority: Int, rect: CGRect
                if let note = fragment.noteBounds.first(where: { $0.contains(point) }) { priority = 0; rect = note }
                else if fragment.passageBounds.contains(point) {
                    priority = item.currentRange.length > 0 ? 1 : 2; rect = fragment.passageBounds
                } else if fragment.bandBounds.contains(point) { priority = 3; rect = fragment.bandBounds }
                else { continue }
                let area = rect.width * rect.height
                if best == nil || priority < best!.priority || priority == best!.priority && area < best!.area {
                    best = (item.id, priority, area)
                }
            }
        }
        return best?.id
    }
}

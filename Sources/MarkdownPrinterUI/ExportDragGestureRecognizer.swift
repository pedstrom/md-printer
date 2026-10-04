import AppKit

/// Delays PDFKit's selection handling until a click either becomes a held export
/// or fails as an ordinary click/selection gesture. Keeps the triggering mouse
/// event rather than relying on NSApp.currentEvent during delayed callbacks.
@MainActor
final class ExportDragGestureRecognizer: NSGestureRecognizer {
    var minimumPressDuration = NSEvent.doubleClickInterval
    var allowableMovement = NSPressGestureRecognizer().allowableMovement
    private(set) var mouseEvent: NSEvent?
    var onStateChanged: ((ExportDragGestureRecognizer, NSGestureRecognizer.State) -> Void)?
    private var pressLocation: NSPoint?
    private var pressTimer: Timer?
    private var isReady = false

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        delaysPrimaryMouseButtonEvents = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delaysPrimaryMouseButtonEvents = true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        mouseEvent = event
        pressLocation = event.locationInWindow
        isReady = false
        let timer = Timer(timeInterval: minimumPressDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressLocation != nil else { return }
                self.pressTimer = nil
                self.isReady = true
                self.transition(to: .began)
            }
        }
        pressTimer?.invalidate()
        pressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        mouseEvent = event
        guard let pressLocation else { return }
        if isReady {
            transition(to: .changed)
        } else {
            let location = event.locationInWindow
            if hypot(location.x - pressLocation.x, location.y - pressLocation.y) > allowableMovement {
                pressTimer?.invalidate()
                pressTimer = nil
                self.pressLocation = nil
                transition(to: .failed)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        mouseEvent = event
        guard pressLocation != nil else { return }
        pressTimer?.invalidate()
        pressTimer = nil
        transition(to: isReady ? .ended : .failed)
        pressLocation = nil
        isReady = false
    }

    override func reset() {
        if pressLocation != nil { onStateChanged?(self, .cancelled) }
        super.reset()
        pressTimer?.invalidate()
        pressTimer = nil
        pressLocation = nil
        isReady = false
        mouseEvent = nil
    }

    private func transition(to newState: NSGestureRecognizer.State) {
        state = newState
        onStateChanged?(self, newState)
    }

    override func location(in view: NSView?) -> NSPoint {
        guard let mouseEvent else { return super.location(in: view) }
        return view?.convert(mouseEvent.locationInWindow, from: nil) ?? mouseEvent.locationInWindow
    }

    // PDFKit's own selection recognizers must not defeat the export hold before
    // its timer fires. Early movement fails this recognizer and releases the
    // delayed events back to normal PDF selection handling.
    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool {
        false
    }

    deinit {
        pressTimer?.invalidate()
    }
}

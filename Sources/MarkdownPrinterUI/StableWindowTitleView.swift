import AppKit
import SwiftUI

@MainActor
protocol WindowTitleWriting: AnyObject {
    var title: String { get set }
}

extension NSWindow: WindowTitleWriting { }

@MainActor
enum StableWindowTitlePolicy {
    @discardableResult
    static func enforce(_ title: String, on window: WindowTitleWriting) -> Bool {
        guard !title.isEmpty, window.title != title else { return false }
        window.title = title
        return true
    }
}

struct StableWindowTitleView: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> StableWindowTitleHostView {
        let view = StableWindowTitleHostView()
        view.updateTitle(title)
        return view
    }

    func updateNSView(_ view: StableWindowTitleHostView, context: Context) {
        view.updateTitle(title)
    }
}

@MainActor
final class StableWindowTitleHostView: NSView {
    private var desiredTitle = "Markdown Printer"
    private weak var observedWindow: NSWindow?
    private var titleObservation: NSKeyValueObservation?
    private var isApplyingTitle = false

    deinit {
        titleObservation?.invalidate()
    }

    func updateTitle(_ title: String) {
        desiredTitle = title
        enforceTitle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeCurrentWindow()
    }

    private func observeCurrentWindow() {
        guard observedWindow !== window else {
            enforceTitle()
            return
        }
        titleObservation?.invalidate()
        titleObservation = nil
        observedWindow = window
        guard let window else { return }
        titleObservation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.enforceTitle()
            }
        }
        enforceTitle()
    }

    private func enforceTitle() {
        guard !isApplyingTitle,
              let window
        else { return }
        isApplyingTitle = true
        StableWindowTitlePolicy.enforce(desiredTitle, on: window)
        isApplyingTitle = false
    }
}

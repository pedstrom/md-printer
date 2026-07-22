import PDFKit
import SwiftUI

public struct PDFPreviewView: NSViewRepresentable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public func makeNSView(context: Context) -> PDFView {
        PageAdvancingPDFView()
    }

    public func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.dataRepresentation() != data else { return }
        guard let document = PDFDocument(data: data) else { return }
        (view as? PageAdvancingPDFView)?.display(document)
    }
}

final class PageAdvancingPDFView: PDFView {
    private var needsInitialPageFit = false
    private var displayRevision = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func display(_ document: PDFDocument) {
        self.document = document
        displayRevision += 1
        needsInitialPageFit = true
        goToFirstPage(nil)
        needsLayout = true
        focusForPageNavigation()
        scheduleSettledInitialPageFit(for: displayRevision)
    }

    override func layout() {
        super.layout()
        guard needsInitialPageFit, bounds.width > 0, bounds.height > 0 else { return }
        needsInitialPageFit = false
        fitFirstPage()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusForPageNavigation()
    }

    override func keyDown(with event: NSEvent) {
        let navigationModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.charactersIgnoringModifiers == " ", navigationModifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }
        goToNextPage(nil)
    }

    private func configure() {
        autoScales = false
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        backgroundColor = .windowBackgroundColor
    }

    private func fitFirstPage() {
        guard let firstPage = document?.page(at: 0) else { return }
        displayMode = .singlePage
        // Leave room for the page-break edge that continuous mode adds.
        let fittedScale = scaleFactorForSizeToFit * 0.99
        displayMode = .singlePageContinuous
        scaleFactor = fittedScale
        let bounds = firstPage.bounds(for: .cropBox)
        go(
            to: CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1),
            on: firstPage
        )
    }

    private func focusForPageNavigation() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    private func scheduleSettledInitialPageFit(for revision: Int) {
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayRevision == revision else { return }
                self.needsInitialPageFit = false
                self.fitFirstPage()
            }
        }
    }
}

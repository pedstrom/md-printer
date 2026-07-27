@preconcurrency import PDFKit
import SwiftUI

public struct PDFPreviewView: NSViewRepresentable {
    public let data: Data
    public let fileName: String
    private let openURL: (URL) -> Void

    public init(data: Data, fileName: String, openURL: @escaping (URL) -> Void) {
        self.data = data
        self.fileName = fileName
        self.openURL = openURL
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL)
    }

    public func makeNSView(context: Context) -> PDFView {
        let view = PageAdvancingPDFView()
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.openURL = openURL
        (view as? PageAdvancingPDFView)?.updateDragPayload(data: data, fileName: fileName)
        guard view.document?.dataRepresentation() != data else { return }
        guard let document = PDFDocument(data: data) else { return }
        (view as? PageAdvancingPDFView)?.display(document)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var openURL: (URL) -> Void

        init(openURL: @escaping (URL) -> Void) {
            self.openURL = openURL
        }
    }
}

extension PDFPreviewView.Coordinator: @preconcurrency PDFViewDelegate {
    public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        openURL(url)
    }
}

final class PageAdvancingPDFView: PDFView, NSDraggingSource {
    private var needsInitialPageFit = false
    private var displayRevision = 0
    private var fittedViewWidth: CGFloat?
    private var dragData: Data?
    private var dragFileName = "Untitled.pdf"
    private var isDraggingPDF = false
    private(set) lazy var outboundPDFDragRecognizer: NSPressGestureRecognizer = {
        let recognizer = NSPressGestureRecognizer(target: self, action: #selector(handleOutboundPDFDrag(_:)))
        recognizer.buttonMask = 0x1
        return recognizer
    }()

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
        fittedViewWidth = nil
        goToFirstPage(nil)
        needsLayout = true
        focusForPageNavigation()
        scheduleSettledInitialPageFit(for: displayRevision)
    }

    func updateDragPayload(data: Data, fileName: String) {
        dragData = data
        dragFileName = fileName
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if needsInitialPageFit {
            needsInitialPageFit = false
            fitFirstPage()
            fittedViewWidth = bounds.width
        } else if let fittedViewWidth, abs(fittedViewWidth - bounds.width) > 0.5 {
            self.fittedViewWidth = bounds.width
            fitPageWidth()
        }
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

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDraggingPDF = false
    }

    private func configure() {
        autoScales = false
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        backgroundColor = .windowBackgroundColor
        addGestureRecognizer(outboundPDFDragRecognizer)
    }

    @objc
    private func handleOutboundPDFDrag(_ recognizer: NSPressGestureRecognizer) {
        guard recognizer.state == .changed,
              !isDraggingPDF,
              let dragData,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged
        else {
            return
        }

        let writer = PDFFilePromiseWriter(pdfData: dragData, fileName: dragFileName)
        let provider = writer.makeProvider()
        let draggingItem = NSDraggingItem(pasteboardWriter: provider)
        let image = dragThumbnail()
        let location = recognizer.location(in: self)
        draggingItem.setDraggingFrame(
            NSRect(
                x: location.x - image.size.width / 2,
                y: location.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ),
            contents: image
        )

        isDraggingPDF = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func dragThumbnail() -> NSImage {
        let size = NSSize(width: 110, height: 142)
        guard let firstPage = document?.page(at: 0) else {
            let icon = NSWorkspace.shared.icon(for: .pdf)
            icon.size = size
            return icon
        }
        return firstPage.thumbnail(of: size, for: .cropBox)
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

    private func fitPageWidth() {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: .cropBox).width
        guard pageWidth > 0 else { return }
        // Keep a modest gutter for PDFKit's page edge and vertical scroller.
        scaleFactor = max(bounds.width - 64, 1) / pageWidth
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
                self.fittedViewWidth = self.bounds.width
            }
        }
    }
}

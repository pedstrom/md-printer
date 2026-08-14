@preconcurrency import PDFKit
import MarkdownPrinterCore
import QuartzCore
import SwiftUI

public struct PDFPreviewView: NSViewRepresentable {
    public let data: Data
    public let revision: UInt64
    public let exportFormat: ExportFormat
    public let fileName: String
    private let exportData: () throws -> Data
    private let openURL: (URL) -> Void
    private let onDragError: (Error) -> Void

    public init(
        data: Data,
        revision: UInt64 = 0,
        exportFormat: ExportFormat,
        fileName: String,
        exportData: @escaping () throws -> Data,
        openURL: @escaping (URL) -> Void,
        onDragError: @escaping (Error) -> Void = { _ in }
    ) {
        self.data = data
        self.revision = revision
        self.exportFormat = exportFormat
        self.fileName = fileName
        self.exportData = exportData
        self.openURL = openURL
        self.onDragError = onDragError
    }

    public init(
        data: Data,
        revision: UInt64 = 0,
        fileName: String,
        openURL: @escaping (URL) -> Void,
        onDragError: @escaping (Error) -> Void = { _ in }
    ) {
        self.init(
            data: data,
            revision: revision,
            exportFormat: .pdf,
            fileName: fileName,
            exportData: { data },
            openURL: openURL,
            onDragError: onDragError
        )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL, onDragError: onDragError)
    }

    public func makeNSView(context: Context) -> BufferedPDFPreviewView {
        let view = BufferedPDFPreviewView()
        view.delegate = context.coordinator
        return view
    }

    public func updateNSView(_ view: BufferedPDFPreviewView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.onDragError = onDragError
        view.delegate = context.coordinator
        view.updateDragPayload(
            format: exportFormat,
            fileName: fileName,
            dataProvider: exportData,
            onError: context.coordinator.reportDragError
        )
        guard let document = PDFDocument(data: data) else { return }
        view.display(document, data: data, revision: revision)
    }

    @MainActor
    public final class Coordinator: NSObject {
        var openURL: (URL) -> Void
        var onDragError: (Error) -> Void

        init(openURL: @escaping (URL) -> Void, onDragError: @escaping (Error) -> Void) {
            self.openURL = openURL
            self.onDragError = onDragError
        }

        func reportDragError(_ error: Error) {
            onDragError(error)
        }
    }
}

extension PDFPreviewView.Coordinator: @preconcurrency PDFViewDelegate {
    public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        openURL(url)
    }
}

struct PreviewViewport {
    struct TextAnchor: Equatable {
        let text: String
        let documentProgress: CGFloat
        let viewportTopFraction: CGFloat
    }

    let scaleFactor: CGFloat
    let pageIndex: Int
    let normalizedPagePoint: CGPoint
    let documentProgress: CGFloat
    let textAnchors: [TextAnchor]

    static func capture(from view: PDFView) -> PreviewViewport? {
        guard let document = view.document,
              document.pageCount > 0,
              let currentPage = view.currentDestination?.page ?? view.currentPage
        else { return nil }

        let pageIndex = max(document.index(for: currentPage), 0)
        let pageBounds = currentPage.bounds(for: .cropBox)
        let point = view.currentDestination?.point
            ?? CGPoint(x: pageBounds.minX, y: pageBounds.maxY)
        let normalizedPoint = CGPoint(
            x: normalized(point.x, minimum: pageBounds.minX, length: pageBounds.width),
            y: normalized(point.y, minimum: pageBounds.minY, length: pageBounds.height)
        )
        let progressWithinPage = 1 - normalizedPoint.y
        let documentProgress = clamped(
            (CGFloat(pageIndex) + progressWithinPage) / CGFloat(document.pageCount)
        )

        return PreviewViewport(
            scaleFactor: view.scaleFactor,
            pageIndex: pageIndex,
            normalizedPagePoint: normalizedPoint,
            documentProgress: documentProgress,
            textAnchors: visibleTextAnchors(
                in: view,
                document: document,
                currentPageIndex: pageIndex
            )
        )
    }

    func restore(in view: PDFView) {
        guard let document = view.document, document.pageCount > 0 else { return }
        if scaleFactor.isFinite, scaleFactor > 0 {
            view.scaleFactor = scaleFactor
        }

        if let resolvedAnchor = resolvedTextAnchor(in: document) {
            scroll(to: resolvedAnchor.selection, anchor: resolvedAnchor.anchor, in: view)
            return
        }

        let targetPageIndex: Int
        if pageIndex < document.pageCount {
            targetPageIndex = pageIndex
        } else {
            targetPageIndex = min(
                max(Int(documentProgress * CGFloat(document.pageCount)), 0),
                document.pageCount - 1
            )
        }
        guard let page = document.page(at: targetPageIndex) else { return }
        let bounds = page.bounds(for: .cropBox)
        let point = CGPoint(
            x: bounds.minX + normalizedPagePoint.x * bounds.width,
            y: bounds.minY + normalizedPagePoint.y * bounds.height
        )
        go(to: point, on: page, in: view)
    }

    private func resolvedTextAnchor(
        in document: PDFDocument
    ) -> (anchor: TextAnchor, selection: PDFSelection)? {
        var best: (anchor: TextAnchor, selection: PDFSelection, distance: CGFloat)?
        for anchor in textAnchors {
            let matches = document.findString(
                anchor.text,
                withOptions: [.caseInsensitive, .diacriticInsensitive]
            )
            for selection in matches {
                let progress = Self.documentProgress(of: selection, in: document)
                let distance = abs(progress - anchor.documentProgress)
                if best == nil || distance < best!.distance {
                    best = (anchor, selection, distance)
                }
            }
        }
        return best.map { ($0.anchor, $0.selection) }
    }

    private func scroll(to selection: PDFSelection, anchor: TextAnchor, in view: PDFView) {
        guard let page = selection.pages.first else { return }
        let pageBounds = page.bounds(for: .cropBox)
        let selectionBounds = selection.bounds(for: page)
        let viewportHeightInPage = view.bounds.height / max(view.scaleFactor, 0.01)
        let targetY = min(
            max(
                selectionBounds.maxY + anchor.viewportTopFraction * viewportHeightInPage,
                pageBounds.minY
            ),
            pageBounds.maxY
        )
        let targetX = pageBounds.minX + normalizedPagePoint.x * pageBounds.width
        go(to: CGPoint(x: targetX, y: targetY), on: page, in: view)
    }

    private func go(to point: CGPoint, on page: PDFPage, in view: PDFView) {
        let destination = PDFDestination(page: page, at: point)
        destination.zoom = view.scaleFactor
        view.go(to: destination)
    }

    private static func visibleTextAnchors(
        in view: PDFView,
        document: PDFDocument,
        currentPageIndex: Int
    ) -> [TextAnchor] {
        let visibleBounds = view.bounds
        guard visibleBounds.width > 0, visibleBounds.height > 0 else { return [] }
        let lowerIndex = max(currentPageIndex - 2, 0)
        let upperIndex = min(currentPageIndex + 2, document.pageCount - 1)
        var anchors: [TextAnchor] = []
        var seenText = Set<String>()

        for index in lowerIndex...upperIndex {
            guard let page = document.page(at: index) else { continue }
            let pageFrame = view.convert(page.bounds(for: .cropBox), from: page)
            let visiblePageFrame = pageFrame.intersection(visibleBounds)
            guard !visiblePageFrame.isNull,
                  visiblePageFrame.width > 0,
                  visiblePageFrame.height > 0
            else { continue }

            let pageSelectionBounds = view.convert(visiblePageFrame, to: page)
            guard let selection = page.selection(for: pageSelectionBounds) else { continue }
            for lineSelection in selection.selectionsByLine() {
                let text = anchorText(from: lineSelection.string)
                guard text.count >= 8, seenText.insert(text).inserted else { continue }
                let lineBounds = view.convert(lineSelection.bounds(for: page), from: page)
                let fractionFromTop: CGFloat
                if view.isFlipped {
                    fractionFromTop = (lineBounds.minY - visibleBounds.minY) / visibleBounds.height
                } else {
                    fractionFromTop = (visibleBounds.maxY - lineBounds.maxY) / visibleBounds.height
                }
                anchors.append(TextAnchor(
                    text: text,
                    documentProgress: documentProgress(of: lineSelection, in: document),
                    viewportTopFraction: clamped(fractionFromTop)
                ))
            }
        }

        return anchors
            .sorted { $0.viewportTopFraction < $1.viewportTopFraction }
            .prefix(8)
            .map { $0 }
    }

    private static func anchorText(from string: String?) -> String {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(trimmed.prefix(160))
    }

    private static func documentProgress(
        of selection: PDFSelection,
        in document: PDFDocument
    ) -> CGFloat {
        guard let page = selection.pages.first else { return 0 }
        let index = max(document.index(for: page), 0)
        let pageBounds = page.bounds(for: .cropBox)
        let selectionBounds = selection.bounds(for: page)
        let withinPage = clamped(
            (pageBounds.maxY - selectionBounds.maxY) / max(pageBounds.height, 1)
        )
        return clamped((CGFloat(index) + withinPage) / CGFloat(max(document.pageCount, 1)))
    }

    private static func normalized(_ value: CGFloat, minimum: CGFloat, length: CGFloat) -> CGFloat {
        clamped((value - minimum) / max(length, 1))
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

@MainActor
public final class BufferedPDFPreviewView: NSView {
    private let firstView: PageAdvancingPDFView
    private let secondView: PageAdvancingPDFView
    private var pendingCommit: DispatchWorkItem?
    private var requestSequence: UInt64 = 0
    private(set) var activeView: PageAdvancingPDFView
    private(set) var activeRevision: UInt64?
    private(set) var activeData: Data?

    var delegate: PDFViewDelegate? {
        didSet {
            firstView.delegate = delegate
            secondView.delegate = delegate
        }
    }

    public override init(frame frameRect: NSRect) {
        let firstView = PageAdvancingPDFView(frame: frameRect)
        let secondView = PageAdvancingPDFView(frame: frameRect)
        self.firstView = firstView
        self.secondView = secondView
        self.activeView = firstView
        super.init(frame: frameRect)
        wantsLayer = true
        firstView.automaticallyTakesFocus = true
        secondView.automaticallyTakesFocus = false
        secondView.isHidden = true
        addSubview(secondView)
        addSubview(firstView, positioned: .above, relativeTo: secondView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        firstView.frame = bounds
        secondView.frame = bounds
    }

    func display(_ document: PDFDocument, data: Data, revision: UInt64) {
        guard activeData != data else {
            activeRevision = revision
            return
        }

        requestSequence &+= 1
        let requestedSequence = requestSequence
        pendingCommit?.cancel()

        guard activeView.document != nil else {
            activeData = data
            activeRevision = revision
            activeView.displayInitial(document)
            return
        }

        let viewport = PreviewViewport.capture(from: activeView)
        let stagedView = inactiveView
        stagedView.automaticallyTakesFocus = false
        stagedView.isHidden = false
        addSubview(stagedView, positioned: .below, relativeTo: activeView)
        stagedView.displayReplacement(document, viewport: viewport)
        stagedView.layoutSubtreeIfNeeded()
        viewport?.restore(in: stagedView)
        stagedView.displayIfNeededIgnoringOpacity()

        let workItem = DispatchWorkItem { [weak self, weak stagedView] in
            guard let self,
                  let stagedView,
                  self.requestSequence == requestedSequence,
                  self.inactiveView === stagedView
            else { return }
            stagedView.layoutSubtreeIfNeeded()
            viewport?.restore(in: stagedView)
            stagedView.displayIfNeededIgnoringOpacity()
            self.commitStagedView(
                stagedView,
                data: data,
                revision: revision,
                requestedSequence: requestedSequence
            )
        }
        pendingCommit = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func updateDragPayload(
        format: ExportFormat,
        fileName: String,
        dataProvider: @escaping () throws -> Data,
        onError: @escaping (Error) -> Void
    ) {
        firstView.updateDragPayload(
            format: format,
            fileName: fileName,
            dataProvider: dataProvider,
            onError: onError
        )
        secondView.updateDragPayload(
            format: format,
            fileName: fileName,
            dataProvider: dataProvider,
            onError: onError
        )
    }

    private var inactiveView: PageAdvancingPDFView {
        activeView === firstView ? secondView : firstView
    }

    private func commitStagedView(
        _ stagedView: PageAdvancingPDFView,
        data: Data,
        revision: UInt64,
        requestedSequence: UInt64
    ) {
        guard requestSequence == requestedSequence else { return }
        let previousView = activeView
        let focusedView = window?.firstResponder as? NSView
        let shouldTransferFocus = focusedView === previousView
            || focusedView?.isDescendant(of: previousView) == true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            stagedView.isHidden = false
            addSubview(stagedView, positioned: .above, relativeTo: previousView)
            previousView.isHidden = true
        }
        CATransaction.commit()

        previousView.automaticallyTakesFocus = false
        stagedView.automaticallyTakesFocus = true
        activeView = stagedView
        activeData = data
        activeRevision = revision
        pendingCommit = nil
        if shouldTransferFocus {
            window?.makeFirstResponder(stagedView)
        }
    }
}

final class PageAdvancingPDFView: PDFView, NSDraggingSource {
    private var needsInitialPageFit = false
    private var displayRevision = 0
    private var fittedViewWidth: CGFloat?
    private var dragDataProvider: (() throws -> Data)?
    private var dragFormat = ExportFormat.pdf
    private var dragFileName = "Untitled.pdf"
    private var dragErrorHandler: ((Error) -> Void)?
    private lazy var dragFileStore = ExportDragFileStore()
    private var activeDragArtifact: ExportDragArtifact?
    private var isDraggingExport = false
    var automaticallyTakesFocus = true
    private(set) lazy var outboundExportDragRecognizer: NSPressGestureRecognizer = {
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

    func displayInitial(_ document: PDFDocument) {
        self.document = document
        displayRevision += 1
        needsInitialPageFit = true
        fittedViewWidth = nil
        goToFirstPage(nil)
        needsLayout = true
        focusForPageNavigation()
        scheduleSettledInitialPageFit(for: displayRevision)
    }

    func display(_ document: PDFDocument) {
        displayInitial(document)
    }

    func displayReplacement(_ document: PDFDocument, viewport: PreviewViewport?) {
        self.document = document
        displayRevision += 1
        needsInitialPageFit = false
        fittedViewWidth = bounds.width
        if let viewport, viewport.scaleFactor.isFinite, viewport.scaleFactor > 0 {
            scaleFactor = viewport.scaleFactor
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        viewport?.restore(in: self)
    }

    func updateDragPayload(
        format: ExportFormat,
        fileName: String,
        dataProvider: @escaping () throws -> Data,
        onError: @escaping (Error) -> Void
    ) {
        dragFormat = format
        dragFileName = fileName
        dragDataProvider = dataProvider
        dragErrorHandler = onError
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
        if let activeDragArtifact {
            dragFileStore.finish(activeDragArtifact, operation: operation)
            self.activeDragArtifact = nil
        }
        isDraggingExport = false
    }

    private func configure() {
        autoScales = false
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        backgroundColor = .windowBackgroundColor
        addGestureRecognizer(outboundExportDragRecognizer)
    }

    @objc
    private func handleOutboundPDFDrag(_ recognizer: NSPressGestureRecognizer) {
        guard recognizer.state == .changed,
              !isDraggingExport,
              let dragDataProvider,
              let event = NSApp.currentEvent,
              event.type == .leftMouseDragged
        else {
            return
        }

        let artifact: ExportDragArtifact
        do {
            artifact = try dragFileStore.materialize(
                data: dragDataProvider(),
                fileName: dragFileName
            )
        } catch {
            dragErrorHandler?(error)
            return
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: artifact.fileURL as NSURL)
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

        activeDragArtifact = artifact
        isDraggingExport = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func dragThumbnail() -> NSImage {
        let size = NSSize(width: 110, height: 142)
        guard dragFormat == .pdf else {
            let icon = NSWorkspace.shared.icon(for: dragFormat.contentType)
            icon.size = size
            return icon
        }
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
        let fittedScale = scaleFactorForSizeToFit * 0.99
        displayMode = .singlePageContinuous
        scaleFactor = fittedScale
        let bounds = firstPage.bounds(for: .cropBox)
        let destination = PDFDestination(
            page: firstPage,
            at: CGPoint(x: bounds.minX, y: bounds.maxY)
        )
        destination.zoom = fittedScale
        go(to: destination)
    }

    private func fitPageWidth() {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        let pageWidth = page.bounds(for: .cropBox).width
        guard pageWidth > 0 else { return }
        scaleFactor = max(bounds.width - 64, 1) / pageWidth
    }

    private func focusForPageNavigation() {
        guard automaticallyTakesFocus, let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  self.automaticallyTakesFocus,
                  let window,
                  self.window === window
            else { return }
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

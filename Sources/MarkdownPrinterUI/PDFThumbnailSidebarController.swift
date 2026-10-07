import AppKit
import Combine
import PDFKit

@MainActor
private final class ThumbnailSplitView: NSSplitView {
    var hidesDivider = false {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    override var dividerThickness: CGFloat {
        hidesDivider ? 0 : super.dividerThickness
    }

    override func drawDivider(in rect: NSRect) {
        guard !hidesDivider else { return }
        super.drawDivider(in: rect)
    }

}

@MainActor
protocol PDFThumbnailSidebarTarget: AnyObject {
    var isThumbnailSidebarVisible: Bool { get }
    var thumbnailSidebarWidth: CGFloat { get }
    func setThumbnailSidebarVisible(_ isVisible: Bool)
}

@MainActor
package final class PDFSidebarController: ObservableObject {
    @Published public private(set) var commandTitle = "Show Sidebar"
    @Published public private(set) var canToggle = false
    @Published public private(set) var isVisible = false

    private weak var target: PDFThumbnailSidebarTarget?

    package init() {}

    func attach(to target: PDFThumbnailSidebarTarget) {
        self.target = target
        refresh()
    }

    func detach(from target: PDFThumbnailSidebarTarget) {
        guard self.target === target else { return }
        self.target = nil
        refresh()
    }

    func detachForDismantling(from target: PDFThumbnailSidebarTarget) {
        guard self.target === target else { return }
        self.target = nil
        // Publishing inside dismantleNSView re-enters SwiftUI's graph destruction.
        Task { @MainActor [weak self] in
            guard let self, self.target == nil else { return }
            self.refresh()
        }
    }

    package func toggle() {
        guard let target else { return }
        target.setThumbnailSidebarVisible(!target.isThumbnailSidebarVisible)
        refresh()
    }

    func targetDidChange() {
        refresh()
    }

    private func refresh() {
        canToggle = target != nil
        isVisible = target?.isThumbnailSidebarVisible == true
        commandTitle = isVisible ? "Hide Sidebar" : "Show Sidebar"
    }
}

package typealias PDFThumbnailSidebarController = PDFSidebarController

@MainActor
public final class PDFPreviewContainerView: NSView, NSSplitViewDelegate, PDFThumbnailSidebarTarget {
    static let defaultSidebarWidth: CGFloat = 168
    static let minimumSidebarWidth: CGFloat = 120
    static let maximumSidebarWidth: CGFloat = 260
    static let sidebarCollapseThreshold: CGFloat = 72

    let previewView: BufferedPDFPreviewView
    let thumbnailView: PDFThumbnailView
    private let splitView = ThumbnailSplitView()
    private let sidebarView = NSView()
    private weak var sidebarController: PDFSidebarController?
    private var sidebarIsShown = false
    private var storedSidebarWidth = defaultSidebarWidth
    let reviewController = RevisionReviewController()
    private lazy var changesView = RevisionChangesView(controller: reviewController)
    private let modeSelector = NSSegmentedControl(labels: ["Pages", "Changes"], trackingMode: .selectOne, target: nil, action: nil)
    private var lastReviewRevision: UInt64?
    var sidebarMode: DocumentSidebarMode { reviewController.state.mode }
    private var isApplyingSidebarLayout = false
    private var lastSplitWidth: CGFloat = 0

    var isThumbnailSidebarVisible: Bool {
        sidebarIsShown
    }

    var thumbnailSidebarWidth: CGFloat {
        storedSidebarWidth
    }

    var sidebarDividerThickness: CGFloat {
        splitView.dividerThickness
    }

    var sidebarDividerHitThickness: CGFloat {
        self.splitView(
            splitView,
            effectiveRect: NSRect(
                x: 0,
                y: 0,
                width: splitView.dividerThickness,
                height: 100
            ),
            forDrawnRect: NSRect(x: 0, y: 0, width: splitView.dividerThickness, height: 100),
            ofDividerAt: 0
        ).width
    }

    func captureThumbnailRestorationState() -> PersistedThumbnailSidebar {
        PersistedThumbnailSidebar(
            isVisible: isThumbnailSidebarVisible,
            width: Double(storedSidebarWidth),
            scrollOffset: Double(max(thumbnailView.visibleRect.minY, 0))
        )
    }

    func restoreThumbnailRestorationState(_ state: PersistedThumbnailSidebar) {
        setThumbnailSidebarWidth(CGFloat(state.width))
        setThumbnailSidebarVisible(state.isVisible)
        guard state.isVisible else { return }
        DispatchQueue.main.async { [weak self] in
            self?.thumbnailView.scroll(
                NSPoint(x: 0, y: CGFloat(state.scrollOffset))
            )
        }
    }

    override init(frame frameRect: NSRect) {
        previewView = BufferedPDFPreviewView(frame: frameRect)
        thumbnailView = PDFThumbnailView(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.defaultSidebarWidth,
            height: frameRect.height
        ))
        super.init(frame: frameRect)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.autoresizingMask = [.width, .height]
        splitView.frame = bounds

        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        thumbnailView.autoresizingMask = [.width, .height]
        layoutSidebar()
        thumbnailView.backgroundColor = .windowBackgroundColor
        sidebarView.addSubview(thumbnailView)
        sidebarView.addSubview(changesView)
        sidebarView.addSubview(modeSelector)
        modeSelector.target = self; modeSelector.action = #selector(modeChanged)
        modeSelector.setAccessibilityLabel("Sidebar mode")
        modeSelector.selectedSegment = 0; modeSelector.setEnabled(false, forSegment: 1)
        changesView.isHidden = true
        reviewController.navigate = { [weak self] id, revision, destination in
            self?.previewView.navigateReview(id: id, revision: revision, destination: destination)
        }

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(previewView)
        addSubview(splitView)
        sidebarView.isHidden = true
        splitView.hidesDivider = true

        previewView.activeViewDidChange = { [weak self] activeView in
            self?.thumbnailView.pdfView = activeView
            self?.updateThumbnailSize()
        }
        thumbnailView.pdfView = previewView.activeView
        updateThumbnailSize()
    }

    required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    public override func layout() {
        isApplyingSidebarLayout = true
        super.layout()
        splitView.frame = bounds
        lastSplitWidth = splitView.bounds.width
        layoutSidebar()
        isApplyingSidebarLayout = false
        updateThumbnailSize()
        if isThumbnailSidebarVisible, !isApplyingSidebarLayout {
            applyStoredSidebarWidth()
        }
    }

    func attach(sidebarController: PDFSidebarController?) {
        guard self.sidebarController !== sidebarController else { return }
        if let existing = self.sidebarController {
            existing.detach(from: self)
        }
        self.sidebarController = sidebarController
        sidebarController?.attach(to: self)
    }

    func prepareForDismantling() {
        if let sidebarController {
            sidebarController.detachForDismantling(from: self)
        }
        sidebarController = nil
        previewView.prepareForDismantling()
        thumbnailView.pdfView = nil
    }

    func setThumbnailSidebarVisible(_ isVisible: Bool) {
        guard isThumbnailSidebarVisible != isVisible else { return }
        isApplyingSidebarLayout = true
        sidebarIsShown = isVisible
        splitView.hidesDivider = !isVisible
        sidebarView.isHidden = !isVisible
        splitView.adjustSubviews()
        isApplyingSidebarLayout = false
        if isVisible {
            applyStoredSidebarWidth()
        }
        sidebarController?.targetDidChange()
    }

    func setThumbnailSidebarWidth(_ width: CGFloat) {
        storedSidebarWidth = min(max(width, Self.minimumSidebarWidth), Self.maximumSidebarWidth)
        if isThumbnailSidebarVisible {
            applyStoredSidebarWidth()
        }
        sidebarController?.targetDidChange()
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0 else { return proposedPosition }
        if proposedPosition < Self.sidebarCollapseThreshold {
            return 0
        }
        if sidebarMode == .changes {
            return min(max(proposedPosition, 240), min(520, max(0, splitView.bounds.width - 161)))
        }
        return min(max(proposedPosition, Self.minimumSidebarWidth), Self.maximumSidebarWidth)
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === sidebarView
    }

    public func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        guard !self.splitView.hidesDivider else { return .zero }
        return proposedEffectiveRect.insetBy(dx: -6, dy: 0)
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingSidebarLayout else { return }
        let windowResized = lastSplitWidth != splitView.bounds.width
        lastSplitWidth = splitView.bounds.width
        if windowResized {
            if isThumbnailSidebarVisible { applyStoredSidebarWidth() }
            else { layoutSidebar() }
            return
        }
        if sidebarView.frame.width < 1 {
            if NSApp.currentEvent?.type == .leftMouseDragged {
                setThumbnailSidebarVisible(false)
            }
            return
        }
        guard isThumbnailSidebarVisible else { return }
        if !windowResized, sidebarMode == .pages, (Self.minimumSidebarWidth...Self.maximumSidebarWidth).contains(sidebarView.frame.width) {
            storedSidebarWidth = sidebarView.frame.width
        } else if !windowResized, sidebarMode == .changes, (240...520).contains(sidebarView.frame.width),
                  splitView.bounds.width - 161 >= reviewController.state.changesWidth {
            reviewController.state.changesWidth = sidebarView.frame.width
        }
        layoutSidebar()
        updateThumbnailSize()
        sidebarController?.targetDidChange()
    }

    private func applyStoredSidebarWidth() {
        guard splitView.arrangedSubviews.count == 2, splitView.bounds.width > 0 else { return }
        isApplyingSidebarLayout = true
        let requested = sidebarMode == .pages ? storedSidebarWidth : reviewController.state.changesWidth
        let actual = sidebarMode == .pages ? requested : min(requested, max(0, splitView.bounds.width - 161))
        sidebarView.isHidden = false
        splitView.setPosition(actual, ofDividerAt: 0)
        isApplyingSidebarLayout = false
        layoutSidebar()
        updateThumbnailSize()
    }

    private func layoutSidebar() {
        let size = sidebarView.bounds.size
        modeSelector.frame = NSRect(x: 8, y: max(0, size.height - 34), width: max(0, size.width - 16), height: 26)
        let content = NSRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 40))
        let changed = changesView.frame != content
        thumbnailView.frame = content; changesView.frame = content
        if changed { changesView.needsLayout = true }
    }

    @objc private func modeChanged() {
        setSidebarMode(modeSelector.selectedSegment == 1 ? .changes : .pages)
    }

    func setSidebarMode(_ mode: DocumentSidebarMode) {
        guard mode != .changes || reviewController.baseline != nil else { return }
        reviewController.state.mode = mode
        modeSelector.selectedSegment = mode == .pages ? 0 : 1
        thumbnailView.isHidden = mode != .pages; changesView.isHidden = mode != .changes
        if isThumbnailSidebarVisible { applyStoredSidebarWidth() }
        sidebarController?.targetDidChange()
    }

    func updateReview(_ snapshot: RenderedDocumentSnapshot) {
        guard lastReviewRevision != snapshot.revision else { return }
        if !reviewController.restorationPending { changesView.captureScrollPositions() }
        reviewController.state.isVisible = isThumbnailSidebarVisible
        reviewController.update(snapshot)
        lastReviewRevision = snapshot.revision
        modeSelector.setEnabled(snapshot.baseline != nil, forSegment: 1)
        setSidebarMode(reviewController.state.mode)
        setThumbnailSidebarVisible(reviewController.state.isVisible)
        changesView.refresh()
    }

    func captureSidebarRestorationState() -> PersistedDocumentSidebar {
        changesView.captureScrollPositions()
        reviewController.state.isVisible = isThumbnailSidebarVisible
        reviewController.state.pagesWidth = storedSidebarWidth
        return reviewController.state
    }

    func restoreSidebarRestorationState(_ state: PersistedDocumentSidebar) {
        storedSidebarWidth = state.pagesWidth
        reviewController.restore(state)
        setThumbnailSidebarVisible(state.isVisible)
        // The selected mode and detail positions are applied once the restored comparison commits.
        lastReviewRevision = nil
    }

    private func updateThumbnailSize() {
        let width = max(sidebarView.bounds.width - 24, Self.minimumSidebarWidth - 24)
        let firstPageBounds = thumbnailView.pdfView?.document?.page(at: 0)?.bounds(for: .mediaBox)
        let aspectRatio: CGFloat
        if let firstPageBounds, firstPageBounds.width > 0 {
            aspectRatio = firstPageBounds.height / firstPageBounds.width
        } else {
            aspectRatio = 11 / 8.5
        }
        thumbnailView.thumbnailSize = NSSize(width: width, height: width * aspectRatio)
    }
}

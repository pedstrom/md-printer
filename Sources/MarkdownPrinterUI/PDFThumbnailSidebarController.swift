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
package final class PDFThumbnailSidebarController: ObservableObject {
    @Published public private(set) var commandTitle = "Show Thumbnails"
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
        commandTitle = isVisible ? "Hide Thumbnails" : "Show Thumbnails"
    }
}

@MainActor
public final class PDFPreviewContainerView: NSView, NSSplitViewDelegate, PDFThumbnailSidebarTarget {
    static let defaultSidebarWidth: CGFloat = 168
    static let minimumSidebarWidth: CGFloat = 120
    static let maximumSidebarWidth: CGFloat = 260

    let previewView: BufferedPDFPreviewView
    let thumbnailView: PDFThumbnailView
    private let splitView = ThumbnailSplitView()
    private let sidebarView = NSView()
    private weak var sidebarController: PDFThumbnailSidebarController?
    private var storedSidebarWidth = defaultSidebarWidth
    private var isApplyingSidebarLayout = false

    var isThumbnailSidebarVisible: Bool {
        !sidebarView.isHidden
    }

    var thumbnailSidebarWidth: CGFloat {
        storedSidebarWidth
    }

    var sidebarDividerThickness: CGFloat {
        splitView.dividerThickness
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
        thumbnailView.frame = sidebarView.bounds
        thumbnailView.backgroundColor = .windowBackgroundColor
        sidebarView.addSubview(thumbnailView)

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

    public override func layout() {
        super.layout()
        splitView.frame = bounds
        thumbnailView.frame = sidebarView.bounds
        updateThumbnailSize()
        if isThumbnailSidebarVisible, !isApplyingSidebarLayout {
            applyStoredSidebarWidth()
        }
    }

    func attach(sidebarController: PDFThumbnailSidebarController?) {
        guard self.sidebarController !== sidebarController else { return }
        if let existing = self.sidebarController {
            existing.detach(from: self)
        }
        self.sidebarController = sidebarController
        sidebarController?.attach(to: self)
    }

    func prepareForDismantling() {
        if let sidebarController {
            sidebarController.detach(from: self)
        }
        sidebarController = nil
        previewView.prepareForDismantling()
        thumbnailView.pdfView = nil
    }

    func setThumbnailSidebarVisible(_ isVisible: Bool) {
        guard isThumbnailSidebarVisible != isVisible else { return }
        splitView.hidesDivider = !isVisible
        sidebarView.isHidden = !isVisible
        splitView.adjustSubviews()
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
        return min(max(proposedPosition, Self.minimumSidebarWidth), Self.maximumSidebarWidth)
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isApplyingSidebarLayout, isThumbnailSidebarVisible else { return }
        storedSidebarWidth = min(
            max(sidebarView.frame.width, Self.minimumSidebarWidth),
            Self.maximumSidebarWidth
        )
        thumbnailView.frame = sidebarView.bounds
        updateThumbnailSize()
        sidebarController?.targetDidChange()
    }

    private func applyStoredSidebarWidth() {
        guard splitView.arrangedSubviews.count == 2, splitView.bounds.width > 0 else { return }
        isApplyingSidebarLayout = true
        splitView.setPosition(storedSidebarWidth, ofDividerAt: 0)
        isApplyingSidebarLayout = false
        thumbnailView.frame = sidebarView.bounds
        updateThumbnailSize()
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

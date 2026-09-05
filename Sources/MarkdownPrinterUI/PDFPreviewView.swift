@preconcurrency import PDFKit
import MarkdownPrinterCore
import QuartzCore
import SwiftUI

public struct PDFPreviewView: NSViewRepresentable {
    @Environment(\.documentWindowRestorationCoordinator) private var windowRestorationCoordinator

    public let data: Data
    public let revision: UInt64
    public let exportFormat: ExportFormat
    public let fileName: String
    private let exportData: () throws -> Data
    private let openURL: (URL) -> Void
    private let remoteImageSources: [String]
    private let onDownloadRemoteImage: (String) -> Void
    private let onDownloadAllRemoteImages: () -> Void
    private let onDragError: (Error) -> Void
    private let searchController: PDFSearchController?
    private let viewingController: PDFViewingController?
    private let sidebarController: PDFThumbnailSidebarController?

    public init(
        data: Data,
        revision: UInt64 = 0,
        exportFormat: ExportFormat,
        fileName: String,
        exportData: @escaping () throws -> Data,
        openURL: @escaping (URL) -> Void,
        remoteImageSources: [String] = [],
        onDownloadRemoteImage: @escaping (String) -> Void = { _ in },
        onDownloadAllRemoteImages: @escaping () -> Void = {},
        onDragError: @escaping (Error) -> Void = { _ in }
    ) {
        self.init(
            data: data,
            revision: revision,
            exportFormat: exportFormat,
            fileName: fileName,
            searchController: nil,
            viewingController: nil,
            sidebarController: nil,
            exportData: exportData,
            openURL: openURL,
            remoteImageSources: remoteImageSources,
            onDownloadRemoteImage: onDownloadRemoteImage,
            onDownloadAllRemoteImages: onDownloadAllRemoteImages,
            onDragError: onDragError
        )
    }

    init(
        data: Data,
        revision: UInt64 = 0,
        exportFormat: ExportFormat,
        fileName: String,
        searchController: PDFSearchController,
        viewingController: PDFViewingController,
        sidebarController: PDFThumbnailSidebarController,
        exportData: @escaping () throws -> Data,
        openURL: @escaping (URL) -> Void,
        remoteImageSources: [String] = [],
        onDownloadRemoteImage: @escaping (String) -> Void = { _ in },
        onDownloadAllRemoteImages: @escaping () -> Void = {},
        onDragError: @escaping (Error) -> Void = { _ in }
    ) {
        self.init(
            data: data,
            revision: revision,
            exportFormat: exportFormat,
            fileName: fileName,
            searchController: Optional(searchController),
            viewingController: Optional(viewingController),
            sidebarController: Optional(sidebarController),
            exportData: exportData,
            openURL: openURL,
            remoteImageSources: remoteImageSources,
            onDownloadRemoteImage: onDownloadRemoteImage,
            onDownloadAllRemoteImages: onDownloadAllRemoteImages,
            onDragError: onDragError
        )
    }

    private init(
        data: Data,
        revision: UInt64,
        exportFormat: ExportFormat,
        fileName: String,
        searchController: PDFSearchController?,
        viewingController: PDFViewingController?,
        sidebarController: PDFThumbnailSidebarController?,
        exportData: @escaping () throws -> Data,
        openURL: @escaping (URL) -> Void,
        remoteImageSources: [String],
        onDownloadRemoteImage: @escaping (String) -> Void,
        onDownloadAllRemoteImages: @escaping () -> Void,
        onDragError: @escaping (Error) -> Void
    ) {
        self.data = data
        self.revision = revision
        self.exportFormat = exportFormat
        self.fileName = fileName
        self.searchController = searchController
        self.viewingController = viewingController
        self.sidebarController = sidebarController
        self.exportData = exportData
        self.openURL = openURL
        self.remoteImageSources = remoteImageSources
        self.onDownloadRemoteImage = onDownloadRemoteImage
        self.onDownloadAllRemoteImages = onDownloadAllRemoteImages
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
            remoteImageSources: [],
            onDownloadRemoteImage: { _ in },
            onDownloadAllRemoteImages: {},
            onDragError: onDragError
        )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            openURL: openURL,
            onDownloadRemoteImage: onDownloadRemoteImage,
            onDragError: onDragError
        )
    }

    public func makeNSView(context: Context) -> PDFPreviewContainerView {
        let container = PDFPreviewContainerView()
        container.previewView.delegate = context.coordinator
        container.previewView.updateRemoteImageActions(
            sources: remoteImageSources,
            downloadOne: onDownloadRemoteImage,
            downloadAll: onDownloadAllRemoteImages
        )
        container.attach(sidebarController: sidebarController)
        windowRestorationCoordinator?.attach(previewContainer: container)
        return container
    }

    public func updateNSView(_ container: PDFPreviewContainerView, context: Context) {
        let view = container.previewView
        context.coordinator.openURL = openURL
        context.coordinator.onDownloadRemoteImage = onDownloadRemoteImage
        context.coordinator.onDragError = onDragError
        view.delegate = context.coordinator
        container.attach(sidebarController: sidebarController)
        windowRestorationCoordinator?.attach(previewContainer: container)
        view.updateDragPayload(
            format: exportFormat,
            fileName: fileName,
            dataProvider: exportData,
            onError: context.coordinator.reportDragError
        )
        view.updateRemoteImageActions(
            sources: remoteImageSources,
            downloadOne: onDownloadRemoteImage,
            downloadAll: onDownloadAllRemoteImages
        )
        guard let document = PDFDocument(data: data) else { return }
        view.display(document, data: data, revision: revision)
        windowRestorationCoordinator?.previewDidDisplayDocument()
        view.deferControllerUpdate(
            searchController: searchController,
            viewingController: viewingController
        )
    }

    public static func dismantleNSView(
        _ view: PDFPreviewContainerView,
        coordinator: Coordinator
    ) {
        view.prepareForDismantling()
    }

    @MainActor
    public final class Coordinator: NSObject {
        var openURL: (URL) -> Void
        var onDownloadRemoteImage: (String) -> Void
        var onDragError: (Error) -> Void

        init(
            openURL: @escaping (URL) -> Void,
            onDownloadRemoteImage: @escaping (String) -> Void = { _ in },
            onDragError: @escaping (Error) -> Void
        ) {
            self.openURL = openURL
            self.onDownloadRemoteImage = onDownloadRemoteImage
            self.onDragError = onDragError
        }

        func reportDragError(_ error: Error) {
            onDragError(error)
        }
    }
}

extension PDFPreviewView.Coordinator: @preconcurrency PDFViewDelegate {
    public func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if let source = RemoteImageActionURL.downloadSource(from: url) {
            onDownloadRemoteImage(source)
        } else {
            openURL(url)
        }
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
              let reference = viewportReference(in: view)
        else { return nil }

        let pageIndex = max(document.index(for: reference.page), 0)
        let pageBounds = reference.page.bounds(for: .cropBox)
        let normalizedPoint = CGPoint(
            x: normalized(
                reference.point.x,
                minimum: pageBounds.minX,
                length: pageBounds.width
            ),
            y: normalized(
                reference.point.y,
                minimum: pageBounds.minY,
                length: pageBounds.height
            )
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

        for resolvedAnchor in resolvedTextAnchors(in: document) {
            if scroll(to: resolvedAnchor.selection, anchor: resolvedAnchor.anchor, in: view) {
                return
            }
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

    private func resolvedTextAnchors(
        in document: PDFDocument
    ) -> [(anchor: TextAnchor, selection: PDFSelection)] {
        var resolved: [(anchor: TextAnchor, selection: PDFSelection, distance: CGFloat)] = []
        for anchor in textAnchors where anchor.viewportTopFraction.isFinite {
            let matches = document.findString(
                anchor.text,
                withOptions: [.caseInsensitive, .diacriticInsensitive]
            )
            var closestMatch: (selection: PDFSelection, distance: CGFloat)?
            for selection in matches {
                let progress = Self.documentProgress(of: selection, in: document)
                let distance = abs(progress - anchor.documentProgress)
                if let currentMatch = closestMatch {
                    if distance < currentMatch.distance {
                        closestMatch = (selection, distance)
                    }
                } else {
                    closestMatch = (selection, distance)
                }
            }
            if let closestMatch {
                resolved.append((anchor, closestMatch.selection, closestMatch.distance))
            }
        }
        return resolved
            .sorted { $0.distance < $1.distance }
            .map { ($0.anchor, $0.selection) }
    }

    private func scroll(
        to selection: PDFSelection,
        anchor: TextAnchor,
        in view: PDFView
    ) -> Bool {
        guard let page = selection.pages.first else { return false }
        let pageBounds = page.bounds(for: .cropBox)
        let selectionBounds = selection.bounds(for: page)
        let viewportHeightInPage = view.bounds.height / max(view.scaleFactor, 0.01)
        let targetY = selectionBounds.maxY
            + anchor.viewportTopFraction * viewportHeightInPage
        guard pageBounds.minY...pageBounds.maxY ~= targetY else { return false }
        let targetX = pageBounds.minX + normalizedPagePoint.x * pageBounds.width
        go(to: CGPoint(x: targetX, y: targetY), on: page, in: view)
        return true
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
                guard lineBounds.minY.isFinite, lineBounds.maxY.isFinite else { continue }
                let fractionFromTop: CGFloat
                if view.isFlipped {
                    fractionFromTop = (lineBounds.minY - visibleBounds.minY) / visibleBounds.height
                } else {
                    fractionFromTop = (visibleBounds.maxY - lineBounds.maxY) / visibleBounds.height
                }
                guard fractionFromTop.isFinite else { continue }
                anchors.append(TextAnchor(
                    text: text,
                    documentProgress: documentProgress(of: lineSelection, in: document),
                    viewportTopFraction: clamped(fractionFromTop)
                ))
            }
        }

        return anchors
            .sorted { $0.viewportTopFraction < $1.viewportTopFraction }
            .evenlySampled(maximumCount: 16)
    }

    private static func viewportReference(
        in view: PDFView
    ) -> (page: PDFPage, point: CGPoint)? {
        let viewportTop = CGPoint(
            x: view.bounds.midX,
            y: view.isFlipped ? view.bounds.minY : view.bounds.maxY
        )
        if let page = view.page(for: viewportTop, nearest: true) {
            let pageBounds = page.bounds(for: .cropBox)
            let convertedPoint = view.convert(viewportTop, to: page)
            return (
                page,
                CGPoint(x: pageBounds.minX, y: convertedPoint.y)
            )
        }

        guard let page = view.currentPage ?? view.currentDestination?.page else { return nil }
        let pageBounds = page.bounds(for: .cropBox)
        let destination = view.currentDestination
        let point = destination?.page === page ? destination?.point : nil
        return (page, point ?? CGPoint(x: pageBounds.minX, y: pageBounds.maxY))
    }

    private static func anchorText(from string: String?) -> String {
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(trimmed.prefix(160))
    }

    static func documentProgress(
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

extension PersistedPreviewViewport {
    init(viewport: PreviewViewport) {
        self.init(
            scaleFactor: Double(viewport.scaleFactor),
            pageIndex: viewport.pageIndex,
            normalizedPageX: Double(viewport.normalizedPagePoint.x),
            normalizedPageY: Double(viewport.normalizedPagePoint.y),
            documentProgress: Double(viewport.documentProgress)
        )
    }

    var previewViewport: PreviewViewport {
        PreviewViewport(
            scaleFactor: CGFloat(scaleFactor),
            pageIndex: pageIndex,
            normalizedPagePoint: CGPoint(
                x: CGFloat(normalizedPageX),
                y: CGFloat(normalizedPageY)
            ),
            documentProgress: CGFloat(documentProgress),
            textAnchors: []
        )
    }
}

private extension Array {
    func evenlySampled(maximumCount: Int) -> [Element] {
        guard maximumCount > 0 else { return [] }
        guard count > maximumCount else { return self }
        guard maximumCount > 1 else { return [self[0]] }
        return (0..<maximumCount).map { sampleIndex in
            let index = Int(
                (Double(sampleIndex) * Double(count - 1) / Double(maximumCount - 1)).rounded()
            )
            return self[index]
        }
    }
}

private struct PDFSearchState {
    let query: String
    let matches: [PDFSelection]
    let selectedMatchIndex: Int?

    static let empty = PDFSearchState(query: "", matches: [], selectedMatchIndex: nil)

    var summary: PDFSearchSummary {
        PDFSearchSummary(
            matchCount: matches.count,
            selectedMatchIndex: selectedMatchIndex
        )
    }

    func selectedProgress(in document: PDFDocument) -> CGFloat? {
        guard let selectedMatchIndex,
              matches.indices.contains(selectedMatchIndex)
        else { return nil }
        return PreviewViewport.documentProgress(
            of: matches[selectedMatchIndex],
            in: document
        )
    }
}

private enum PDFSearchStartingPoint {
    case atOrAfter(CGFloat)
    case closest(to: CGFloat)
}

@MainActor
public final class BufferedPDFPreviewView: NSView, PDFSearchTarget, PDFViewingTarget {
    private var pendingCommit: DispatchWorkItem?
    private var stagedView: PageAdvancingPDFView?
    private var requestSequence: UInt64 = 0
    private var searchControllerUpdateSequence: UInt64 = 0
    private var viewingNotificationTokens: [NSObjectProtocol] = []
    private var searchState = PDFSearchState.empty
    private var showsAllSearchMatches = false
    private var dragDataProvider: (() throws -> Data)?
    private var dragFormat = ExportFormat.pdf
    private var dragFileName = "Untitled.pdf"
    private var dragErrorHandler: ((Error) -> Void)?
    private var remoteImageSources: [String] = []
    private var remoteImageDownloadHandler: ((String) -> Void)?
    private var allRemoteImagesDownloadHandler: (() -> Void)?
    var stagingDelay: TimeInterval = 0.05
    var retirementDelay: TimeInterval = 0.1
    private(set) var activeView: PageAdvancingPDFView
    private(set) var activeRevision: UInt64?
    private(set) var activeData: Data?
    var activeViewDidChange: ((PageAdvancingPDFView) -> Void)?

    weak var searchController: PDFSearchController? {
        didSet {
            guard oldValue !== searchController else { return }
            oldValue?.detach(from: self)
            searchController?.attach(to: self)
        }
    }

    weak var viewingController: PDFViewingController? {
        didSet {
            guard oldValue !== viewingController else { return }
            oldValue?.detach(from: self)
            viewingController?.attach(to: self)
        }
    }

    func deferControllerUpdate(
        searchController: PDFSearchController?,
        viewingController: PDFViewingController?
    ) {
        searchControllerUpdateSequence &+= 1
        let requestedSequence = searchControllerUpdateSequence
        Task { @MainActor [weak self] in
            guard let self,
                  self.searchControllerUpdateSequence == requestedSequence
            else { return }
            self.searchController = searchController
            self.viewingController = viewingController
        }
    }

    func deferSearchControllerUpdate(_ searchController: PDFSearchController?) {
        deferControllerUpdate(
            searchController: searchController,
            viewingController: viewingController
        )
    }

    func prepareForDismantling() {
        searchControllerUpdateSequence &+= 1
        searchController?.detachForDismantling(from: self)
        searchController = nil
        viewingController?.detachForDismantling(from: self)
        viewingController = nil
        stopObservingViewingState()
    }

    package func capturePersistedViewport() -> PersistedPreviewViewport? {
        PreviewViewport.capture(from: activeView).map(PersistedPreviewViewport.init(viewport:))
    }

    package func restorePersistedViewport(_ viewport: PersistedPreviewViewport) {
        activeView.restoreRelaunchViewport(viewport.previewViewport)
        notifyViewingController()
    }

    var viewingState: PDFViewingState {
        guard activeView.document?.pageCount ?? 0 > 0 else { return .unavailable }
        return PDFViewingState(
            isAvailable: true,
            canZoomIn: activeView.canZoomIn,
            canZoomOut: activeView.canZoomOut,
            canGoToPreviousPage: activeView.canGoToPreviousPage,
            canGoToNextPage: activeView.canGoToNextPage
        )
    }

    func showActualSize() {
        activeView.showActualSize()
        notifyViewingController()
    }

    func fitCurrentPage() {
        activeView.fitCurrentPage()
        notifyViewingController()
    }

    func zoomIn() {
        activeView.zoomInByStep()
        notifyViewingController()
    }

    func zoomOut() {
        activeView.zoomOutByStep()
        notifyViewingController()
    }

    func goToPreviousPage() {
        activeView.moveToPreviousPage()
        notifyViewingController()
    }

    func goToNextPage() {
        activeView.moveToNextPage()
        notifyViewingController()
    }

    var delegate: PDFViewDelegate? {
        didSet {
            previewViews.forEach { $0.delegate = delegate }
        }
    }

    public override init(frame frameRect: NSRect) {
        let initialView = PageAdvancingPDFView(frame: frameRect)
        self.activeView = initialView
        super.init(frame: frameRect)
        wantsLayer = true
        initialView.automaticallyTakesFocus = true
        initialView.setAccessibilityElement(true)
        initialView.setAccessibilityHidden(false)
        addSubview(initialView)
        observeViewingState(in: initialView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        previewViews.forEach { $0.frame = bounds }
    }

    func display(_ document: PDFDocument, data: Data, revision: UInt64) {
        guard activeData != data else {
            activeRevision = revision
            return
        }

        requestSequence &+= 1
        let requestedSequence = requestSequence
        pendingCommit?.cancel()
        pendingCommit = nil
        discardStagedView()

        guard activeView.document != nil else {
            activeData = data
            activeRevision = revision
            activeView.displayInitial(document)
            activeViewDidChange?(activeView)
            notifyViewingController()
            searchState = makeSearchState(
                query: searchState.query,
                in: document,
                startingAt: .atOrAfter(0)
            )
            applySearchState(
                searchState,
                to: activeView,
                showingAllMatches: showsAllSearchMatches,
                scrollSelection: false
            )
            notifySearchController()
            return
        }

        let viewport = PreviewViewport.capture(from: activeView)
        let preferredSearchProgress = activeView.document.flatMap {
            searchState.selectedProgress(in: $0)
        } ?? viewport?.documentProgress ?? 0
        let stagedSearchState = makeSearchState(
            query: searchState.query,
            in: document,
            startingAt: .closest(to: preferredSearchProgress)
        )
        let stagedView = makeStagedView()
        self.stagedView = stagedView
        addSubview(stagedView, positioned: .below, relativeTo: activeView)
        stagedView.displayReplacement(document, viewport: viewport)
        stagedView.layoutSubtreeIfNeeded()
        viewport?.restore(in: stagedView)
        applySearchState(
            stagedSearchState,
            to: stagedView,
            showingAllMatches: showsAllSearchMatches,
            scrollSelection: false
        )
        stagedView.displayIfNeededIgnoringOpacity()

        let workItem = DispatchWorkItem { [weak self, weak stagedView] in
            guard let self,
                  let stagedView,
                  self.requestSequence == requestedSequence,
                  self.stagedView === stagedView
            else { return }
            stagedView.layoutSubtreeIfNeeded()
            viewport?.restore(in: stagedView)
            let latestSearchProgress = self.activeView.document.flatMap {
                self.searchState.selectedProgress(in: $0)
            } ?? viewport?.documentProgress ?? 0
            let committedSearchState = self.makeSearchState(
                query: self.searchState.query,
                in: document,
                startingAt: .closest(to: latestSearchProgress)
            )
            self.applySearchState(
                committedSearchState,
                to: stagedView,
                showingAllMatches: self.showsAllSearchMatches,
                scrollSelection: false
            )
            stagedView.displayIfNeededIgnoringOpacity()
            self.commitStagedView(
                stagedView,
                data: data,
                revision: revision,
                requestedSequence: requestedSequence,
                searchState: committedSearchState
            )
        }
        pendingCommit = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + stagingDelay, execute: workItem)
    }

    var isSearchAvailable: Bool {
        activeView.document != nil
    }

    func performSearch(
        for query: String,
        showingAllMatches: Bool
    ) -> PDFSearchSummary {
        showsAllSearchMatches = showingAllMatches
        let startingProgress = PreviewViewport.capture(from: activeView)?.documentProgress ?? 0
        guard let document = activeView.document else {
            searchState = PDFSearchState(
                query: normalizedSearchQuery(query),
                matches: [],
                selectedMatchIndex: nil
            )
            return searchState.summary
        }

        searchState = makeSearchState(
            query: query,
            in: document,
            startingAt: .atOrAfter(startingProgress)
        )
        applySearchState(
            searchState,
            to: activeView,
            showingAllMatches: showingAllMatches,
            scrollSelection: true
        )
        return searchState.summary
    }

    func moveSearchSelection(
        _ direction: PDFSearchDirection,
        showingAllMatches: Bool
    ) -> PDFSearchSummary {
        showsAllSearchMatches = showingAllMatches
        guard !searchState.matches.isEmpty else { return searchState.summary }

        let currentIndex = searchState.selectedMatchIndex ?? {
            switch direction {
            case .next: return -1
            case .previous: return 0
            }
        }()
        let selectedIndex: Int
        switch direction {
        case .next:
            selectedIndex = (currentIndex + 1) % searchState.matches.count
        case .previous:
            selectedIndex = (
                currentIndex - 1 + searchState.matches.count
            ) % searchState.matches.count
        }
        searchState = PDFSearchState(
            query: searchState.query,
            matches: searchState.matches,
            selectedMatchIndex: selectedIndex
        )
        applySearchState(
            searchState,
            to: activeView,
            showingAllMatches: showingAllMatches,
            scrollSelection: true
        )
        return searchState.summary
    }

    func setShowsAllSearchMatches(_ showsAllMatches: Bool) {
        showsAllSearchMatches = showsAllMatches
        applySearchState(
            searchState,
            to: activeView,
            showingAllMatches: showsAllMatches,
            scrollSelection: false
        )
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
        previewViews.forEach {
            $0.updateDragPayload(
                format: format,
                fileName: fileName,
                dataProvider: dataProvider,
                onError: onError
            )
        }
    }

    func updateRemoteImageActions(
        sources: [String],
        downloadOne: @escaping (String) -> Void,
        downloadAll: @escaping () -> Void
    ) {
        remoteImageSources = sources
        remoteImageDownloadHandler = downloadOne
        allRemoteImagesDownloadHandler = downloadAll
        previewViews.forEach {
            $0.updateRemoteImageActions(
                sources: sources,
                downloadOne: downloadOne,
                downloadAll: downloadAll
            )
        }
    }

    private var previewViews: [PageAdvancingPDFView] {
        subviews.compactMap { $0 as? PageAdvancingPDFView }
    }

    private func makeStagedView() -> PageAdvancingPDFView {
        let view = PageAdvancingPDFView(frame: bounds)
        view.automaticallyTakesFocus = false
        view.delegate = delegate
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        if let dragDataProvider, let dragErrorHandler {
            view.updateDragPayload(
                format: dragFormat,
                fileName: dragFileName,
                dataProvider: dragDataProvider,
                onError: dragErrorHandler
            )
        }
        if let remoteImageDownloadHandler, let allRemoteImagesDownloadHandler {
            view.updateRemoteImageActions(
                sources: remoteImageSources,
                downloadOne: remoteImageDownloadHandler,
                downloadAll: allRemoteImagesDownloadHandler
            )
        }
        return view
    }

    private func discardStagedView() {
        guard let stagedView else { return }
        stagedView.isHidden = true
        stagedView.removeFromSuperview()
        stagedView.document = nil
        self.stagedView = nil
    }

    private func makeSearchState(
        query: String,
        in document: PDFDocument,
        startingAt startingPoint: PDFSearchStartingPoint
    ) -> PDFSearchState {
        let query = normalizedSearchQuery(query)
        guard !query.isEmpty else { return .empty }
        let matches = document.findString(query, withOptions: [.caseInsensitive])
        guard !matches.isEmpty else {
            return PDFSearchState(query: query, matches: [], selectedMatchIndex: nil)
        }

        let matchProgress = matches.map {
            PreviewViewport.documentProgress(of: $0, in: document)
        }
        let selectedIndex: Int
        switch startingPoint {
        case let .atOrAfter(progress):
            selectedIndex = matchProgress.firstIndex { $0 + 0.000_001 >= progress } ?? 0
        case let .closest(progress):
            selectedIndex = matchProgress.indices.min {
                abs(matchProgress[$0] - progress) < abs(matchProgress[$1] - progress)
            } ?? 0
        }
        return PDFSearchState(
            query: query,
            matches: matches,
            selectedMatchIndex: selectedIndex
        )
    }

    private func normalizedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applySearchState(
        _ state: PDFSearchState,
        to view: PDFView,
        showingAllMatches: Bool,
        scrollSelection: Bool
    ) {
        guard let selectedMatchIndex = state.selectedMatchIndex,
              state.matches.indices.contains(selectedMatchIndex)
        else {
            view.highlightedSelections = nil
            view.clearSelection()
            return
        }

        let selection = state.matches[selectedMatchIndex]
        view.setCurrentSelection(selection, animate: false)
        if showingAllMatches {
            view.highlightedSelections = state.matches.enumerated().compactMap { index, match in
                guard index != selectedMatchIndex,
                      let highlightedMatch = match.copy() as? PDFSelection
                else { return nil }
                highlightedMatch.color = NSColor.systemYellow.withAlphaComponent(0.32)
                return highlightedMatch
            }
        } else {
            view.highlightedSelections = nil
        }
        if scrollSelection {
            view.scrollSelectionToVisible(nil)
        }
    }

    private func notifySearchController() {
        searchController?.target(self, didUpdate: searchState.summary)
    }

    private func commitStagedView(
        _ stagedView: PageAdvancingPDFView,
        data: Data,
        revision: UInt64,
        requestedSequence: UInt64,
        searchState: PDFSearchState
    ) {
        guard requestSequence == requestedSequence,
              self.stagedView === stagedView
        else { return }
        let previousView = activeView
        let focusedView = window?.firstResponder as? NSView
        let shouldTransferFocus = focusedView === previousView
            || focusedView?.isDescendant(of: previousView) == true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            addSubview(stagedView, positioned: .above, relativeTo: previousView)
        }
        CATransaction.commit()

        previousView.automaticallyTakesFocus = false
        stagedView.automaticallyTakesFocus = true
        previousView.setAccessibilityElement(false)
        stagedView.setAccessibilityElement(true)
        previousView.setAccessibilityHidden(true)
        stagedView.setAccessibilityHidden(false)
        activeView = stagedView
        observeViewingState(in: stagedView)
        activeViewDidChange?(stagedView)
        activeData = data
        activeRevision = revision
        self.searchState = searchState
        self.stagedView = nil
        pendingCommit = nil
        notifySearchController()
        notifyViewingController()
        if shouldTransferFocus {
            window?.makeFirstResponder(stagedView)
        }
        scheduleRetirement(of: previousView)
    }

    private func scheduleRetirement(of previousView: PageAdvancingPDFView) {
        let workItem = DispatchWorkItem { [weak self, weak previousView] in
            guard let self,
                  let previousView,
                  previousView !== self.activeView,
                  previousView.superview === self
            else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previousView.isHidden = true
            previousView.removeFromSuperview()
            previousView.highlightedSelections = nil
            previousView.clearSelection()
            previousView.document = nil
            CATransaction.commit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retirementDelay, execute: workItem)
    }

    private func observeViewingState(in view: PDFView) {
        stopObservingViewingState()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .PDFViewPageChanged,
            .PDFViewScaleChanged
        ]
        viewingNotificationTokens = names.map { name in
            center.addObserver(forName: name, object: view, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.notifyViewingController()
                }
            }
        }
    }

    private func stopObservingViewingState() {
        let center = NotificationCenter.default
        viewingNotificationTokens.forEach(center.removeObserver)
        viewingNotificationTokens = []
    }

    private func notifyViewingController() {
        viewingController?.targetDidChange(self)
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
    private var remoteImageSources: [String] = []
    private var remoteImageDownloadHandler: ((String) -> Void)?
    private var allRemoteImagesDownloadHandler: (() -> Void)?
    private lazy var dragFileStore = ExportDragFileStore()
    private var activeDragArtifact: ExportDragArtifact?
    private var isDraggingExport = false
    var automaticallyTakesFocus = true
    private(set) lazy var outboundExportDragFeedbackView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.alphaValue = 0.86
        imageView.wantsLayer = true
        imageView.layer?.shadowColor = NSColor.black.cgColor
        imageView.layer?.shadowOpacity = 0.24
        imageView.layer?.shadowRadius = 5
        imageView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        imageView.setAccessibilityElement(false)
        imageView.setAccessibilityHidden(true)
        return imageView
    }()
    private(set) lazy var outboundExportDragRecognizer: NSPressGestureRecognizer = {
        let recognizer = NSPressGestureRecognizer(target: self, action: #selector(handleOutboundPDFDrag(_:)))
        recognizer.buttonMask = 0x1
        recognizer.minimumPressDuration = NSEvent.doubleClickInterval
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

    func restoreRelaunchViewport(_ viewport: PreviewViewport) {
        displayRevision += 1
        let restorationRevision = displayRevision
        needsInitialPageFit = false
        fittedViewWidth = bounds.width
        layoutSubtreeIfNeeded()
        viewport.restore(in: self)
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.displayRevision == restorationRevision else { return }
                self.needsInitialPageFit = false
                self.fittedViewWidth = self.bounds.width
                self.layoutSubtreeIfNeeded()
                viewport.restore(in: self)
            }
        }
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

    func updateRemoteImageActions(
        sources: [String],
        downloadOne: @escaping (String) -> Void,
        downloadAll: @escaping () -> Void
    ) {
        remoteImageSources = sources
        remoteImageDownloadHandler = downloadOne
        allRemoteImagesDownloadHandler = downloadAll
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        guard let page = page(for: location, nearest: false) else {
            return super.menu(for: event)
        }
        let pageLocation = convert(location, to: page)
        guard let source = page.annotations.compactMap({ annotation -> String? in
            guard annotation.bounds.contains(pageLocation), let url = annotation.url else {
                return nil
            }
            return RemoteImageActionURL.downloadSource(from: url)
        }).first else {
            return super.menu(for: event)
        }
        return remoteImageContextMenu(for: source)
    }

    func remoteImageContextMenu(for source: String) -> NSMenu {
        let menu = NSMenu()
        let one = NSMenuItem(
            title: "Download Image",
            action: #selector(downloadRemoteImage(_:)),
            keyEquivalent: ""
        )
        one.target = self
        one.representedObject = source
        one.isEnabled = remoteImageDownloadHandler != nil
        menu.addItem(one)

        let all = NSMenuItem(
            title: "Download All Images",
            action: #selector(downloadAllRemoteImages(_:)),
            keyEquivalent: ""
        )
        all.target = self
        all.isEnabled = !remoteImageSources.isEmpty && allRemoteImagesDownloadHandler != nil
        menu.addItem(all)
        return menu
    }

    @objc
    private func downloadRemoteImage(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? String else { return }
        remoteImageDownloadHandler?(source)
    }

    @objc
    private func downloadAllRemoteImages(_ sender: NSMenuItem) {
        allRemoteImagesDownloadHandler?()
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
        guard event.charactersIgnoringModifiers == " " else {
            super.keyDown(with: event)
            return
        }
        switch navigationModifiers {
        case []:
            moveToNextPage()
        case [.shift]:
            moveToPreviousPage()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard document != nil else {
            return super.performKeyEquivalent(with: event)
        }
        if modifiers == .option {
            switch event.keyCode {
            case 126:
                moveToPreviousPage()
                return true
            case 125:
                moveToNextPage()
                return true
            default:
                break
            }
        }
        guard modifiers == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "0":
            showActualSize()
        case "9":
            fitCurrentPage()
        case "+", "=":
            zoomInByStep()
        case "-":
            zoomOutByStep()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    func showActualSize() {
        guard document != nil else { return }
        autoScales = false
        scaleFactor = 1
        fittedViewWidth = nil
    }

    func fitCurrentPage() {
        guard let page = currentPage ?? document?.page(at: 0) else { return }
        fit(page)
        fittedViewWidth = bounds.width
    }

    func zoomInByStep() {
        guard document != nil, canZoomIn else { return }
        autoScales = false
        zoomIn(nil)
        fittedViewWidth = nil
    }

    func zoomOutByStep() {
        guard document != nil, canZoomOut else { return }
        autoScales = false
        zoomOut(nil)
        fittedViewWidth = nil
    }

    func moveToPreviousPage() {
        guard document != nil, canGoToPreviousPage else { return }
        goToPreviousPage(nil)
    }

    func moveToNextPage() {
        guard document != nil, canGoToNextPage else { return }
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
        hideOutboundExportDragFeedback()
    }

    private func configure() {
        autoScales = false
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        displaysPageBreaks = true
        addGestureRecognizer(outboundExportDragRecognizer)
    }

    @objc
    private func handleOutboundPDFDrag(_ recognizer: NSPressGestureRecognizer) {
        handleOutboundExportDrag(
            state: recognizer.state,
            event: NSApp.currentEvent,
            location: recognizer.location(in: self)
        )
    }

    func handleOutboundExportDrag(
        state: NSGestureRecognizer.State,
        event: NSEvent?,
        location: NSPoint
    ) {
        switch state {
        case .began:
            guard !isDraggingExport, dragDataProvider != nil else { return }
            showOutboundExportDragFeedback(at: location)
        case .changed:
            guard !isDraggingExport,
                  let dragDataProvider,
                  let event,
                  event.type == .leftMouseDragged
            else { return }
            beginOutboundExportDrag(
                dataProvider: dragDataProvider,
                event: event,
                location: location
            )
        case .ended, .cancelled, .failed:
            hideOutboundExportDragFeedback()
        default:
            break
        }
    }

    private func beginOutboundExportDrag(
        dataProvider: () throws -> Data,
        event: NSEvent,
        location: NSPoint
    ) {
        let artifact: ExportDragArtifact
        do {
            artifact = try dragFileStore.materialize(
                data: dataProvider(),
                fileName: dragFileName
            )
        } catch {
            hideOutboundExportDragFeedback()
            dragErrorHandler?(error)
            return
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: artifact.fileURL as NSURL)
        let image = dragThumbnail()
        draggingItem.setDraggingFrame(
            outboundExportDragFrame(for: image, centeredAt: location),
            contents: image
        )

        activeDragArtifact = artifact
        isDraggingExport = true
        hideOutboundExportDragFeedback()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func showOutboundExportDragFeedback(at location: NSPoint) {
        let image = dragThumbnail()
        outboundExportDragFeedbackView.image = image
        outboundExportDragFeedbackView.frame = outboundExportDragFrame(
            for: image,
            centeredAt: location
        )
        if outboundExportDragFeedbackView.superview !== self {
            addSubview(outboundExportDragFeedbackView, positioned: .above, relativeTo: nil)
        }
    }

    private func hideOutboundExportDragFeedback() {
        outboundExportDragFeedbackView.removeFromSuperview()
        outboundExportDragFeedbackView.image = nil
    }

    private func outboundExportDragFrame(for image: NSImage, centeredAt location: NSPoint) -> NSRect {
        NSRect(
            x: location.x - image.size.width / 2,
            y: location.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
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
        fit(firstPage)
    }

    private func fit(_ page: PDFPage) {
        displayMode = .singlePage
        let fittedScale = scaleFactorForSizeToFit * 0.99
        displayMode = .singlePageContinuous
        scaleFactor = fittedScale
        let bounds = page.bounds(for: .cropBox)
        let destination = PDFDestination(
            page: page,
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

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
    private let searchController: PDFSearchController?

    public init(
        data: Data,
        revision: UInt64 = 0,
        exportFormat: ExportFormat,
        fileName: String,
        exportData: @escaping () throws -> Data,
        openURL: @escaping (URL) -> Void,
        onDragError: @escaping (Error) -> Void = { _ in }
    ) {
        self.init(
            data: data,
            revision: revision,
            exportFormat: exportFormat,
            fileName: fileName,
            searchController: nil,
            exportData: exportData,
            openURL: openURL,
            onDragError: onDragError
        )
    }

    init(
        data: Data,
        revision: UInt64 = 0,
        exportFormat: ExportFormat,
        fileName: String,
        searchController: PDFSearchController,
        exportData: @escaping () throws -> Data,
        openURL: @escaping (URL) -> Void,
        onDragError: @escaping (Error) -> Void = { _ in }
    ) {
        self.init(
            data: data,
            revision: revision,
            exportFormat: exportFormat,
            fileName: fileName,
            searchController: Optional(searchController),
            exportData: exportData,
            openURL: openURL,
            onDragError: onDragError
        )
    }

    private init(
        data: Data,
        revision: UInt64,
        exportFormat: ExportFormat,
        fileName: String,
        searchController: PDFSearchController?,
        exportData: @escaping () throws -> Data,
        openURL: @escaping (URL) -> Void,
        onDragError: @escaping (Error) -> Void
    ) {
        self.data = data
        self.revision = revision
        self.exportFormat = exportFormat
        self.fileName = fileName
        self.searchController = searchController
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
        view.searchController = searchController
        return view
    }

    public func updateNSView(_ view: BufferedPDFPreviewView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.onDragError = onDragError
        view.delegate = context.coordinator
        view.searchController = searchController
        view.updateDragPayload(
            format: exportFormat,
            fileName: fileName,
            dataProvider: exportData,
            onError: context.coordinator.reportDragError
        )
        guard let document = PDFDocument(data: data) else { return }
        view.display(document, data: data, revision: revision)
    }

    public static func dismantleNSView(
        _ view: BufferedPDFPreviewView,
        coordinator: Coordinator
    ) {
        view.searchController = nil
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
        for anchor in textAnchors {
            let matches = document.findString(
                anchor.text,
                withOptions: [.caseInsensitive, .diacriticInsensitive]
            )
            for selection in matches {
                let progress = Self.documentProgress(of: selection, in: document)
                let distance = abs(progress - anchor.documentProgress)
                resolved.append((anchor, selection, distance))
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
public final class BufferedPDFPreviewView: NSView, PDFSearchTarget {
    private var pendingCommit: DispatchWorkItem?
    private var stagedView: PageAdvancingPDFView?
    private var requestSequence: UInt64 = 0
    private var searchState = PDFSearchState.empty
    private var showsAllSearchMatches = false
    private var dragDataProvider: (() throws -> Data)?
    private var dragFormat = ExportFormat.pdf
    private var dragFileName = "Untitled.pdf"
    private var dragErrorHandler: ((Error) -> Void)?
    var stagingDelay: TimeInterval = 0.05
    var retirementDelay: TimeInterval = 0.1
    private(set) var activeView: PageAdvancingPDFView
    private(set) var activeRevision: UInt64?
    private(set) var activeData: Data?

    weak var searchController: PDFSearchController? {
        didSet {
            guard oldValue !== searchController else { return }
            oldValue?.detach(from: self)
            searchController?.attach(to: self)
        }
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
        activeData = data
        activeRevision = revision
        self.searchState = searchState
        self.stagedView = nil
        pendingCommit = nil
        notifySearchController()
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

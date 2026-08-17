import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class PDFPreviewViewTests: XCTestCase {
    func testLinkCoordinatorForwardsPDFClicks() {
        let expectedURL = URL(string: "https://example.com")!
        var openedURL: URL?
        let coordinator = PDFPreviewView.Coordinator(
            openURL: { openedURL = $0 },
            onDragError: { _ in }
        )

        coordinator.pdfViewWillClick(onLink: PDFView(), with: expectedURL)

        XCTAssertEqual(openedURL, expectedURL)
    }

    func testDragErrorsAreForwarded() {
        var reportedError: PreviewTestError?
        let coordinator = PDFPreviewView.Coordinator(
            openURL: { _ in },
            onDragError: { reportedError = $0 as? PreviewTestError }
        )

        coordinator.reportDragError(PreviewTestError.example)

        XCTAssertEqual(reportedError, .example)
    }

    func testMarkdownLinkTargetRecognizesSupportedLocalFilesAndRemovesFragments() throws {
        for pathExtension in ["md", "markdown", "mdown", "mkd", "MD"] {
            let fileURL = URL(fileURLWithPath: "/tmp/notes.\(pathExtension)")
            var components = try XCTUnwrap(URLComponents(url: fileURL, resolvingAgainstBaseURL: false))
            components.query = "source=preview"
            components.fragment = "details"
            let linkedURL = try XCTUnwrap(components.url)

            XCTAssertEqual(MarkdownLinkTarget.fileURL(from: linkedURL), fileURL.standardizedFileURL)
        }
    }

    func testMarkdownLinkTargetLeavesWebAndOtherLocalFilesToTheSystem() {
        XCTAssertNil(MarkdownLinkTarget.fileURL(from: URL(string: "https://example.com/notes.md")!))
        XCTAssertNil(MarkdownLinkTarget.fileURL(from: URL(fileURLWithPath: "/tmp/report.pdf")))
    }

    func testInitialLayoutFitsTheCompleteFirstPage() throws {
        let document = try makeMultiPageDocument()
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))

        view.display(document)
        view.layoutSubtreeIfNeeded()

        let pageRect = view.convert(firstPage.bounds(for: .cropBox), from: firstPage)
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 0)
        XCTAssertLessThan(pageRect.width, view.bounds.width)
        XCTAssertLessThan(pageRect.height, view.bounds.height)
        XCTAssertEqual(view.displayMode, .singlePageContinuous)
        XCTAssertFalse(view.autoScales)
    }

    func testSettledInitialLayoutTargetsTheTopOfTheFirstPage() async throws {
        let document = try makeMultiPageDocument()
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))

        view.displayInitial(document)
        view.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        await nextMainQueueTurn()

        let destination = try XCTUnwrap(view.currentDestination)
        XCTAssertEqual(document.index(for: try XCTUnwrap(destination.page)), 0)
        XCTAssertEqual(
            destination.point.y,
            firstPage.bounds(for: .cropBox).maxY,
            accuracy: 1
        )
    }

    func testWidthResizeFitsThePageToTheAvailableWidth() throws {
        let document = try makeMultiPageDocument()
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let initialPageWidth = view.convert(firstPage.bounds(for: .cropBox), from: firstPage).width

        view.setFrameSize(NSSize(width: 1_040, height: 890))
        view.layoutSubtreeIfNeeded()

        let expandedPageWidth = view.convert(firstPage.bounds(for: .cropBox), from: firstPage).width
        XCTAssertGreaterThan(expandedPageWidth, initialPageWidth)
        XCTAssertEqual(view.bounds.width - expandedPageWidth, 64, accuracy: 1)
        XCTAssertLessThan(expandedPageWidth, view.bounds.width)
    }

    func testHeightOnlyResizeKeepsTheCurrentScale() throws {
        let document = try makeMultiPageDocument()
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let initialScale = view.scaleFactor

        view.setFrameSize(NSSize(width: 760, height: 1_100))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.scaleFactor, initialScale, accuracy: 0.001)
    }

    func testPlainSpaceAdvancesExactlyOnePage() throws {
        let document = try makeMultiPageDocument()
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        let space = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: " ",
            charactersIgnoringModifiers: " ",
            isARepeat: false,
            keyCode: 49
        ))

        view.keyDown(with: space)

        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 1)
    }

    func testSettledInitialFitOverridesInterimRestoredPagePosition() async throws {
        let document = try makeMultiPageDocument()
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.display(document)
        view.layoutSubtreeIfNeeded()
        view.goToNextPage(nil)
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 1)

        await nextMainQueueTurn()
        await nextMainQueueTurn()

        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 0)
    }

    func testOutboundExportDragUsesADeferredPrimaryButtonPress() {
        let view = PageAdvancingPDFView()
        let recognizer = view.outboundExportDragRecognizer

        XCTAssertEqual(recognizer.buttonMask, 0x1)
        XCTAssertEqual(recognizer.minimumPressDuration, NSEvent.doubleClickInterval)
        XCTAssertTrue(view.gestureRecognizers.contains { $0 === recognizer })
    }

    func testBufferedPreviewKeepsTheOldDocumentVisibleUntilThePreparedSwapCommits() async throws {
        let first = try makeDocument(markdown: "# First\n\nThe original visible document.")
        let second = try makeDocument(markdown: "# Second\n\nThe replacement visible document.")
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.stagingDelay = 0
        container.layoutSubtreeIfNeeded()

        container.display(first.document, data: first.data, revision: 1)
        let originalView = container.activeView
        XCTAssertEqual(container.activeData, first.data)
        XCTAssertFalse(originalView.isHidden)
        XCTAssertTrue(originalView.isAccessibilityElement())
        XCTAssertFalse(originalView.isAccessibilityHidden())

        container.display(second.document, data: second.data, revision: 2)

        XCTAssertTrue(container.activeView === originalView)
        XCTAssertEqual(container.activeData, first.data)
        XCTAssertFalse(originalView.isHidden)
        let preparedViews = container.subviews.compactMap { $0 as? PageAdvancingPDFView }
        XCTAssertTrue(preparedViews.contains {
            $0 !== originalView && $0.document?.string?.contains("replacement visible") == true
        })

        await nextMainQueueTurn()

        XCTAssertFalse(container.activeView === originalView)
        XCTAssertEqual(container.activeData, second.data)
        XCTAssertEqual(container.activeRevision, 2)
        XCTAssertFalse(originalView.isHidden)
        XCTAssertFalse(container.activeView.isHidden)
        XCTAssertFalse(originalView.isAccessibilityElement())
        XCTAssertTrue(container.activeView.isAccessibilityElement())
        XCTAssertTrue(originalView.isAccessibilityHidden())
        XCTAssertFalse(container.activeView.isAccessibilityHidden())
        XCTAssertTrue(container.subviews.last === container.activeView)
        XCTAssertTrue(container.activeView.document?.string?.contains("replacement visible") == true)
    }

    func testBufferedPreviewDiscardsAStalePreparedRevision() async throws {
        let first = try makeDocument(markdown: "# First\n\nInitial.")
        let stale = try makeDocument(markdown: "# Stale\n\nNever show this revision.")
        let latest = try makeDocument(markdown: "# Latest\n\nOnly show this revision.")
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.stagingDelay = 0
        container.layoutSubtreeIfNeeded()
        container.display(first.document, data: first.data, revision: 1)

        container.display(stale.document, data: stale.data, revision: 2)
        container.display(latest.document, data: latest.data, revision: 3)
        await nextMainQueueTurn()

        XCTAssertEqual(container.activeData, latest.data)
        XCTAssertEqual(container.activeRevision, 3)
        XCTAssertTrue(container.activeView.document?.string?.contains("Only show this revision") == true)
        XCTAssertFalse(container.activeView.document?.string?.contains("Never show") == true)
    }

    func testBufferedPreviewKeepsOutgoingViewOnTopDuringPaintDelay() async throws {
        let first = try makeDocument(markdown: "# First\n\nThe currently painted preview.")
        let second = try makeDocument(markdown: "# Second\n\nThe staged replacement preview.")
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.stagingDelay = 0.05
        container.layoutSubtreeIfNeeded()
        container.display(first.document, data: first.data, revision: 1)
        let outgoingView = container.activeView

        container.display(second.document, data: second.data, revision: 2)
        await nextMainQueueTurn()

        XCTAssertTrue(container.activeView === outgoingView)
        XCTAssertFalse(outgoingView.isHidden)
        XCTAssertTrue(container.subviews.last === outgoingView)

        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertFalse(container.activeView === outgoingView)
        XCTAssertFalse(outgoingView.isHidden)
        XCTAssertFalse(container.activeView.isHidden)
        XCTAssertTrue(container.subviews.last === container.activeView)
    }

    func testBufferedPreviewRetiresTheCoveredDocumentAfterTheSwap() async throws {
        let first = try makeDocument(markdown: "# First\n\nThe outgoing preview.")
        let second = try makeDocument(markdown: "# Second\n\nThe active preview.")
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.stagingDelay = 0
        container.retirementDelay = 0.02
        container.layoutSubtreeIfNeeded()
        container.display(first.document, data: first.data, revision: 1)
        let outgoingView = container.activeView

        container.display(second.document, data: second.data, revision: 2)
        await nextMainQueueTurn()
        XCTAssertNotNil(outgoingView.document)

        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertNil(outgoingView.document)
        XCTAssertTrue(container.activeView.document?.string?.contains("active preview") == true)
    }

    func testSearchIsCaseInsensitiveStartsAtTheViewportAndPreservesZoom() throws {
        let markdown = (1...120).map { index in
            [12, 62, 108].contains(index)
                ? "Result \(index) contains the distinctive NeEdLeToKeN phrase."
                : "Search fixture paragraph \(index) keeps the PDF spread across several pages."
        }.joined(separator: "\n\n")
        let rendered = try makeDocument(markdown: markdown)
        let matches = rendered.document.findString("needletoken", withOptions: [.caseInsensitive])
        XCTAssertEqual(matches.count, 3)
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.layoutSubtreeIfNeeded()
        container.display(rendered.document, data: rendered.data, revision: 1)
        container.activeView.scaleFactor = 0.82
        container.activeView.go(to: matches[1])

        let summary = container.performSearch(for: "NEEDLETOKEN", showingAllMatches: true)

        XCTAssertEqual(summary, PDFSearchSummary(matchCount: 3, selectedMatchIndex: 1))
        XCTAssertEqual(container.activeView.scaleFactor, 0.82, accuracy: 0.001)
        XCTAssertTrue(container.activeView.currentSelection?.string?.contains("NeEdLeToKeN") == true)
        XCTAssertEqual(container.activeView.highlightedSelections?.count, 2)
    }

    func testSearchNavigationWrapsAndDismissalKeepsOnlyTheCurrentMatch() throws {
        let rendered = try makeDocument(
            markdown: "# Search\n\nNeedle one.\n\nNeedle two.\n\nNeedle three."
        )
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.layoutSubtreeIfNeeded()
        container.display(rendered.document, data: rendered.data, revision: 1)
        let initial = container.performSearch(for: "needle", showingAllMatches: true)
        let initialIndex = try XCTUnwrap(initial.selectedMatchIndex)

        let previous = container.moveSearchSelection(.previous, showingAllMatches: true)
        XCTAssertEqual(previous.selectedMatchIndex, (initialIndex + 2) % 3)

        let next = container.moveSearchSelection(.next, showingAllMatches: true)
        XCTAssertEqual(next.selectedMatchIndex, initialIndex)

        container.setShowsAllSearchMatches(false)
        XCTAssertNil(container.activeView.highlightedSelections)
        XCTAssertNotNil(container.activeView.currentSelection)

        let empty = container.performSearch(for: " \n ", showingAllMatches: true)
        XCTAssertEqual(empty, .empty)
        XCTAssertNil(container.activeView.currentSelection)
        XCTAssertNil(container.activeView.highlightedSelections)
    }

    func testSearchStateFollowsBufferedRefreshesAndRecoversWhenMatchesReturn() async throws {
        let originalParagraphs = (1...120).map { index in
            [20, 60, 100].contains(index)
                ? "Repeated refresh needle at paragraph \(index)."
                : "Original refresh paragraph \(index) provides stable searchable content."
        }
        let replacementParagraphs = (1...5).map {
            "Inserted paragraph \($0) shifts later search matches without removing them."
        } + originalParagraphs
        let original = try makeDocument(markdown: originalParagraphs.joined(separator: "\n\n"))
        let replacement = try makeDocument(markdown: replacementParagraphs.joined(separator: "\n\n"))
        let missing = try makeDocument(markdown: "# Missing\n\nEvery former result is gone.")
        let returned = try makeDocument(markdown: "# Returned\n\nOne refresh needle is back.")
        let controller = PDFSearchController()
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.stagingDelay = 0
        container.layoutSubtreeIfNeeded()
        container.searchController = controller
        container.display(original.document, data: original.data, revision: 1)
        container.activeView.scaleFactor = 0.84
        controller.query = "refresh needle"
        controller.findNext()
        XCTAssertEqual(controller.selectedMatchIndex, 1)

        container.display(replacement.document, data: replacement.data, revision: 2)
        await nextMainQueueTurn()

        XCTAssertEqual(controller.matchCount, 3)
        XCTAssertEqual(controller.selectedMatchIndex, 1)
        XCTAssertEqual(container.activeView.scaleFactor, 0.84, accuracy: 0.001)
        XCTAssertTrue(container.activeView.currentSelection?.string?.contains("refresh needle") == true)

        container.display(missing.document, data: missing.data, revision: 3)
        await nextMainQueueTurn()

        XCTAssertEqual(controller.query, "refresh needle")
        XCTAssertEqual(controller.matchCount, 0)
        XCTAssertNil(container.activeView.currentSelection)

        container.display(returned.document, data: returned.data, revision: 4)
        await nextMainQueueTurn()

        XCTAssertEqual(controller.matchCount, 1)
        XCTAssertEqual(controller.selectedMatchIndex, 0)
        XCTAssertTrue(container.activeView.currentSelection?.string?.contains("refresh needle") == true)
    }

    func testLatestQueryWinsWhenItChangesDuringBufferedStaging() async throws {
        let original = try makeDocument(markdown: "# Original\n\nAlpha marker.")
        let replacement = try makeDocument(markdown: "# Replacement\n\nBeta marker.")
        let controller = PDFSearchController()
        let container = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        container.stagingDelay = 0.05
        container.layoutSubtreeIfNeeded()
        container.searchController = controller
        container.display(original.document, data: original.data, revision: 1)
        controller.query = "alpha"

        container.display(replacement.document, data: replacement.data, revision: 2)
        controller.query = "beta"
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(controller.query, "beta")
        XCTAssertEqual(controller.matchCount, 1)
        XCTAssertEqual(controller.selectedMatchIndex, 0)
        XCTAssertTrue(container.activeView.currentSelection?.string?.contains("Beta") == true)
    }

    func testViewportRestoresTheClosestSurvivingTextAnchor() throws {
        let paragraphs = (1...120).map { index in
            if index == 12 || index == 100 {
                return "Repeated semantic anchor used to preserve the visible paragraph."
            }
            return "Paragraph \(index): enough unique text to create a stable multipage document for viewport tests."
        }
        let rendered = try makeDocument(markdown: paragraphs.joined(separator: "\n\n"))
        let matches = rendered.document.findString(
            "Repeated semantic anchor used to preserve the visible paragraph.",
            withOptions: []
        )
        XCTAssertEqual(matches.count, 2)
        let laterPage = try XCTUnwrap(matches.last?.pages.first)
        let laterPageIndex = rendered.document.index(for: laterPage)
        let viewport = PreviewViewport(
            scaleFactor: 0.9,
            pageIndex: 0,
            normalizedPagePoint: CGPoint(x: 0, y: 0.5),
            documentProgress: 0.8,
            textAnchors: [
                .init(
                    text: "A changed sentence that no longer exists.",
                    documentProgress: 0.8,
                    viewportTopFraction: 0.2
                ),
                .init(
                    text: "Repeated semantic anchor used to preserve the visible paragraph.",
                    documentProgress: 0.8,
                    viewportTopFraction: 0.35
                )
            ]
        )
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))

        view.displayReplacement(rendered.document, viewport: viewport)

        XCTAssertEqual(
            rendered.document.index(for: try XCTUnwrap(view.currentDestination?.page)),
            laterPageIndex
        )
        XCTAssertEqual(view.scaleFactor, 0.9, accuracy: 0.001)
    }

    func testViewportFollowsTheSameParagraphWhenPaginationGrowsAndShrinks() throws {
        let anchorText = "The nearby unchanged paragraph keeps this viewport steady."
        let originalParagraphs = (1...120).map { index in
            index == 70
                ? anchorText
                : "Original paragraph \(index): unique searchable text for pagination changes."
        }
        let original = try makeDocument(markdown: originalParagraphs.joined(separator: "\n\n"))
        let originalSelection = try XCTUnwrap(
            original.document.findString(anchorText, withOptions: []).first
        )
        let originalPage = try XCTUnwrap(originalSelection.pages.first)
        let originalProgress = (
            CGFloat(original.document.index(for: originalPage)) + 0.5
        ) / CGFloat(original.document.pageCount)
        let viewport = PreviewViewport(
            scaleFactor: 0.85,
            pageIndex: original.document.index(for: originalPage),
            normalizedPagePoint: CGPoint(x: 0, y: 0.5),
            documentProgress: originalProgress,
            textAnchors: [
                .init(
                    text: anchorText,
                    documentProgress: originalProgress,
                    viewportTopFraction: 0.4
                )
            ]
        )
        let variants = [
            (1...80).map { "Inserted paragraph \($0): content added above the anchor." }
                + originalParagraphs,
            Array(originalParagraphs[59...79])
        ]
        XCTAssertGreaterThan(
            try makeDocument(markdown: variants[0].joined(separator: "\n\n")).document.pageCount,
            original.document.pageCount
        )
        XCTAssertLessThan(
            try makeDocument(markdown: variants[1].joined(separator: "\n\n")).document.pageCount,
            original.document.pageCount
        )

        for paragraphs in variants {
            let replacement = try makeDocument(markdown: paragraphs.joined(separator: "\n\n"))
            let expectedSelection = try XCTUnwrap(
                replacement.document.findString(anchorText, withOptions: []).first
            )
            let expectedPage = try XCTUnwrap(expectedSelection.pages.first)
            let view = PageAdvancingPDFView(
                frame: NSRect(x: 0, y: 0, width: 760, height: 890)
            )

            view.displayReplacement(replacement.document, viewport: viewport)

            XCTAssertEqual(
                replacement.document.index(for: try XCTUnwrap(view.currentDestination?.page)),
                replacement.document.index(for: expectedPage)
            )
            XCTAssertEqual(view.scaleFactor, 0.85, accuracy: 0.001)
        }
    }

    func testViewportFallsBackWhenEveryTextAnchorIsRemoved() throws {
        let rendered = try makeDocument(markdown: (1...100)
            .map { "Fallback paragraph \($0): enough text to require several pages." }
            .joined(separator: "\n\n"))
        XCTAssertGreaterThan(rendered.document.pageCount, 2)
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        let pageViewport = PreviewViewport(
            scaleFactor: 0.8,
            pageIndex: 1,
            normalizedPagePoint: CGPoint(x: 0.2, y: 0.6),
            documentProgress: 0.95,
            textAnchors: [
                .init(
                    text: "Every former semantic anchor has been removed.",
                    documentProgress: 0.95,
                    viewportTopFraction: 0.3
                )
            ]
        )

        view.displayReplacement(rendered.document, viewport: pageViewport)
        XCTAssertEqual(
            rendered.document.index(for: try XCTUnwrap(view.currentDestination?.page)),
            1
        )

        let progressViewport = PreviewViewport(
            scaleFactor: 0.8,
            pageIndex: rendered.document.pageCount + 10,
            normalizedPagePoint: CGPoint(x: 0.2, y: 0.6),
            documentProgress: 0.95,
            textAnchors: []
        )
        view.displayReplacement(rendered.document, viewport: progressViewport)
        let lastPage = try XCTUnwrap(rendered.document.page(at: rendered.document.pageCount - 1))
        XCTAssertTrue(view.convert(lastPage.bounds(for: .cropBox), from: lastPage).intersects(view.bounds))
    }

    func testViewportCaptureCollectsVisibleTextWithoutChangingScale() throws {
        let rendered = try makeDocument(markdown: (1...100)
            .map { "Visible anchor paragraph \($0): distinctive searchable viewport content." }
            .joined(separator: "\n\n"))
        let view = PageAdvancingPDFView(frame: NSRect(x: 0, y: 0, width: 760, height: 890))
        view.displayInitial(rendered.document)
        view.layoutSubtreeIfNeeded()
        let target = try XCTUnwrap(rendered.document.findString("Visible anchor paragraph 60", withOptions: []).first)
        view.go(to: target)
        let originalScale = view.scaleFactor

        let viewport = try XCTUnwrap(PreviewViewport.capture(from: view))

        XCTAssertFalse(viewport.textAnchors.isEmpty)
        XCTAssertEqual(viewport.scaleFactor, originalScale, accuracy: 0.001)
        XCTAssertTrue(viewport.textAnchors.allSatisfy { !$0.text.isEmpty })
        XCTAssertTrue(viewport.textAnchors.allSatisfy { 0...1 ~= $0.viewportTopFraction })
    }

    private func makeMultiPageDocument() throws -> PDFDocument {
        let markdown = (1...100)
            .map { "Paragraph \($0): Enough text to create several pages for preview navigation." }
            .joined(separator: "\n\n")
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 2)
        return document
    }

    private func makeDocument(markdown: String) throws -> (data: Data, document: PDFDocument) {
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        return (data, try XCTUnwrap(PDFDocument(data: data)))
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private enum PreviewTestError: Error, Equatable {
    case example
}

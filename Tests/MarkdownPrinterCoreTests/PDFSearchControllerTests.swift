import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class PDFSearchControllerTests: XCTestCase {
    func testFocusPolicySelectsOnlyARetainedQuery() {
        XCTAssertFalse(PDFSearchFocusPolicy.shouldSelectQuery(""))
        XCTAssertTrue(PDFSearchFocusPolicy.shouldSelectQuery("Needle"))
    }

    func testControllerPresentsSearchMovesMatchesAndRetainsQueryAfterDismissal() {
        let target = TestPDFSearchTarget()
        target.searchSummary = PDFSearchSummary(matchCount: 3, selectedMatchIndex: 1)
        target.moveSummary = PDFSearchSummary(matchCount: 3, selectedMatchIndex: 2)
        let controller = PDFSearchController()

        controller.attach(to: target)
        controller.present()
        controller.query = "Needle"

        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.focusRequest, 1)
        XCTAssertEqual(target.searchCalls.last?.query, "Needle")
        XCTAssertEqual(target.searchCalls.last?.showingAllMatches, true)
        XCTAssertEqual(controller.statusText, "2 of 3")
        XCTAssertTrue(controller.canNavigate)

        controller.findNext()

        XCTAssertEqual(target.moveCalls, [.next])
        XCTAssertEqual(controller.statusText, "3 of 3")

        controller.dismiss()

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(controller.query, "Needle")
        XCTAssertEqual(Array(target.showAllCalls.suffix(2)), [true, false])
    }

    func testControllerReportsNoMatchesAndPanelLifecycleControlsHighlights() {
        let target = TestPDFSearchTarget()
        let controller = PDFSearchController()
        controller.attach(to: target)

        controller.query = "missing"
        controller.present()

        XCTAssertEqual(controller.statusText, "No matches")
        XCTAssertFalse(controller.canNavigate)
        XCTAssertTrue(controller.isPresented)

        controller.dismiss()

        XCTAssertFalse(controller.isPresented)
        XCTAssertEqual(Array(target.showAllCalls.suffix(2)), [true, false])
    }

    func testUnavailableAndDetachedTargetsDisableCommands() {
        let target = TestPDFSearchTarget()
        target.isSearchAvailable = false
        let controller = PDFSearchController()

        controller.attach(to: target)
        controller.present()

        XCTAssertFalse(controller.canPresent)
        XCTAssertFalse(controller.isPresented)

        target.isSearchAvailable = true
        controller.attach(to: target)
        XCTAssertTrue(controller.canPresent)

        controller.detach(from: target)

        XCTAssertFalse(controller.canPresent)
        XCTAssertFalse(controller.canNavigate)
        XCTAssertEqual(controller.matchCount, 0)
    }

    func testSearchControllersKeepIndependentWindowState() {
        let firstTarget = TestPDFSearchTarget()
        firstTarget.searchSummary = PDFSearchSummary(matchCount: 2, selectedMatchIndex: 0)
        let secondTarget = TestPDFSearchTarget()
        secondTarget.searchSummary = PDFSearchSummary(matchCount: 1, selectedMatchIndex: 0)
        let first = PDFSearchController()
        let second = PDFSearchController()

        first.attach(to: firstTarget)
        second.attach(to: secondTarget)
        first.query = "first"
        second.query = "second"

        XCTAssertEqual(first.query, "first")
        XCTAssertEqual(first.matchCount, 2)
        XCTAssertEqual(second.query, "second")
        XCTAssertEqual(second.matchCount, 1)
        XCTAssertEqual(firstTarget.searchCalls.last?.query, "first")
        XCTAssertEqual(secondTarget.searchCalls.last?.query, "second")
    }
}

@MainActor
private final class TestPDFSearchTarget: PDFSearchTarget {
    struct SearchCall {
        let query: String
        let showingAllMatches: Bool
    }

    var isSearchAvailable = true
    var searchSummary = PDFSearchSummary.empty
    var moveSummary = PDFSearchSummary.empty
    private(set) var searchCalls: [SearchCall] = []
    private(set) var moveCalls: [PDFSearchDirection] = []
    private(set) var showAllCalls: [Bool] = []

    func performSearch(
        for query: String,
        showingAllMatches: Bool
    ) -> PDFSearchSummary {
        searchCalls.append(SearchCall(query: query, showingAllMatches: showingAllMatches))
        return searchSummary
    }

    func moveSearchSelection(
        _ direction: PDFSearchDirection,
        showingAllMatches: Bool
    ) -> PDFSearchSummary {
        moveCalls.append(direction)
        return moveSummary
    }

    func setShowsAllSearchMatches(_ showsAllMatches: Bool) {
        showAllCalls.append(showsAllMatches)
    }
}

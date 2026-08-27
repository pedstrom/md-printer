import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class PDFViewingControllerTests: XCTestCase {
    func testControllerPublishesTargetStateAndClearsItWhenDetached() {
        let target = TestPDFViewingTarget()
        target.state = PDFViewingState(
            isAvailable: true,
            canZoomIn: true,
            canZoomOut: false,
            canGoToPreviousPage: false,
            canGoToNextPage: true
        )
        let controller = PDFViewingController()

        controller.attach(to: target)

        XCTAssertTrue(controller.isAvailable)
        XCTAssertTrue(controller.canZoomIn)
        XCTAssertFalse(controller.canZoomOut)
        XCTAssertFalse(controller.canGoToPreviousPage)
        XCTAssertTrue(controller.canGoToNextPage)

        target.state = PDFViewingState(
            isAvailable: true,
            canZoomIn: false,
            canZoomOut: true,
            canGoToPreviousPage: true,
            canGoToNextPage: false
        )
        controller.targetDidChange(target)

        XCTAssertFalse(controller.canZoomIn)
        XCTAssertTrue(controller.canZoomOut)
        XCTAssertTrue(controller.canGoToPreviousPage)
        XCTAssertFalse(controller.canGoToNextPage)

        controller.detach(from: target)
        XCTAssertEqual(controller.state, .unavailable)
    }

    func testControllerRoutesOnlyCurrentlyAvailableActions() {
        let target = TestPDFViewingTarget()
        target.state = PDFViewingState(
            isAvailable: true,
            canZoomIn: true,
            canZoomOut: false,
            canGoToPreviousPage: false,
            canGoToNextPage: true
        )
        let controller = PDFViewingController()
        controller.attach(to: target)

        controller.actualSize()
        controller.fitPage()
        controller.zoomIn()
        controller.zoomOut()
        controller.previousPage()
        controller.nextPage()

        XCTAssertEqual(target.actualSizeCallCount, 1)
        XCTAssertEqual(target.fitPageCallCount, 1)
        XCTAssertEqual(target.zoomInCallCount, 1)
        XCTAssertEqual(target.zoomOutCallCount, 0)
        XCTAssertEqual(target.previousPageCallCount, 0)
        XCTAssertEqual(target.nextPageCallCount, 1)
    }

    func testDismantlingDefersUnavailablePublication() async {
        let target = TestPDFViewingTarget()
        target.state = PDFViewingState(
            isAvailable: true,
            canZoomIn: true,
            canZoomOut: true,
            canGoToPreviousPage: true,
            canGoToNextPage: true
        )
        let controller = PDFViewingController()
        controller.attach(to: target)

        controller.detachForDismantling(from: target)
        XCTAssertTrue(controller.isAvailable)

        await Task.yield()

        XCTAssertEqual(controller.state, .unavailable)
    }
}

@MainActor
private final class TestPDFViewingTarget: PDFViewingTarget {
    var state = PDFViewingState.unavailable
    var viewingState: PDFViewingState { state }
    private(set) var actualSizeCallCount = 0
    private(set) var fitPageCallCount = 0
    private(set) var zoomInCallCount = 0
    private(set) var zoomOutCallCount = 0
    private(set) var previousPageCallCount = 0
    private(set) var nextPageCallCount = 0

    func showActualSize() { actualSizeCallCount += 1 }
    func fitCurrentPage() { fitPageCallCount += 1 }
    func zoomIn() { zoomInCallCount += 1 }
    func zoomOut() { zoomOutCallCount += 1 }
    func goToPreviousPage() { previousPageCallCount += 1 }
    func goToNextPage() { nextPageCallCount += 1 }
}

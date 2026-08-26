import AppKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class PageSetupControllerTests: XCTestCase {
    func testPrintInfoRoundTripsPaperOrientationScaleAndFixedMargins() {
        let setup = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .landscape,
            scale: 1.15
        )

        let info = NativePageSetupPresenter.printInfo(for: setup)
        let roundTrip = NativePageSetupPresenter.pageSetup(from: info)

        XCTAssertEqual(roundTrip.orientation, .landscape)
        XCTAssertEqual(roundTrip.pageSize.width, setup.pageSize.width, accuracy: 0.5)
        XCTAssertEqual(roundTrip.pageSize.height, setup.pageSize.height, accuracy: 0.5)
        XCTAssertEqual(roundTrip.scale, 1.15, accuracy: 0.001)
        XCTAssertEqual(info.topMargin, 54)
        XCTAssertEqual(info.leftMargin, 54)
        XCTAssertEqual(info.bottomMargin, 54)
        XCTAssertEqual(info.rightMargin, 54)
    }

    func testPageSetupApplyAndCancelAreTransactionalBlockingSheets() throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Page", markdown: "# Page"))
        let activity = ApplicationActivityCoordinator()
        var capturedSetup: DocumentPageSetup?
        var completion: ((DocumentPageSetup?) -> Void)?
        let presenter = NativePageSetupPresenter { setup, _, handler in
            capturedSetup = setup
            completion = handler
        }
        let controller = DocumentPageActionController(
            session: session,
            activityCoordinator: activity,
            pageSetupPresenter: presenter
        )
        let window = NSWindow()

        controller.showPageSetup(window: window)
        XCTAssertTrue(activity.hasActiveBlockingOperation)
        XCTAssertEqual(capturedSetup, .letter)
        completion?(nil)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertEqual(session.activePageSetup, .letter)
        XCTAssertFalse(session.hasExplicitPageSetup)

        let accepted = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .portrait,
            scale: 0.9
        )
        controller.showPageSetup(window: window)
        completion?(accepted)
        XCTAssertEqual(session.activePageSetup, accepted)
        XCTAssertTrue(session.hasExplicitPageSetup)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

    func testUnavailableDocumentActionsAreNoOps() {
        let session = DocumentSession()
        let activity = ApplicationActivityCoordinator()
        var presentationCount = 0
        var printCount = 0
        let presenter = NativePageSetupPresenter { _, _, _ in presentationCount += 1 }
        let controller = DocumentPageActionController(
            session: session,
            activityCoordinator: activity,
            pageSetupPresenter: presenter,
            printing: { _ in printCount += 1 }
        )

        XCTAssertFalse(controller.canPageSetup)
        XCTAssertFalse(controller.canPrint)
        controller.showPageSetup(window: NSWindow())
        controller.printDocument()
        XCTAssertEqual(presentationCount, 0)
        XCTAssertEqual(printCount, 0)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

    func testPrintUsesSharedBlockingPathAndReportsFailures() throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Print", markdown: "# Print"))
        let activity = ApplicationActivityCoordinator()
        var printCount = 0
        let successful = DocumentPageActionController(
            session: session,
            activityCoordinator: activity,
            printing: { _ in
                XCTAssertTrue(activity.hasActiveBlockingOperation)
                printCount += 1
            }
        )

        successful.printDocument()
        XCTAssertEqual(printCount, 1)
        XCTAssertFalse(activity.hasActiveBlockingOperation)

        let failing = DocumentPageActionController(
            session: session,
            activityCoordinator: activity,
            printing: { _ in throw TestPrintError.failed }
        )
        failing.printDocument()

        XCTAssertEqual(session.errorMessage, TestPrintError.failed.localizedDescription)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

}

private enum TestPrintError: LocalizedError {
    case failed

    var errorDescription: String? { "Test print failed." }
}

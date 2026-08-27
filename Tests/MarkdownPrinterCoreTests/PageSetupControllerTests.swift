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
        var allowsUseDefault = true
        var completion: ((NativePageSetupResult) -> Void)?
        let presenter = NativePageSetupPresenter { setup, allowsDefault, _, handler in
            capturedSetup = setup
            allowsUseDefault = allowsDefault
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
        XCTAssertFalse(allowsUseDefault)
        completion?(.cancelled)
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
        completion?(.accepted(accepted))
        XCTAssertEqual(session.activePageSetup, accepted)
        XCTAssertTrue(session.hasExplicitPageSetup)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

    func testUseDefaultIsOfferedOnlyForAnOverrideAndImmediatelyRestoresInheritance() throws {
        let suite = "PageSetupControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PagePreferences(defaults: defaults)
        let session = DocumentSession(pagePreferences: preferences)
        try session.apply(MarkdownDocument(title: "Page", markdown: "# Page\n\nBody"))
        let explicit = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .landscape,
            scale: 0.9
        )
        try session.applyExplicitPageSetup(explicit)
        let previousRevision = try XCTUnwrap(session.renderedSnapshot).revision
        let activity = ApplicationActivityCoordinator()
        var allowsUseDefault = false
        var completion: ((NativePageSetupResult) -> Void)?
        let presenter = NativePageSetupPresenter { _, allowsDefault, _, handler in
            allowsUseDefault = allowsDefault
            completion = handler
        }
        let controller = DocumentPageActionController(
            session: session,
            activityCoordinator: activity,
            pageSetupPresenter: presenter
        )

        controller.showPageSetup(window: NSWindow())
        XCTAssertTrue(allowsUseDefault)
        XCTAssertTrue(activity.hasActiveBlockingOperation)
        completion?(.useDefault)

        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertFalse(session.hasExplicitPageSetup)
        XCTAssertEqual(session.activePageSetup, preferences.defaultPageSetup)
        XCTAssertGreaterThan(try XCTUnwrap(session.renderedSnapshot).revision, previousRevision)

        let laterDefault = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .portrait,
            scale: 1.1
        )
        preferences.defaultPageSetup = laterDefault
        XCTAssertEqual(session.activePageSetup, laterDefault)
    }

    func testUseDefaultFailureKeepsTheOverrideAndReportsTheExistingDocumentError() throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Page", markdown: "# Page"))
        let explicit = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .landscape,
            scale: 0.9
        )
        try session.applyExplicitPageSetup(explicit)
        let previousSnapshot = try XCTUnwrap(session.renderedSnapshot)
        let activity = ApplicationActivityCoordinator()
        var completion: ((NativePageSetupResult) -> Void)?
        let presenter = NativePageSetupPresenter { _, _, _, handler in completion = handler }
        let controller = DocumentPageActionController(
            session: session,
            activityCoordinator: activity,
            pageSetupPresenter: presenter,
            clearingPageSetup: { _ in throw TestPageSetupError.failed }
        )

        controller.showPageSetup(window: NSWindow())
        completion?(.useDefault)

        XCTAssertTrue(session.hasExplicitPageSetup)
        XCTAssertEqual(session.activePageSetup, explicit)
        XCTAssertEqual(session.renderedSnapshot?.revision, previousSnapshot.revision)
        XCTAssertEqual(session.errorMessage, TestPageSetupError.failed.localizedDescription)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

    func testDefaultPageSetupAccessoryHasTheOfficialImmediateAction() {
        var actionCount = 0
        let accessory = PageSetupDefaultAccessoryController { window in
            XCTAssertNil(window)
            actionCount += 1
        }

        accessory.loadView()
        XCTAssertEqual(accessory.useDefaultButton.title, "Use Default Page Setup")
        XCTAssertEqual(
            accessory.useDefaultButton.accessibilityLabel(),
            "Use Default Page Setup"
        )
        accessory.useDefaultButton.performClick(nil)

        XCTAssertEqual(actionCount, 1)
    }

    func testPageSetupPresentationContextDeliversAnImmediateResultOnlyOnce() {
        var results: [NativePageSetupResult] = []
        let context = PageSetupPresentationContext { results.append($0) }

        context.requestedDefault = true
        context.complete(.useDefault)
        context.complete(.cancelled)

        XCTAssertTrue(context.requestedDefault)
        XCTAssertEqual(results, [.useDefault])
    }

    func testUnavailableDocumentActionsAreNoOps() {
        let session = DocumentSession()
        let activity = ApplicationActivityCoordinator()
        var presentationCount = 0
        var printCount = 0
        let presenter = NativePageSetupPresenter { _, _, _, _ in presentationCount += 1 }
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

private enum TestPageSetupError: LocalizedError {
    case failed

    var errorDescription: String? { "Default page setup failed." }
}

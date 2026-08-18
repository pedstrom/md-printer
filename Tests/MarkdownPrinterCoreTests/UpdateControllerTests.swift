import Foundation
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testControllerReflectsInitialUpdaterState() {
        let checker = FakeUpdateChecker(
            canCheckForUpdates: false,
            automaticallyChecksForUpdates: true
        )
        let controller = UpdateController(updateChecker: checker)

        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertTrue(controller.automaticallyChecksForUpdates)
    }

    func testManualCheckRunsOnlyWhenSparkleCanCheck() {
        let checker = FakeUpdateChecker(canCheckForUpdates: false)
        let controller = UpdateController(updateChecker: checker)

        controller.checkForUpdates()
        XCTAssertEqual(checker.checkCount, 0)

        checker.canCheckForUpdates = true
        checker.stateDidChange?()
        controller.checkForUpdates()

        XCTAssertTrue(controller.canCheckForUpdates)
        XCTAssertEqual(checker.checkCount, 1)
    }

    func testAutomaticCheckPreferenceIsBoundDirectlyToSparkle() {
        let checker = FakeUpdateChecker(automaticallyChecksForUpdates: true)
        let controller = UpdateController(updateChecker: checker)

        controller.automaticallyChecksForUpdates = false

        XCTAssertFalse(checker.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
    }

    func testUnchangedAutomaticPreferenceDoesNotRewriteSparkle() {
        let checker = FakeUpdateChecker(automaticallyChecksForUpdates: true)
        let controller = UpdateController(updateChecker: checker)

        controller.automaticallyChecksForUpdates = true
        checker.stateDidChange?()

        XCTAssertEqual(checker.automaticPreferenceWriteCount, 0)
        XCTAssertTrue(controller.canCheckForUpdates)
    }

    func testProductionControllerStartsSparkleBridge() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        let controller = UpdateController(
            documentRestoration: restoration,
            activityCoordinator: ApplicationActivityCoordinator()
        )

        _ = controller.canCheckForUpdates
        _ = controller.automaticallyChecksForUpdates
        await Task.yield()
    }

    func testInstallationDelegateRecordsDocumentsForTargetBuild() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        let activity = ApplicationActivityCoordinator()
        let delegate = SparkleInstallationDelegate(
            documentRestoration: restoration,
            activityCoordinator: activity
        )
        let document = URL(fileURLWithPath: "/tmp/Install.md")
        restoration.documentDidOpen(at: document)

        delegate.prepareForInstallation(targetBuild: "8")

        XCTAssertEqual(
            restoration.consumeDocumentsForRelaunch(currentBuild: "8"),
            [document.standardizedFileURL]
        )
    }

    func testInstallationDelegatePostponesRelaunchDuringBlockingOperation() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        let activity = ApplicationActivityCoordinator()
        let delegate = SparkleInstallationDelegate(
            documentRestoration: restoration,
            activityCoordinator: activity
        )
        var didInvokeInstallHandler = false

        activity.performBlockingOperation {
            XCTAssertTrue(
                delegate.postponeRelaunch { didInvokeInstallHandler = true }
            )
            XCTAssertFalse(didInvokeInstallHandler)
        }

        XCTAssertTrue(didInvokeInstallHandler)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "UpdateControllerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

@MainActor
private final class FakeUpdateChecker: UpdateChecking {
    var canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool {
        didSet { automaticPreferenceWriteCount += 1 }
    }
    var stateDidChange: (() -> Void)?
    private(set) var checkCount = 0
    private(set) var automaticPreferenceWriteCount = 0

    init(
        canCheckForUpdates: Bool = true,
        automaticallyChecksForUpdates: Bool = false
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        checkCount += 1
    }
}

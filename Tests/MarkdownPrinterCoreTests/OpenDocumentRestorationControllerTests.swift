import Foundation
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class OpenDocumentRestorationControllerTests: XCTestCase {
    func testRecordsUniqueOpenFilesForTheTargetBuildAndConsumesOnce() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let first = URL(fileURLWithPath: "/tmp/Zeta.md")
        let second = URL(fileURLWithPath: "/tmp/Alpha.md")

        controller.documentDidOpen(at: first)
        controller.documentDidOpen(at: second)
        controller.documentDidOpen(at: first)
        controller.documentDidOpen(at: URL(string: "https://example.com/remote.md"))
        controller.prepareForRelaunch(targetBuild: "8")

        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "7"), [])
        XCTAssertEqual(
            controller.consumeDocumentsForRelaunch(currentBuild: "8"),
            [second.standardizedFileURL, first.standardizedFileURL]
        )
        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "8"), [])
    }

    func testDocumentReferenceCountsPreventEarlyRemoval() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/Repeated.md")

        controller.documentDidOpen(at: document)
        controller.documentDidOpen(at: document)
        controller.documentDidClose(at: document)

        XCTAssertTrue(controller.isDocumentOpen(at: document))
        controller.prepareForRelaunch(targetBuild: "8")
        XCTAssertEqual(
            controller.consumeDocumentsForRelaunch(currentBuild: "8"),
            [document.standardizedFileURL]
        )

        controller.documentDidClose(at: document)
        XCTAssertFalse(controller.isDocumentOpen(at: document))
    }

    func testPreparingWithNoOpenDocumentsClearsPendingRecord() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["build": "8", "paths": ["/tmp/Stale.md"]],
            forKey: OpenDocumentRestorationController.pendingRelaunchKey
        )
        let controller = OpenDocumentRestorationController(defaults: defaults)

        controller.prepareForRelaunch(targetBuild: "8")

        XCTAssertNil(defaults.object(forKey: OpenDocumentRestorationController.pendingRelaunchKey))
    }

    func testIgnoresInvalidPendingRecord() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["build": "8", "paths": "not-an-array"],
            forKey: OpenDocumentRestorationController.pendingRelaunchKey
        )
        let controller = OpenDocumentRestorationController(defaults: defaults)

        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "8"), [])
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "OpenDocumentRestorationControllerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

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
        let state = DocumentWindowRestorationState(
            frame: CGRect(x: 120, y: 180, width: 840, height: 920),
            viewport: PersistedPreviewViewport(
                scaleFactor: 0.82,
                pageIndex: 3,
                normalizedPageX: 0.1,
                normalizedPageY: 0.72,
                documentProgress: 0.48
            )
        )
        let providerID = UUID()
        var providerCallCount = 0

        controller.documentDidOpen(at: first)
        controller.documentDidOpen(at: second)
        controller.documentDidOpen(at: first)
        controller.documentDidOpen(at: URL(string: "https://example.com/remote.md"))
        controller.registerStateProvider(at: first, id: providerID) {
            providerCallCount += 1
            return state
        }
        controller.prepareForRelaunch(targetBuild: "8")

        XCTAssertEqual(providerCallCount, 1)
        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "7"), [])
        XCTAssertEqual(
            controller.consumeDocumentsForRelaunch(currentBuild: "8"),
            [second.standardizedFileURL, first.standardizedFileURL]
        )
        XCTAssertEqual(controller.takeWindowState(for: first), state)
        XCTAssertNil(controller.takeWindowState(for: first))
        XCTAssertNil(controller.takeWindowState(for: second))
        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "8"), [])

        controller.unregisterStateProvider(at: first, id: providerID)
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

    func testConsumesLegacyPathOnlyRecordWithoutWindowState() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["build": "8", "paths": ["/tmp/Legacy.md"]],
            forKey: OpenDocumentRestorationController.pendingRelaunchKey
        )
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Legacy.md").standardizedFileURL

        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "8"), [url])
        XCTAssertNil(controller.takeWindowState(for: url))
    }

    func testInvalidGeometryIsIgnoredWhileTheDocumentStillReopens() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                "build": "8",
                "documents": [[
                    "path": "/tmp/Invalid.md",
                    "frame": [0.0, 0.0, -1.0, 900.0],
                    "viewport": [
                        "scaleFactor": -1.0,
                        "pageIndex": 2,
                        "normalizedPageX": 0.0,
                        "normalizedPageY": 1.0,
                        "documentProgress": 0.5
                    ]
                ]]
            ],
            forKey: OpenDocumentRestorationController.pendingRelaunchKey
        )
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Invalid.md").standardizedFileURL

        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "8"), [url])
        XCTAssertNil(controller.takeWindowState(for: url))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "OpenDocumentRestorationControllerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

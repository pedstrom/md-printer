import Foundation
import XCTest
@testable import MarkdownPrinterCore
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

    func testLastSessionWorkspacePersistsUntilNextCaptureAndTracksAdditionalDocuments() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/Manual.md")
        let workspace = WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(
                identifier: "tabs",
                tabs: [.welcome, .document(document, state: nil)],
                selectedTabIndex: 1,
                isTabBarVisible: true
            )
        ])
        controller.workspaceCaptureProvider = { workspace }

        controller.captureLastSession()

        XCTAssertEqual(controller.lastSessionWorkspace(), workspace)
        XCTAssertTrue(controller.canReopenLastSession)
        var reopenCount = 0
        controller.reopenLastSessionHandler = { reopenCount += 1 }
        controller.reopenLastSession()
        XCTAssertEqual(reopenCount, 1)
        XCTAssertEqual(controller.lastSessionWorkspace(), workspace)

        controller.documentDidOpen(at: document)
        XCTAssertFalse(controller.canReopenLastSession)
        controller.reopenLastSession()
        XCTAssertEqual(reopenCount, 1)

        controller.documentDidClose(at: document)
        XCTAssertTrue(controller.canReopenLastSession)
        controller.workspaceCaptureProvider = { WorkspaceSnapshot(groups: []) }
        controller.captureLastSession()
        XCTAssertNil(controller.lastSessionWorkspace())
        XCTAssertFalse(controller.canReopenLastSession)
    }

    func testVersionedUpdateWorkspaceRoundTripsTabsAndThumbnailStateOnce() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/Versioned.md")
        let state = DocumentWindowRestorationState(
            frame: CGRect(x: 30, y: 40, width: 700, height: 800),
            viewport: PersistedPreviewViewport(
                scaleFactor: 0.75,
                pageIndex: 2,
                normalizedPageX: 0.2,
                normalizedPageY: 0.6,
                documentProgress: 0.4
            ),
            thumbnails: PersistedThumbnailSidebar(
                isVisible: true,
                width: 214,
                scrollOffset: 320
            ),
            explicitPageSetup: DocumentPageSetup(
                paperName: "iso-a4",
                paperSize: CGSize(width: 595, height: 842),
                orientation: .landscape,
                scale: 0.9
            )
        )
        let workspace = WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(
                identifier: "group-a",
                tabs: [.document(document, state: state), .welcome],
                selectedTabIndex: 0,
                isTabBarVisible: true
            )
        ])
        controller.workspaceCaptureProvider = { workspace }

        controller.prepareForRelaunch(targetBuild: "12")

        XCTAssertNil(controller.consumeWorkspaceForRelaunch(currentBuild: "11"))
        XCTAssertEqual(controller.consumeWorkspaceForRelaunch(currentBuild: "12"), workspace)
        XCTAssertEqual(controller.takeWindowState(for: document), state)
        XCTAssertNil(controller.consumeWorkspaceForRelaunch(currentBuild: "12"))
    }

    func testUnknownWorkspaceVersionIsNotRestored() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                "build": "12",
                "workspace": ["version": 99, "groups": []]
            ],
            forKey: OpenDocumentRestorationController.pendingRelaunchKey
        )
        let controller = OpenDocumentRestorationController(defaults: defaults)

        XCTAssertNil(controller.consumeWorkspaceForRelaunch(currentBuild: "12"))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "OpenDocumentRestorationControllerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

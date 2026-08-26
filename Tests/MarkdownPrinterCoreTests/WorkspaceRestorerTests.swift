import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class WorkspaceRestorerTests: XCTestCase {
    func testRestoreSkipsOpenDocumentsAndRebuildsMixedTabGroup() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        let coordinator = WindowTabCoordinator()
        let openURL = URL(fileURLWithPath: "/tmp/Already-Open.md")
        let newURL = URL(fileURLWithPath: "/tmp/New.md")
        let openWindow = makeWindow()
        let newWindow = makeWindow()
        var welcomeWindow: NSWindow?
        coordinator.attach(window: openWindow, documentURL: openURL)
        restoration.documentDidOpen(at: openURL)
        let workspace = WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(
                identifier: "mixed",
                tabs: [
                    .welcome,
                    .document(openURL, state: nil),
                    .document(newURL, state: nil)
                ],
                selectedTabIndex: 2,
                isTabBarVisible: true
            )
        ])

        let result = await WorkspaceRestorer.restore(
            workspace,
            restorationController: restoration,
            tabCoordinator: coordinator,
            openDocument: { url in
                XCTAssertEqual(url, newURL)
                coordinator.attach(window: newWindow, documentURL: url)
                restoration.documentDidOpen(at: url)
            },
            openWelcome: { identifier in
                let window = self.makeWindow()
                welcomeWindow = window
                coordinator.attach(window: window, identifier: identifier)
            },
            isReadableFile: { $0 == newURL }
        )

        XCTAssertEqual(result, WorkspaceRestoreResult(
            openedDocumentCount: 1,
            failedDocumentNames: []
        ))
        let group = try XCTUnwrap(openWindow.tabGroup)
        XCTAssertEqual(group.windows.count, 3)
        XCTAssertTrue(group.windows.contains { $0 === welcomeWindow })
        XCTAssertTrue(group.selectedWindow === newWindow)
        XCTAssertTrue(group.isTabBarVisible)
    }

    func testRestoreContinuesAfterUnreadableAndOpenFailuresWithOneSummary() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        let coordinator = WindowTabCoordinator()
        let missing = URL(fileURLWithPath: "/tmp/Missing.md")
        let failing = URL(fileURLWithPath: "/tmp/Failing.md")
        let workspace = WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(
                identifier: "failures",
                tabs: [
                    .document(missing, state: nil),
                    .document(failing, state: nil)
                ],
                selectedTabIndex: 0,
                isTabBarVisible: false
            )
        ])

        let result = await WorkspaceRestorer.restore(
            workspace,
            restorationController: restoration,
            tabCoordinator: coordinator,
            openDocument: { _ in throw RestoreTestError.failed },
            openWelcome: { _ in XCTFail("No welcome tab should be opened") },
            isReadableFile: { $0 == failing }
        )

        XCTAssertEqual(result.failedDocumentNames, ["Failing.md", "Missing.md"])
        XCTAssertEqual(
            WorkspaceRestorationSummaryError(
                failedDocumentNames: result.failedDocumentNames
            ).localizedDescription,
            "Couldn’t reopen 2 documents: Failing.md, Missing.md."
        )
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "WorkspaceRestorerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

private enum RestoreTestError: Error {
    case failed
}

import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class WindowTabCoordinatorTests: XCTestCase {
    func testAttachingWindowsConfiguresAndGroupsTheRequestedTab() throws {
        let coordinator = WindowTabCoordinator()
        let sourceWindow = makeWindow()
        let newWindow = makeWindow()

        coordinator.attach(window: sourceWindow)
        let identifier = coordinator.prepareNewTab(from: sourceWindow)
        coordinator.attach(window: newWindow, identifier: identifier)

        XCTAssertEqual(
            sourceWindow.tabbingIdentifier,
            coordinator.tabbingIdentifier
        )
        XCTAssertEqual(
            newWindow.tabbingIdentifier,
            coordinator.tabbingIdentifier
        )
        let tabGroup = try XCTUnwrap(sourceWindow.tabGroup)
        XCTAssertEqual(tabGroup.windows.count, 2)
        XCTAssertTrue(tabGroup.windows.contains { $0 === sourceWindow })
        XCTAssertTrue(tabGroup.windows.contains { $0 === newWindow })
        XCTAssertTrue(tabGroup.selectedWindow === newWindow)
        XCTAssertFalse(coordinator.canToggleTabBar)
        XCTAssertEqual(coordinator.tabBarCommandTitle, "Hide Tab Bar")
        XCTAssertFalse(coordinator.toggleTabBar(for: newWindow))
        XCTAssertTrue(tabGroup.isTabBarVisible)

        tabGroup.removeWindow(newWindow)
        XCTAssertTrue(coordinator.canToggleTabBar)
        XCTAssertEqual(coordinator.tabBarCommandTitle, "Show Tab Bar")
        XCTAssertTrue(coordinator.toggleTabBar(for: sourceWindow))
        XCTAssertTrue(tabGroup.isTabBarVisible)
        XCTAssertTrue(coordinator.toggleTabBar(for: sourceWindow))
        XCTAssertFalse(tabGroup.isTabBarVisible)
    }

    func testPendingTabRequestsRetainTheirOwnSources() throws {
        let coordinator = WindowTabCoordinator()
        let firstSource = makeWindow()
        let secondSource = makeWindow()
        let firstNewWindow = makeWindow()
        let secondNewWindow = makeWindow()
        coordinator.attach(window: firstSource)
        coordinator.attach(window: secondSource)

        let firstIdentifier = coordinator.prepareNewTab(from: firstSource)
        let secondIdentifier = coordinator.prepareNewTab(from: secondSource)
        coordinator.attach(window: secondNewWindow, identifier: secondIdentifier)
        coordinator.attach(window: firstNewWindow, identifier: firstIdentifier)

        let firstGroup = try XCTUnwrap(firstSource.tabGroup)
        let secondGroup = try XCTUnwrap(secondSource.tabGroup)
        XCTAssertTrue(firstGroup.windows.contains { $0 === firstNewWindow })
        XCTAssertFalse(firstGroup.windows.contains { $0 === secondNewWindow })
        XCTAssertTrue(secondGroup.windows.contains { $0 === secondNewWindow })
        XCTAssertFalse(secondGroup.windows.contains { $0 === firstNewWindow })
    }

    func testDocumentWindowReplacesTheWelcomeTabThatOpenedIt() throws {
        let coordinator = WindowTabCoordinator()
        let welcomeIdentifier = UUID()
        let welcomeWindow = makeWindow()
        let documentWindow = makeWindow()
        let documentURL = URL(fileURLWithPath: "/tmp/Chosen.md")
        coordinator.attach(window: welcomeWindow, identifier: welcomeIdentifier)

        XCTAssertNotNil(
            coordinator.prepareDocumentTab(
                for: documentURL,
                replacingWelcomeWindow: welcomeIdentifier
            )
        )
        coordinator.attach(window: documentWindow, documentURL: documentURL)

        let tabGroup = try XCTUnwrap(welcomeWindow.tabGroup)
        XCTAssertTrue(tabGroup.windows.contains { $0 === documentWindow })
        XCTAssertTrue(tabGroup.selectedWindow === documentWindow)

        tabGroup.removeWindow(welcomeWindow)
        XCTAssertEqual(tabGroup.windows.count, 1)
        XCTAssertTrue(tabGroup.windows.first === documentWindow)
    }

    func testCancelledDocumentRequestDoesNotClaimALaterDocumentWindow() throws {
        let coordinator = WindowTabCoordinator()
        let welcomeIdentifier = UUID()
        let welcomeWindow = makeWindow()
        let documentWindow = makeWindow()
        let documentURL = URL(fileURLWithPath: "/tmp/Cancelled.md")
        coordinator.attach(window: welcomeWindow, identifier: welcomeIdentifier)
        let requestIdentifier = try XCTUnwrap(
            coordinator.prepareDocumentTab(
                for: documentURL,
                replacingWelcomeWindow: welcomeIdentifier
            )
        )

        coordinator.cancelDocumentTabRequest(requestIdentifier, for: documentURL)
        coordinator.attach(window: documentWindow, documentURL: documentURL)

        XCTAssertNil(documentWindow.tabbedWindows)
        XCTAssertNil(welcomeWindow.tabbedWindows)
    }

    func testCancellingOneRepeatedDocumentRequestPreservesTheNextSource() throws {
        let coordinator = WindowTabCoordinator()
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        let firstWelcome = makeWindow()
        let secondWelcome = makeWindow()
        let documentWindow = makeWindow()
        let documentURL = URL(fileURLWithPath: "/tmp/Cancel-First.md")
        coordinator.attach(window: firstWelcome, identifier: firstIdentifier)
        coordinator.attach(window: secondWelcome, identifier: secondIdentifier)
        let firstRequest = try XCTUnwrap(
            coordinator.prepareDocumentTab(
                for: documentURL,
                replacingWelcomeWindow: firstIdentifier
            )
        )
        XCTAssertNotNil(
            coordinator.prepareDocumentTab(
                for: documentURL,
                replacingWelcomeWindow: secondIdentifier
            )
        )

        coordinator.cancelDocumentTabRequest(firstRequest, for: documentURL)
        coordinator.attach(window: documentWindow, documentURL: documentURL)

        XCTAssertNil(firstWelcome.tabbedWindows)
        XCTAssertTrue(
            try XCTUnwrap(secondWelcome.tabGroup).windows.contains { $0 === documentWindow }
        )
    }

    func testMissingDocumentRequestsAndUnknownWelcomeWindowsAreNoOps() {
        let coordinator = WindowTabCoordinator()
        let documentURL = URL(fileURLWithPath: "/tmp/Missing.md")

        XCTAssertNil(
            coordinator.prepareDocumentTab(
                for: documentURL,
                replacingWelcomeWindow: UUID()
            )
        )
        coordinator.cancelDocumentTabRequest(UUID(), for: documentURL)
    }

    func testDocumentRequestsForTheSameURLKeepTheirWelcomeWindowsInOrder() throws {
        let coordinator = WindowTabCoordinator()
        let firstIdentifier = UUID()
        let secondIdentifier = UUID()
        let firstWelcome = makeWindow()
        let secondWelcome = makeWindow()
        let firstDocument = makeWindow()
        let secondDocument = makeWindow()
        let documentURL = URL(fileURLWithPath: "/tmp/Repeated.md")
        coordinator.attach(window: firstWelcome, identifier: firstIdentifier)
        coordinator.attach(window: secondWelcome, identifier: secondIdentifier)

        XCTAssertNotNil(
            coordinator.prepareDocumentTab(
                for: documentURL,
                replacingWelcomeWindow: firstIdentifier
            )
        )
        XCTAssertNotNil(
            coordinator.prepareDocumentTab(
                for: documentURL,
                replacingWelcomeWindow: secondIdentifier
            )
        )
        coordinator.attach(window: firstDocument, documentURL: documentURL)
        coordinator.attach(window: secondDocument, documentURL: documentURL)

        XCTAssertTrue(
            try XCTUnwrap(firstWelcome.tabGroup).windows.contains { $0 === firstDocument }
        )
        XCTAssertFalse(
            try XCTUnwrap(firstWelcome.tabGroup).windows.contains { $0 === secondDocument }
        )
        XCTAssertTrue(
            try XCTUnwrap(secondWelcome.tabGroup).windows.contains { $0 === secondDocument }
        )
    }

    func testNewTabWithoutATabbableSourceRemainsAStandaloneWindow() {
        let coordinator = WindowTabCoordinator()
        let unrelatedWindow = makeWindow()
        let newWindow = makeWindow()

        let identifier = coordinator.prepareNewTab(from: unrelatedWindow)
        coordinator.attach(window: newWindow, identifier: identifier)

        XCTAssertNil(newWindow.tabbedWindows)
        XCTAssertTrue(coordinator.isTabbable(newWindow))
        XCTAssertFalse(coordinator.isTabbable(unrelatedWindow))
    }

    func testNewTabFallsBackToTheLastActiveDocumentWindow() throws {
        let coordinator = WindowTabCoordinator()
        let activeWindow = makeWindow()
        let unrelatedWindow = makeWindow()
        let newWindow = makeWindow()
        coordinator.attach(window: activeWindow)
        coordinator.activate(window: activeWindow)

        let identifier = coordinator.prepareNewTab(from: unrelatedWindow)
        coordinator.attach(window: newWindow, identifier: identifier)

        XCTAssertTrue(
            try XCTUnwrap(activeWindow.tabGroup).windows.contains { $0 === newWindow }
        )
    }

    func testNewTabRequestsUseTheInstalledWindowCreationHandler() {
        let coordinator = WindowTabCoordinator()
        let sourceWindow = makeWindow()
        var requestedWindow: NSWindow?
        coordinator.newTabRequestHandler = { requestedWindow = $0 }

        coordinator.requestNewTab(from: sourceWindow)

        XCTAssertTrue(requestedWindow === sourceWindow)
    }

    func testWindowResponderRoutesTheNativePlusActionThroughTheCoordinator() {
        let coordinator = WindowTabCoordinator()
        let sourceWindow = makeWindow()
        var requestedWindow: NSWindow?
        coordinator.newTabRequestHandler = { requestedWindow = $0 }
        let responder = WindowTabCommandResponder(
            coordinator: coordinator,
            sourceWindow: sourceWindow
        )

        responder.newWindowForTab(nil)

        XCTAssertTrue(requestedWindow === sourceWindow)
    }

    func testToggleCommandTracksVisibilityAndRejectsUntabbableWindows() {
        let coordinator = WindowTabCoordinator()
        let window = makeWindow()
        let unrelatedWindow = makeWindow()
        coordinator.attach(window: window)
        coordinator.activate(window: window)

        XCTAssertTrue(coordinator.canToggleTabBar)
        XCTAssertEqual(coordinator.tabBarCommandTitle, "Show Tab Bar")
        XCTAssertTrue(coordinator.toggleTabBar(for: window))
        XCTAssertEqual(coordinator.tabBarCommandTitle, "Hide Tab Bar")
        XCTAssertTrue(coordinator.toggleTabBar(for: window))
        XCTAssertEqual(coordinator.tabBarCommandTitle, "Show Tab Bar")

        coordinator.activate(window: unrelatedWindow)
        XCTAssertFalse(coordinator.canToggleTabBar)
        XCTAssertEqual(coordinator.tabBarCommandTitle, "Show Tab Bar")
        XCTAssertFalse(coordinator.toggleTabBar(for: unrelatedWindow))
    }

    func testAttachmentHostConnectsItsWindowAndHandlesKeyWindowNotification() throws {
        let coordinator = WindowTabCoordinator()
        let sourceWindow = makeWindow()
        let newWindow = makeWindow()
        coordinator.attach(window: sourceWindow)
        let identifier = coordinator.prepareNewTab(from: sourceWindow)
        let host = WindowTabAttachmentHostView(
            coordinator: coordinator,
            windowIdentifier: identifier
        )

        newWindow.contentView = host
        host.attachCurrentWindow()

        XCTAssertTrue(try XCTUnwrap(sourceWindow.tabGroup).windows.contains { $0 === newWindow })
        XCTAssertTrue(newWindow.nextResponder is WindowTabCommandResponder)
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: newWindow
        )
        XCTAssertFalse(coordinator.canToggleTabBar)
        XCTAssertEqual(coordinator.tabBarCommandTitle, "Hide Tab Bar")

        newWindow.contentView = NSView()
        host.attachCurrentWindow()
        XCTAssertNil(host.window)
        XCTAssertFalse(newWindow.nextResponder is WindowTabCommandResponder)
    }

    func testWorkspaceCapturePreservesTabOrderSelectionAndMixedWelcomeTabs() throws {
        let suiteName = "WindowTabCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        let coordinator = WindowTabCoordinator()
        let firstURL = URL(fileURLWithPath: "/tmp/First.md")
        let secondURL = URL(fileURLWithPath: "/tmp/Second.md")
        let first = makeWindow()
        let welcome = makeWindow()
        let second = makeWindow()
        let standaloneWelcome = makeWindow()
        coordinator.attach(window: first, documentURL: firstURL)
        coordinator.attach(window: welcome, identifier: UUID())
        coordinator.attach(window: second, documentURL: secondURL)
        coordinator.attach(window: standaloneWelcome, identifier: UUID())
        first.addTabbedWindow(welcome, ordered: .above)
        first.addTabbedWindow(second, ordered: .above)
        first.tabGroup?.selectedWindow = welcome

        let workspace = coordinator.captureWorkspace(restorationController: restoration)

        XCTAssertEqual(workspace.groups.count, 1)
        let group = try XCTUnwrap(workspace.groups.first)
        XCTAssertEqual(group.tabs.map(\.kind), [.document, .document, .welcome])
        XCTAssertEqual(group.tabs.compactMap(\.documentURL), [firstURL, secondURL])
        XCTAssertEqual(group.selectedTabIndex, 2)
    }

    func testWorkspaceRestorationGroupsTabsAndRestoresSelectedTab() throws {
        let coordinator = WindowTabCoordinator()
        let groupIdentifier = "restored-group"
        let welcome = makeWindow()
        let first = makeWindow()
        let second = makeWindow()
        let firstURL = URL(fileURLWithPath: "/tmp/First-Restored.md")
        let secondURL = URL(fileURLWithPath: "/tmp/Second-Restored.md")

        let welcomeIdentifier = coordinator.prepareWorkspaceWelcome(
            groupIdentifier: groupIdentifier,
            isSelected: false,
            isTabBarVisible: true
        )
        coordinator.attach(window: welcome, identifier: welcomeIdentifier)
        coordinator.prepareWorkspaceDocument(
            at: firstURL,
            groupIdentifier: groupIdentifier,
            isSelected: true,
            isTabBarVisible: true
        )
        coordinator.attach(window: first, documentURL: firstURL)
        coordinator.prepareWorkspaceDocument(
            at: secondURL,
            groupIdentifier: groupIdentifier,
            isSelected: false,
            isTabBarVisible: true
        )
        coordinator.attach(window: second, documentURL: secondURL)
        coordinator.finishWorkspaceRestoration()

        let tabGroup = try XCTUnwrap(first.tabGroup)
        XCTAssertEqual(tabGroup.windows.count, 3)
        XCTAssertEqual(tabGroup.windows.map { ObjectIdentifier($0) }, [
            ObjectIdentifier(welcome),
            ObjectIdentifier(first),
            ObjectIdentifier(second)
        ])
        XCTAssertTrue(tabGroup.selectedWindow === first)
        XCTAssertTrue(tabGroup.isTabBarVisible)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}

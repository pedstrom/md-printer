import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class ApplicationLifecycleDelegateTests: XCTestCase {
    func testApplicationTerminatesAfterLastWindowCloses() {
        let delegate = ApplicationLifecycleDelegate()

        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }

    func testNormalTerminationCapturesWorkspaceBeforeTerminating() {
        let delegate = ApplicationLifecycleDelegate()
        var captureCount = 0
        delegate.normalTerminationHandler = { captureCount += 1 }

        let reply = delegate.applicationShouldTerminate(.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(captureCount, 1)
    }

    func testNewWindowForTabUsesTheInstalledHandler() {
        let delegate = ApplicationLifecycleDelegate()
        var invocationCount = 0
        delegate.newTabHandler = {
            invocationCount += 1
        }

        delegate.newWindowForTab(nil)

        XCTAssertEqual(invocationCount, 1)
    }

    func testGeneratedNewDocumentSubmenuIsHiddenWithoutChangingOtherFileItems() throws {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let newMenu = NSMenu(title: "New")
        newMenu.addItem(withTitle: "New Markdown Printer Window", action: nil, keyEquivalent: "n")
        newMenu.addItem(withTitle: "New Document", action: nil, keyEquivalent: "")
        newItem.submenu = newMenu
        fileMenu.addItem(withTitle: "New Window", action: nil, keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: nil, keyEquivalent: "t")
        fileMenu.addItem(newItem)
        fileMenu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.hideGeneratedNewSubmenu(in: mainMenu)

        XCTAssertEqual(fileMenu.items.map(\.title), ["New Window", "New Tab", "New", "Open…"])
        XCTAssertTrue(newItem.isHidden)
        XCTAssertFalse(fileMenu.item(withTitle: "New Window")?.isHidden == true)
        XCTAssertFalse(fileMenu.item(withTitle: "Open…")?.isHidden == true)
    }

    func testGeneratedSaveDuplicateAndShareMenuAreRemovedWithoutChangingOtherFileItems() {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let duplicate = NSMenuItem(title: "Duplicate", action: nil, keyEquivalent: "")
        let genericShare = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        genericShare.submenu = NSMenu(title: "Share")
        let save = NSMenuItem(title: "Save", action: nil, keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: nil, keyEquivalent: "s")
        let preferredShare = NSMenuItem(title: "Share PDF…", action: nil, keyEquivalent: "")
        let open = NSMenuItem(title: "Open…", action: nil, keyEquivalent: "o")
        fileMenu.addItem(open)
        fileMenu.addItem(duplicate)
        fileMenu.addItem(genericShare)
        fileMenu.addItem(save)
        fileMenu.addItem(saveAs)
        fileMenu.addItem(preferredShare)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.hideGeneratedFileItems(in: mainMenu)

        XCTAssertFalse(fileMenu.items.contains(duplicate))
        XCTAssertFalse(fileMenu.items.contains(genericShare))
        XCTAssertFalse(fileMenu.items.contains(save))
        XCTAssertFalse(open.isHidden)
        XCTAssertTrue(fileMenu.items.contains(saveAs))
        XCTAssertTrue(fileMenu.items.contains(preferredShare))
    }

    func testIrrelevantReadOnlyEditItemsAreRemovedAndSeparatorsAreNormalized() {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: nil, keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: nil, keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: nil, keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Writing Tools", action: nil, keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: nil, keyEquivalent: "a")
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        find.submenu = NSMenu(title: "Find")
        editMenu.addItem(find)
        editMenu.addItem(withTitle: "Emoji & Symbols", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        delegate.hideIrrelevantReadOnlyEditItems(in: mainMenu)

        XCTAssertEqual(
            editMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Copy", "Select All", "Find"]
        )
        XCTAssertFalse(editMenu.items.first?.isSeparatorItem == true)
        XCTAssertFalse(editMenu.items.last?.isSeparatorItem == true)
        XCTAssertFalse(zip(editMenu.items, editMenu.items.dropFirst()).contains { pair in
            pair.0.isSeparatorItem && pair.1.isSeparatorItem
        })

        delegate.configureFileMenu(in: mainMenu)
        editMenu.addItem(withTitle: "Writing Tools", action: nil, keyEquivalent: "")
        editMenu.delegate?.menuWillOpen?(editMenu)

        XCTAssertNil(editMenu.item(withTitle: "Writing Tools"))
    }

    func testEditMenuProxyForwardsSwiftUIUpdatesBeforeCleaningRepopulatedItems() throws {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let originalDelegate = TestMenuDelegate()
        editMenu.delegate = originalDelegate

        delegate.configureFileMenu(in: mainMenu)
        let proxy = try XCTUnwrap(editMenu.delegate)

        editMenu.addItem(withTitle: "Writing Tools", action: nil, keyEquivalent: "")
        proxy.menuNeedsUpdate?(editMenu)
        XCTAssertEqual(originalDelegate.needsUpdateCount, 1)
        XCTAssertNil(editMenu.item(withTitle: "Writing Tools"))

        editMenu.addItem(withTitle: "AutoFill", action: nil, keyEquivalent: "")
        proxy.menuWillOpen?(editMenu)
        XCTAssertEqual(originalDelegate.willOpenCount, 1)
        XCTAssertNil(editMenu.item(withTitle: "AutoFill"))
    }

    func testGeneratedNewWindowAndTabDuplicatesAreRemoved() {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: nil, keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: nil, keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Window", action: nil, keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Tab", action: nil, keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.hideGeneratedNewSubmenu(in: mainMenu)

        XCTAssertEqual(fileMenu.items.map(\.title), ["New Window", "New Tab", "Open…"])
    }

    func testMenuCleanupIgnoresUnrelatedNewSubmenusAndMissingMenus() {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "Commands", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "Commands")
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let unrelatedNewMenu = NSMenu(title: "New")
        unrelatedNewMenu.addItem(withTitle: "New Profile", action: nil, keyEquivalent: "")
        newItem.submenu = unrelatedNewMenu
        fileMenu.addItem(newItem)
        fileMenu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.hideGeneratedNewSubmenu(in: mainMenu)
        delegate.hideGeneratedNewSubmenu(in: nil)
        delegate.configureFileMenu(in: nil)

        XCTAssertEqual(fileMenu.items.map(\.title), ["New", "Open…"])
        XCTAssertFalse(newItem.isHidden)
    }

    func testConfiguredFileMenuRehidesGeneratedSubmenuBeforeOpening() throws {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let newMenu = NSMenu(title: "New")
        newMenu.addItem(withTitle: "New Markdown Printer Window", action: nil, keyEquivalent: "n")
        newMenu.addItem(withTitle: "New Document", action: nil, keyEquivalent: "")
        newItem.submenu = newMenu
        fileMenu.addItem(newItem)
        fileMenu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.configureFileMenu(in: mainMenu)
        newItem.isHidden = false
        try XCTUnwrap(fileMenu.delegate).menuWillOpen?(fileMenu)
        XCTAssertTrue(newItem.isHidden)

        newItem.isHidden = false
        try XCTUnwrap(fileMenu.delegate).menuNeedsUpdate?(fileMenu)

        XCTAssertTrue(newItem.isHidden)
    }

    func testConfiguredFileMenuReinstallsReopenItemBeforeOpening() throws {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        fileMenu.addItem(recent)
        fileMenu.addItem(withTitle: "Close", action: nil, keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.configureFileMenu(in: mainMenu)
        let first = try XCTUnwrap(fileMenu.item(withTitle: "Reopen Windows from Last Session"))
        fileMenu.removeItem(first)

        try XCTUnwrap(fileMenu.delegate).menuWillOpen?(fileMenu)

        let restored = try XCTUnwrap(
            fileMenu.item(withTitle: "Reopen Windows from Last Session")
        )
        XCTAssertEqual(fileMenu.index(of: restored), fileMenu.index(of: recent) + 1)
        XCTAssertFalse(restored.isEnabled)
    }

    func testApplicationLifecycleCallbacksKeepTheCurrentFileMenuConfigured() {
        let delegate = ApplicationLifecycleDelegate()
        let application = NSApplication.shared
        let previousMainMenu: NSMenu? = application.mainMenu
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let newItem = NSMenuItem(title: "New", action: nil, keyEquivalent: "")
        let newMenu = NSMenu(title: "New")
        newMenu.addItem(withTitle: "New Document", action: nil, keyEquivalent: "")
        newItem.submenu = newMenu
        fileMenu.addItem(newItem)
        fileMenu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        application.mainMenu = mainMenu
        defer { application.mainMenu = previousMainMenu }

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification, object: application)
        )
        XCTAssertTrue(newItem.isHidden)

        newItem.isHidden = false
        delegate.applicationDidUpdate(
            Notification(name: NSApplication.didUpdateNotification, object: application)
        )
        XCTAssertTrue(newItem.isHidden)

        newItem.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertTrue(newItem.isHidden)
    }

    func testReopenLastSessionItemAppearsAfterOpenRecentAndTracksAvailability() throws {
        let suiteName = "ApplicationLifecycleDelegateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/Reopen.md")
        restoration.workspaceCaptureProvider = {
            WorkspaceSnapshot(groups: [
                WorkspaceWindowGroup(
                    identifier: "window",
                    tabs: [.document(document, state: nil)],
                    selectedTabIndex: 0,
                    isTabBarVisible: false
                )
            ])
        }
        restoration.captureLastSession()
        var reopenCount = 0
        restoration.reopenLastSessionHandler = { reopenCount += 1 }

        let delegate = ApplicationLifecycleDelegate()
        delegate.documentRestorationController = restoration
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: nil, keyEquivalent: "o")
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        fileMenu.addItem(recent)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: nil, keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.configureFileMenu(in: mainMenu)
        delegate.configureFileMenu(in: mainMenu)

        let reopenItems = fileMenu.items.filter {
            $0.title == "Reopen Windows from Last Session"
        }
        XCTAssertEqual(reopenItems.count, 1)
        let reopen = try XCTUnwrap(reopenItems.first)
        XCTAssertEqual(fileMenu.index(of: reopen), fileMenu.index(of: recent) + 1)
        XCTAssertTrue(reopen.isEnabled)
        delegate.reopenWindowsFromLastSession(nil)
        XCTAssertEqual(reopenCount, 1)

        restoration.documentDidOpen(at: document)
        delegate.hideGeneratedFileItems(in: mainMenu)
        XCTAssertFalse(reopen.isEnabled)
    }
}

@MainActor
private final class TestMenuDelegate: NSObject, NSMenuDelegate {
    private(set) var needsUpdateCount = 0
    private(set) var willOpenCount = 0

    func menuNeedsUpdate(_ menu: NSMenu) {
        needsUpdateCount += 1
    }

    func menuWillOpen(_ menu: NSMenu) {
        willOpenCount += 1
    }
}

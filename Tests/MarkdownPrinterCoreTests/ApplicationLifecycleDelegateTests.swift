import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class ApplicationLifecycleDelegateTests: XCTestCase {
    func testApplicationTerminatesAfterLastWindowCloses() {
        let delegate = ApplicationLifecycleDelegate()

        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
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

    func testGeneratedDuplicateIsHiddenWithoutChangingOtherFileItems() {
        let delegate = ApplicationLifecycleDelegate()
        let mainMenu = NSMenu()
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let duplicate = NSMenuItem(title: "Duplicate", action: nil, keyEquivalent: "")
        let save = NSMenuItem(title: "Save…", action: nil, keyEquivalent: "s")
        let open = NSMenuItem(title: "Open…", action: nil, keyEquivalent: "o")
        fileMenu.addItem(open)
        fileMenu.addItem(duplicate)
        fileMenu.addItem(save)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        delegate.hideGeneratedFileItems(in: mainMenu)

        XCTAssertTrue(duplicate.isHidden)
        XCTAssertFalse(open.isHidden)
        XCTAssertFalse(save.isHidden)
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
}

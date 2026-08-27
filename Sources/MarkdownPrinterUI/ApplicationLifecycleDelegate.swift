import AppKit

@MainActor
public final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    package var newTabHandler: (() -> Void)?
    package var helpHandler: ((MarkdownPrinterHelpDestination) -> Void)?
    package var focusedWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    package weak var documentRestorationController: OpenDocumentRestorationController?
    package var normalTerminationHandler: (() -> Void)?
    private static let reopenLastSessionIdentifier = NSUserInterfaceItemIdentifier(
        "com.peteedstrom.markdown-printer.reopen-last-session"
    )
    private static let closeWindowIdentifier = NSUserInterfaceItemIdentifier(
        "com.peteedstrom.markdown-printer.close-window"
    )
    private static let helpOverviewIdentifier = NSUserInterfaceItemIdentifier(
        "com.peteedstrom.markdown-printer.help-overview"
    )
    private static let helpShortcutsIdentifier = NSUserInterfaceItemIdentifier(
        "com.peteedstrom.markdown-printer.help-shortcuts"
    )
    private lazy var fileMenuDelegateProxy = FileMenuDelegateProxy(owner: self)
    private lazy var editMenuDelegateProxy = EditMenuDelegateProxy(owner: self)
    private lazy var helpMenuDelegateProxy = HelpMenuDelegateProxy(owner: self)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        configureFileMenu(in: NSApp.mainMenu)
        DispatchQueue.main.async { [weak self] in
            self?.configureFileMenu(in: NSApp.mainMenu)
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        configureFileMenu(in: NSApp.mainMenu)
        DispatchQueue.main.async { [weak self] in
            self?.configureFileMenu(in: NSApp.mainMenu)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        normalTerminationHandler?()
        return .terminateNow
    }

    @IBAction public func newWindowForTab(_ sender: Any?) {
        newTabHandler?()
    }

    package func hideGeneratedNewSubmenu(in mainMenu: NSMenu?) {
        guard
            let fileMenu = Self.fileMenu(in: mainMenu)
        else {
            return
        }

        fileMenu.items
            .filter { item in
                guard let submenu = item.submenu else { return false }
                return submenu.items.contains { $0.title == "New Document" }
                    || (item.title == "New" && submenu.items.contains {
                        $0.keyEquivalent.lowercased() == "n"
                    })
            }
            .forEach { $0.isHidden = true }

        for title in ["New Window", "New Tab"] {
            fileMenu.items
                .filter { $0.title == title }
                .dropFirst()
                .forEach { fileMenu.removeItem($0) }
        }
    }

    package func configureFileMenu(in mainMenu: NSMenu?) {
        configureEditMenu(in: mainMenu)
        hideIrrelevantReadOnlyEditItems(in: mainMenu)
        configureHelpMenu(in: mainMenu)
        guard let fileMenu = Self.fileMenu(in: mainMenu) else { return }
        fileMenuDelegateProxy.mainMenu = mainMenu
        if fileMenu.delegate !== fileMenuDelegateProxy {
            fileMenuDelegateProxy.originalDelegate = fileMenu.delegate
            fileMenu.delegate = fileMenuDelegateProxy
        }
        hideGeneratedFileItems(in: mainMenu)
        installReopenLastSessionItem(in: fileMenu)
        installCloseWindowItem(in: fileMenu)
    }

    package func configureHelpMenu(in mainMenu: NSMenu?) {
        guard let helpMenu = Self.helpMenu(in: mainMenu) else { return }
        helpMenuDelegateProxy.mainMenu = mainMenu
        if helpMenu.delegate !== helpMenuDelegateProxy {
            helpMenuDelegateProxy.originalDelegate = helpMenu.delegate
            helpMenu.delegate = helpMenuDelegateProxy
        }
        let generatedHelpSelector = #selector(NSApplication.showHelp(_:))
        let managedIdentifiers = [
            Self.helpOverviewIdentifier,
            Self.helpShortcutsIdentifier
        ]
        let replacementIndex = helpMenu.items.firstIndex(where: { item in
            item.action == generatedHelpSelector
                || item.identifier.map(managedIdentifiers.contains) == true
        }) ?? helpMenu.items.count
        helpMenu.items
            .filter { item in
                item.action == generatedHelpSelector
                    || item.identifier.map(managedIdentifiers.contains) == true
            }
            .forEach { helpMenu.removeItem($0) }

        let overview = NSMenuItem(
            title: "Markdown Printer Help",
            action: #selector(showMarkdownPrinterHelp(_:)),
            keyEquivalent: ""
        )
        overview.identifier = Self.helpOverviewIdentifier
        overview.target = self
        helpMenu.insertItem(overview, at: min(replacementIndex, helpMenu.items.count))

        let shortcuts = NSMenuItem(
            title: "Keyboard Shortcuts",
            action: #selector(showKeyboardShortcuts(_:)),
            keyEquivalent: ""
        )
        shortcuts.identifier = Self.helpShortcutsIdentifier
        shortcuts.target = self
        helpMenu.insertItem(
            shortcuts,
            at: min(replacementIndex + 1, helpMenu.items.count)
        )
    }

    @IBAction package func showMarkdownPrinterHelp(_ sender: Any?) {
        helpHandler?(.overview)
    }

    @IBAction package func showKeyboardShortcuts(_ sender: Any?) {
        helpHandler?(.shortcuts)
    }

    private func configureEditMenu(in mainMenu: NSMenu?) {
        guard let editMenu = Self.editMenu(in: mainMenu) else { return }
        editMenuDelegateProxy.mainMenu = mainMenu
        if editMenu.delegate !== editMenuDelegateProxy {
            editMenuDelegateProxy.originalDelegate = editMenu.delegate
            editMenu.delegate = editMenuDelegateProxy
        }
    }

    package func hideGeneratedFileItems(in mainMenu: NSMenu?) {
        hideGeneratedNewSubmenu(in: mainMenu)
        guard let fileMenu = Self.fileMenu(in: mainMenu) else { return }
        fileMenu.items
            .filter { item in
                item.title.replacingOccurrences(of: "…", with: "") == "Save"
                    || item.title == "Duplicate"
                    || (item.title == "Share" && item.submenu != nil)
            }
            .forEach { fileMenu.removeItem($0) }
        Self.removeRedundantSeparators(in: fileMenu)
        updateReopenLastSessionItem(in: fileMenu)
    }

    package func hideIrrelevantReadOnlyEditItems(in mainMenu: NSMenu?) {
        guard let editMenu = Self.editMenu(in: mainMenu) else { return }
        editMenu.items
            .filter { Self.isIrrelevantReadOnlyEditItem($0) }
            .forEach { editMenu.removeItem($0) }
        Self.removeRedundantSeparators(in: editMenu)
    }

    @IBAction package func reopenWindowsFromLastSession(_ sender: Any?) {
        documentRestorationController?.reopenLastSession()
    }

    @IBAction package func closeFocusedWindow(_ sender: Any?) {
        focusedWindowProvider()?.performClose(sender)
    }

    package func installCloseWindowItem(in fileMenu: NSMenu) {
        let closeItems = fileMenu.items.filter { item in
            item.identifier == Self.closeWindowIdentifier
                || item.title.replacingOccurrences(of: "…", with: "") == "Close"
        }
        let item: NSMenuItem
        if let managed = closeItems.first(where: {
            $0.identifier == Self.closeWindowIdentifier
        }) {
            item = managed
        } else if let generated = closeItems.first {
            item = generated
        } else {
            item = NSMenuItem(title: "Close", action: nil, keyEquivalent: "w")
            let reopenIndex = fileMenu.items.firstIndex(where: {
                $0.identifier == Self.reopenLastSessionIdentifier
            })
            let openRecentIndex = fileMenu.items.firstIndex(where: { menuItem in
                menuItem.title == "Open Recent" || menuItem.submenu?.title == "Open Recent"
            })
            fileMenu.insertItem(
                item,
                at: min((reopenIndex ?? openRecentIndex ?? -1) + 1, fileMenu.items.count)
            )
        }

        closeItems
            .filter { $0 !== item }
            .forEach { fileMenu.removeItem($0) }
        item.title = "Close"
        item.identifier = Self.closeWindowIdentifier
        item.target = self
        item.action = #selector(closeFocusedWindow(_:))
        item.keyEquivalent = "w"
        item.keyEquivalentModifierMask = .command
        item.isEnabled = focusedWindowProvider()?.styleMask.contains(.closable) == true
    }

    package func installReopenLastSessionItem(in fileMenu: NSMenu) {
        let item: NSMenuItem
        if let existing = fileMenu.items.first(where: {
            $0.identifier == Self.reopenLastSessionIdentifier
        }) {
            item = existing
        } else {
            item = NSMenuItem(
                title: "Reopen Windows from Last Session",
                action: #selector(reopenWindowsFromLastSession(_:)),
                keyEquivalent: ""
            )
            item.identifier = Self.reopenLastSessionIdentifier
            item.target = self
            let openRecentIndex = fileMenu.items.firstIndex(where: { menuItem in
                menuItem.title == "Open Recent" || menuItem.submenu?.title == "Open Recent"
            })
            fileMenu.insertItem(item, at: min((openRecentIndex ?? -1) + 1, fileMenu.items.count))
        }
        updateReopenLastSessionItem(in: fileMenu)
    }

    private func updateReopenLastSessionItem(in fileMenu: NSMenu) {
        fileMenu.items.first(where: {
            $0.identifier == Self.reopenLastSessionIdentifier
        })?.isEnabled = documentRestorationController?.canReopenLastSession == true
    }

    public func applicationDidUpdate(_ notification: Notification) {
        configureFileMenu(in: NSApp.mainMenu)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard notification.object is NSMenu else { return }
        configureFileMenu(in: NSApp.mainMenu)
    }

    private static func fileMenu(in mainMenu: NSMenu?) -> NSMenu? {
        mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.title == "File" || menu.items.contains { item in
                item.keyEquivalent.lowercased() == "o" && item.title.hasPrefix("Open")
            }
        })
    }

    private static func editMenu(in mainMenu: NSMenu?) -> NSMenu? {
        mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.title == "Edit" || menu.items.contains { item in
                item.keyEquivalent.lowercased() == "c" && item.title == "Copy"
            }
        })
    }

    private static func helpMenu(in mainMenu: NSMenu?) -> NSMenu? {
        mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.title == "Help" || menu.items.contains { item in
                item.action == #selector(NSApplication.showHelp(_:))
            }
        })
    }

    private static func isIrrelevantReadOnlyEditItem(_ item: NSMenuItem) -> Bool {
        let title = item.title.replacingOccurrences(of: "…", with: "")
        if title.hasPrefix("Undo") || title.hasPrefix("Redo") {
            return true
        }
        return [
            "Cut", "Paste", "Delete", "Writing Tools", "Spelling and Grammar",
            "Substitutions", "Transformations", "Speech", "AutoFill", "Start Dictation",
            "Emoji & Symbols"
        ].contains(title)
    }

    private static func removeRedundantSeparators(in menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        var index = menu.items.count - 1
        while index > 0 {
            if menu.items[index].isSeparatorItem,
               menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
            index -= 1
        }
    }
}

@MainActor
private final class FileMenuDelegateProxy: NSObject, NSMenuDelegate {
    weak var owner: ApplicationLifecycleDelegate?
    weak var mainMenu: NSMenu?
    var originalDelegate: NSMenuDelegate?

    init(owner: ApplicationLifecycleDelegate) {
        self.owner = owner
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        originalDelegate?.menuNeedsUpdate?(menu)
        owner?.configureFileMenu(in: mainMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        originalDelegate?.menuWillOpen?(menu)
        owner?.configureFileMenu(in: mainMenu)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

@MainActor
private final class EditMenuDelegateProxy: NSObject, NSMenuDelegate {
    weak var owner: ApplicationLifecycleDelegate?
    weak var mainMenu: NSMenu?
    var originalDelegate: NSMenuDelegate?

    init(owner: ApplicationLifecycleDelegate) {
        self.owner = owner
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        originalDelegate?.menuNeedsUpdate?(menu)
        owner?.hideIrrelevantReadOnlyEditItems(in: mainMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        originalDelegate?.menuWillOpen?(menu)
        owner?.hideIrrelevantReadOnlyEditItems(in: mainMenu)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

@MainActor
private final class HelpMenuDelegateProxy: NSObject, NSMenuDelegate {
    weak var owner: ApplicationLifecycleDelegate?
    weak var mainMenu: NSMenu?
    var originalDelegate: NSMenuDelegate?

    init(owner: ApplicationLifecycleDelegate) {
        self.owner = owner
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        originalDelegate?.menuNeedsUpdate?(menu)
        owner?.configureHelpMenu(in: mainMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        originalDelegate?.menuWillOpen?(menu)
        owner?.configureHelpMenu(in: mainMenu)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: selector)
    }
}

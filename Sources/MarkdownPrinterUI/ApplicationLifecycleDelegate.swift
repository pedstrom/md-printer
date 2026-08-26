import AppKit

@MainActor
public final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    package var newTabHandler: (() -> Void)?
    package weak var documentRestorationController: OpenDocumentRestorationController?
    package var normalTerminationHandler: (() -> Void)?
    private static let reopenLastSessionIdentifier = NSUserInterfaceItemIdentifier(
        "com.peteedstrom.markdown-printer.reopen-last-session"
    )
    private lazy var fileMenuDelegateProxy = FileMenuDelegateProxy(owner: self)

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
        guard let fileMenu = Self.fileMenu(in: mainMenu) else { return }
        fileMenuDelegateProxy.mainMenu = mainMenu
        if fileMenu.delegate !== fileMenuDelegateProxy {
            fileMenuDelegateProxy.originalDelegate = fileMenu.delegate
            fileMenu.delegate = fileMenuDelegateProxy
        }
        hideGeneratedFileItems(in: mainMenu)
        installReopenLastSessionItem(in: fileMenu)
    }

    package func hideGeneratedFileItems(in mainMenu: NSMenu?) {
        hideGeneratedNewSubmenu(in: mainMenu)
        guard let fileMenu = Self.fileMenu(in: mainMenu) else { return }
        fileMenu.items
            .filter { $0.title == "Duplicate" }
            .forEach { fileMenu.removeItem($0) }
        updateReopenLastSessionItem(in: fileMenu)
    }

    @IBAction package func reopenWindowsFromLastSession(_ sender: Any?) {
        documentRestorationController?.reopenLastSession()
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
        owner?.hideGeneratedFileItems(in: mainMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        originalDelegate?.menuWillOpen?(menu)
        owner?.hideGeneratedFileItems(in: mainMenu)
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

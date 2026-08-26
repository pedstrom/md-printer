import AppKit

@MainActor
public final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    package var newTabHandler: (() -> Void)?
    private lazy var fileMenuDelegateProxy = FileMenuDelegateProxy(owner: self)

    public func applicationDidFinishLaunching(_ notification: Notification) {
        configureFileMenu(in: NSApp.mainMenu)
        DispatchQueue.main.async { [weak self] in
            self?.configureFileMenu(in: NSApp.mainMenu)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
    }

    package func configureFileMenu(in mainMenu: NSMenu?) {
        guard let fileMenu = Self.fileMenu(in: mainMenu) else { return }
        fileMenuDelegateProxy.mainMenu = mainMenu
        if fileMenu.delegate !== fileMenuDelegateProxy {
            fileMenuDelegateProxy.originalDelegate = fileMenu.delegate
            fileMenu.delegate = fileMenuDelegateProxy
        }
        hideGeneratedNewSubmenu(in: mainMenu)
    }

    public func applicationDidUpdate(_ notification: Notification) {
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
        owner?.hideGeneratedNewSubmenu(in: mainMenu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        originalDelegate?.menuWillOpen?(menu)
        owner?.hideGeneratedNewSubmenu(in: mainMenu)
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

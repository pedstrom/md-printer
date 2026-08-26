import AppKit
import Combine

@MainActor
package final class WindowTabCoordinator: ObservableObject {
    package let tabbingIdentifier: String

    @Published package private(set) var tabBarCommandTitle = "Show Tab Bar"
    @Published package private(set) var canToggleTabBar = false

    package var newTabRequestHandler: ((NSWindow?) -> Void)?

    private final class WeakWindow {
        weak var value: NSWindow?

        init(_ value: NSWindow?) {
            self.value = value
        }
    }

    private final class PendingDocumentTabSource {
        let requestIdentifier: UUID
        weak var window: NSWindow?

        init(requestIdentifier: UUID, window: NSWindow) {
            self.requestIdentifier = requestIdentifier
            self.window = window
        }
    }

    private var pendingTabSources: [UUID: WeakWindow] = [:]
    private var welcomeWindows: [UUID: WeakWindow] = [:]
    private var pendingDocumentTabSources: [URL: [PendingDocumentTabSource]] = [:]
    private weak var activeWindow: NSWindow?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabWindowsObservation: NSKeyValueObservation?

    package init() {
        tabbingIdentifier = "com.peteedstrom.markdown-printer.documents.\(UUID())"
    }

    deinit {
        tabWindowsObservation?.invalidate()
    }

    package func prepareNewTab(from preferredWindow: NSWindow?) -> UUID {
        let identifier = UUID()
        pendingTabSources[identifier] = WeakWindow(tabSource(preferredWindow))
        return identifier
    }

    package func requestNewTab(from preferredWindow: NSWindow?) {
        newTabRequestHandler?(preferredWindow)
    }

    package func prepareDocumentTab(
        for documentURL: URL,
        replacingWelcomeWindow identifier: UUID
    ) -> UUID? {
        guard let sourceWindow = welcomeWindows[identifier]?.value else { return nil }
        let requestIdentifier = UUID()
        let key = documentURL.standardizedFileURL
        pendingDocumentTabSources[key, default: []].append(
            PendingDocumentTabSource(
                requestIdentifier: requestIdentifier,
                window: sourceWindow
            )
        )
        return requestIdentifier
    }

    package func cancelDocumentTabRequest(_ requestIdentifier: UUID, for documentURL: URL) {
        let key = documentURL.standardizedFileURL
        guard var sources = pendingDocumentTabSources[key] else { return }
        sources.removeAll { $0.requestIdentifier == requestIdentifier }
        pendingDocumentTabSources[key] = sources.isEmpty ? nil : sources
    }

    package func attach(
        window: NSWindow,
        identifier: UUID? = nil,
        documentURL: URL? = nil
    ) {
        window.tabbingIdentifier = tabbingIdentifier
        if let identifier {
            welcomeWindows[identifier] = WeakWindow(window)
        }

        let sourceWindow: NSWindow?
        if let identifier {
            sourceWindow = pendingTabSources.removeValue(forKey: identifier)?.value
        } else if let documentURL {
            sourceWindow = takeDocumentTabSource(for: documentURL)
        } else {
            sourceWindow = nil
        }

        if let sourceWindow, sourceWindow !== window {
            sourceWindow.addTabbedWindow(window, ordered: .above)
            sourceWindow.tabGroup?.selectedWindow = window
        }

        if window.isKeyWindow || sourceWindow != nil {
            activate(window: window)
        }
    }

    package func activate(window: NSWindow?) {
        guard isTabbable(window) else {
            activeWindow = nil
            observe(tabGroup: nil)
            refreshCommandState()
            return
        }
        activeWindow = window
        observe(tabGroup: window?.tabGroup)
        refreshCommandState()
    }

    @discardableResult
    package func toggleTabBar(for preferredWindow: NSWindow?) -> Bool {
        guard let window = tabSource(preferredWindow), canToggleTabBar(for: window) else {
            return false
        }
        NSApp.sendAction(#selector(NSWindow.toggleTabBar(_:)), to: window, from: nil)
        activeWindow = window
        refreshCommandState()
        return true
    }

    package func isTabbable(_ window: NSWindow?) -> Bool {
        window?.tabbingIdentifier == tabbingIdentifier
    }

    private func tabSource(_ preferredWindow: NSWindow?) -> NSWindow? {
        if isTabbable(preferredWindow) {
            return preferredWindow
        }
        if isTabbable(activeWindow) {
            return activeWindow
        }
        return nil
    }

    private func takeDocumentTabSource(for documentURL: URL) -> NSWindow? {
        let key = documentURL.standardizedFileURL
        guard var sources = pendingDocumentTabSources[key] else { return nil }
        var sourceWindow: NSWindow?
        while sourceWindow == nil, !sources.isEmpty {
            sourceWindow = sources.removeFirst().window
        }
        pendingDocumentTabSources[key] = sources.isEmpty ? nil : sources
        return sourceWindow
    }

    private func refreshCommandState() {
        let isTabBarVisible = activeWindow?.tabGroup?.isTabBarVisible == true
        canToggleTabBar = activeWindow.map(canToggleTabBar(for:)) ?? false
        tabBarCommandTitle = isTabBarVisible
            ? "Hide Tab Bar"
            : "Show Tab Bar"
    }

    private func observe(tabGroup: NSWindowTabGroup?) {
        guard observedTabGroup !== tabGroup else { return }
        tabWindowsObservation?.invalidate()
        tabWindowsObservation = nil
        observedTabGroup = tabGroup
        guard let tabGroup else { return }
        tabWindowsObservation = tabGroup.observe(\.windows, options: [.new]) {
            [weak self] group, _ in
            MainActor.assumeIsolated {
                self?.activeWindow = group.selectedWindow
                self?.refreshCommandState()
            }
        }
    }

    private func canToggleTabBar(for window: NSWindow) -> Bool {
        let tabGroup = window.tabGroup
        return tabGroup?.isTabBarVisible != true || tabGroup?.windows.count == 1
    }
}

@MainActor
package final class WindowTabCommandResponder: NSResponder {
    private weak var coordinator: WindowTabCoordinator?
    private weak var sourceWindow: NSWindow?

    package init(coordinator: WindowTabCoordinator, sourceWindow: NSWindow) {
        self.coordinator = coordinator
        self.sourceWindow = sourceWindow
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    package override func newWindowForTab(_ sender: Any?) {
        coordinator?.requestNewTab(from: sourceWindow)
    }
}

@MainActor
package final class WindowTabAttachmentHostView: NSView {
    package var coordinator: WindowTabCoordinator
    package var windowIdentifier: UUID?
    package var documentURL: URL?
    private weak var attachedWindow: NSWindow?
    private weak var responderParent: NSResponder?
    private var tabCommandResponder: WindowTabCommandResponder?

    package init(
        coordinator: WindowTabCoordinator,
        windowIdentifier: UUID?,
        documentURL: URL? = nil
    ) {
        self.coordinator = coordinator
        self.windowIdentifier = windowIdentifier
        self.documentURL = documentURL
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachCurrentWindow()
        DispatchQueue.main.async { [weak self] in
            self?.attachCurrentWindow()
        }
    }

    package func attachCurrentWindow() {
        if attachedWindow === window {
            if let responder = tabCommandResponder,
               responderParent?.nextResponder !== responder {
                removeTabCommandResponder()
            }
            if tabCommandResponder == nil, let window {
                installTabCommandResponder(for: window)
            }
            return
        }
        removeTabCommandResponder()
        NotificationCenter.default.removeObserver(self)
        attachedWindow = window
        guard let window else { return }
        coordinator.attach(
            window: window,
            identifier: windowIdentifier,
            documentURL: documentURL
        )
        installTabCommandResponder(for: window)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        coordinator.activate(window: notification.object as? NSWindow)
    }

    private func installTabCommandResponder(for window: NSWindow) {
        let responder = WindowTabCommandResponder(
            coordinator: coordinator,
            sourceWindow: window
        )
        responder.nextResponder = window.nextResponder
        window.nextResponder = responder
        responderParent = window
        tabCommandResponder = responder
    }

    private func removeTabCommandResponder() {
        guard let responder = tabCommandResponder else { return }
        if responderParent?.nextResponder === responder {
            responderParent?.nextResponder = responder.nextResponder
        }
        responder.nextResponder = nil
        tabCommandResponder = nil
        responderParent = nil
    }
}

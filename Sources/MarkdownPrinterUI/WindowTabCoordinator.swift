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

    private final class AttachedWindowRecord {
        weak var window: NSWindow?
        var welcomeIdentifier: UUID?
        var documentURL: URL?

        init(window: NSWindow, welcomeIdentifier: UUID?, documentURL: URL?) {
            self.window = window
            self.welcomeIdentifier = welcomeIdentifier
            self.documentURL = documentURL?.standardizedFileURL
        }
    }

    private struct PendingWorkspaceTarget {
        let groupIdentifier: String
        let isSelected: Bool
        let isTabBarVisible: Bool
    }

    private var pendingTabSources: [UUID: WeakWindow] = [:]
    private var welcomeWindows: [UUID: WeakWindow] = [:]
    private var pendingDocumentTabSources: [URL: [PendingDocumentTabSource]] = [:]
    private var attachedWindows: [ObjectIdentifier: AttachedWindowRecord] = [:]
    private var attachedWindowOrder: [ObjectIdentifier] = []
    private var pendingWorkspaceDocuments: [URL: [PendingWorkspaceTarget]] = [:]
    private var pendingWorkspaceWelcomes: [UUID: PendingWorkspaceTarget] = [:]
    private var restoredGroupAnchors: [String: WeakWindow] = [:]
    private var restoredGroupSelections: [String: WeakWindow] = [:]
    private var restoredGroupTabBarVisibility: [String: Bool] = [:]
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

        registerAttachedWindow(
            window,
            welcomeIdentifier: identifier,
            documentURL: documentURL
        )

        let workspaceTarget = documentURL.flatMap(takeWorkspaceTarget(for:))
            ?? identifier.flatMap { pendingWorkspaceWelcomes.removeValue(forKey: $0) }
        let sourceWindow: NSWindow?
        if let workspaceTarget {
            sourceWindow = restoredGroupAnchors[workspaceTarget.groupIdentifier]?.value
        } else if let identifier {
            sourceWindow = pendingTabSources.removeValue(forKey: identifier)?.value
        } else if let documentURL {
            sourceWindow = takeDocumentTabSource(for: documentURL)
        } else {
            sourceWindow = nil
        }

        if let sourceWindow, sourceWindow !== window {
            sourceWindow.addTabbedWindow(window, ordered: .above)
            if workspaceTarget == nil {
                sourceWindow.tabGroup?.selectedWindow = window
            }
        }

        if let workspaceTarget {
            restoredGroupAnchors[workspaceTarget.groupIdentifier] = WeakWindow(
                window
            )
            restoredGroupTabBarVisibility[workspaceTarget.groupIdentifier] =
                workspaceTarget.isTabBarVisible
            if workspaceTarget.isSelected {
                restoredGroupSelections[workspaceTarget.groupIdentifier] = WeakWindow(window)
            }
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

    package func captureWorkspace(
        restorationController: OpenDocumentRestorationController
    ) -> WorkspaceSnapshot {
        removeReleasedWindowRecords()
        var processedWindows: Set<ObjectIdentifier> = []
        var groups: [WorkspaceWindowGroup] = []

        for identifier in attachedWindowOrder {
            guard !processedWindows.contains(identifier),
                  let window = attachedWindows[identifier]?.window
            else { continue }
            let groupWindows = window.tabGroup?.windows ?? [window]
            groupWindows.forEach { processedWindows.insert(ObjectIdentifier($0)) }

            var tabs: [WorkspaceTabRecord] = []
            var selectedTabIndex = 0
            for groupWindow in groupWindows {
                guard let record = attachedWindows[ObjectIdentifier(groupWindow)] else { continue }
                let tab: WorkspaceTabRecord?
                if let url = record.documentURL {
                    tab = .document(
                        url,
                        state: restorationController.currentWindowState(for: url)
                    )
                } else if record.welcomeIdentifier != nil {
                    tab = .welcome
                } else {
                    tab = nil
                }
                guard let tab else { continue }
                if groupWindow === window.tabGroup?.selectedWindow ||
                    (window.tabGroup == nil && groupWindow === window) {
                    selectedTabIndex = tabs.count
                }
                tabs.append(tab)
            }

            guard tabs.contains(where: { $0.kind == .document }) else { continue }
            groups.append(WorkspaceWindowGroup(
                identifier: "workspace-\(groups.count)",
                tabs: tabs,
                selectedTabIndex: selectedTabIndex,
                isTabBarVisible: window.tabGroup?.isTabBarVisible == true
            ))
        }
        return WorkspaceSnapshot(groups: groups)
    }

    package func prepareWorkspaceDocument(
        at url: URL,
        groupIdentifier: String,
        isSelected: Bool,
        isTabBarVisible: Bool
    ) {
        pendingWorkspaceDocuments[url.standardizedFileURL, default: []].append(
            PendingWorkspaceTarget(
                groupIdentifier: groupIdentifier,
                isSelected: isSelected,
                isTabBarVisible: isTabBarVisible
            )
        )
    }

    package func cancelWorkspaceDocument(at url: URL, groupIdentifier: String) {
        let key = url.standardizedFileURL
        guard var targets = pendingWorkspaceDocuments[key] else { return }
        if let index = targets.firstIndex(where: { $0.groupIdentifier == groupIdentifier }) {
            targets.remove(at: index)
        }
        pendingWorkspaceDocuments[key] = targets.isEmpty ? nil : targets
    }

    package func useOpenDocument(
        at url: URL,
        groupIdentifier: String,
        isSelected: Bool,
        isTabBarVisible: Bool
    ) {
        guard let window = attachedWindow(for: url) else { return }
        if let sourceWindow = restoredGroupAnchors[groupIdentifier]?.value,
           sourceWindow !== window {
            sourceWindow.addTabbedWindow(window, ordered: .above)
        }
        restoredGroupAnchors[groupIdentifier] = WeakWindow(window)
        restoredGroupTabBarVisibility[groupIdentifier] = isTabBarVisible
        if isSelected {
            restoredGroupSelections[groupIdentifier] = WeakWindow(window)
        }
    }

    package func prepareWorkspaceWelcome(
        groupIdentifier: String,
        isSelected: Bool,
        isTabBarVisible: Bool
    ) -> UUID {
        let identifier = UUID()
        pendingWorkspaceWelcomes[identifier] = PendingWorkspaceTarget(
            groupIdentifier: groupIdentifier,
            isSelected: isSelected,
            isTabBarVisible: isTabBarVisible
        )
        return identifier
    }

    package func finishWorkspaceRestoration() {
        for (groupIdentifier, anchor) in restoredGroupAnchors {
            guard let window = anchor.value else { continue }
            if let selected = restoredGroupSelections[groupIdentifier]?.value {
                window.tabGroup?.selectedWindow = selected
            }
            let wantsVisible = restoredGroupTabBarVisibility[groupIdentifier] == true
            let isVisible = window.tabGroup?.isTabBarVisible == true
            if wantsVisible != isVisible, window.tabGroup != nil {
                NSApp.sendAction(#selector(NSWindow.toggleTabBar(_:)), to: window, from: nil)
            }
        }
        pendingWorkspaceDocuments.removeAll()
        pendingWorkspaceWelcomes.removeAll()
        restoredGroupAnchors.removeAll()
        restoredGroupSelections.removeAll()
        restoredGroupTabBarVisibility.removeAll()
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

    private func takeWorkspaceTarget(for documentURL: URL) -> PendingWorkspaceTarget? {
        let key = documentURL.standardizedFileURL
        guard var targets = pendingWorkspaceDocuments[key], !targets.isEmpty else { return nil }
        let target = targets.removeFirst()
        pendingWorkspaceDocuments[key] = targets.isEmpty ? nil : targets
        return target
    }

    private func registerAttachedWindow(
        _ window: NSWindow,
        welcomeIdentifier: UUID?,
        documentURL: URL?
    ) {
        let identifier = ObjectIdentifier(window)
        if let record = attachedWindows[identifier] {
            record.welcomeIdentifier = welcomeIdentifier ?? record.welcomeIdentifier
            record.documentURL = documentURL?.standardizedFileURL ?? record.documentURL
        } else {
            attachedWindows[identifier] = AttachedWindowRecord(
                window: window,
                welcomeIdentifier: welcomeIdentifier,
                documentURL: documentURL
            )
            attachedWindowOrder.append(identifier)
        }
    }

    private func attachedWindow(for documentURL: URL) -> NSWindow? {
        let key = documentURL.standardizedFileURL
        return attachedWindowOrder.compactMap { attachedWindows[$0] }.first {
            $0.documentURL == key && $0.window != nil
        }?.window
    }

    private func removeReleasedWindowRecords() {
        attachedWindows = attachedWindows.filter { $0.value.window != nil }
        attachedWindowOrder.removeAll { attachedWindows[$0] == nil }
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

import Combine
import Foundation
import MarkdownPrinterCore

package struct PersistedPreviewScrollPosition: Equatable {
    let offset: CGPoint
    let documentSize: CGSize
    let viewportSize: CGSize

    fileprivate var propertyList: [Double] {
        [Double(offset.x), Double(offset.y), Double(documentSize.width),
         Double(documentSize.height), Double(viewportSize.width), Double(viewportSize.height)]
    }

    fileprivate init?(propertyList: [Double]) {
        guard propertyList.count == 6,
              propertyList.allSatisfy(\.isFinite),
              propertyList[2...5].allSatisfy({ $0 > 0 })
        else { return nil }
        self.init(offset: CGPoint(x: propertyList[0], y: propertyList[1]),
                  documentSize: CGSize(width: propertyList[2], height: propertyList[3]),
                  viewportSize: CGSize(width: propertyList[4], height: propertyList[5]))
    }

    package init(offset: CGPoint, documentSize: CGSize, viewportSize: CGSize) {
        self.offset = offset
        self.documentSize = documentSize
        self.viewportSize = viewportSize
    }
}

package struct PersistedPreviewViewport: Equatable {
    let scaleFactor: Double
    let pageIndex: Int
    let normalizedPageX: Double
    let normalizedPageY: Double
    let documentProgress: Double
    let scrollPosition: PersistedPreviewScrollPosition?

    fileprivate var propertyList: [String: Any] {
        var result: [String: Any] = [
            "scaleFactor": scaleFactor,
            "pageIndex": pageIndex,
            "normalizedPageX": normalizedPageX,
            "normalizedPageY": normalizedPageY,
            "documentProgress": documentProgress
        ]
        if let scrollPosition {
            result["scrollPosition"] = scrollPosition.propertyList
        }
        return result
    }

    fileprivate init?(propertyList: [String: Any]) {
        guard
            let scaleFactor = propertyList["scaleFactor"] as? Double,
            let pageIndex = propertyList["pageIndex"] as? Int,
            let normalizedPageX = propertyList["normalizedPageX"] as? Double,
            let normalizedPageY = propertyList["normalizedPageY"] as? Double,
            let documentProgress = propertyList["documentProgress"] as? Double,
            scaleFactor.isFinite,
            scaleFactor > 0,
            pageIndex >= 0,
            normalizedPageX.isFinite,
            (0...1).contains(normalizedPageX),
            normalizedPageY.isFinite,
            (0...1).contains(normalizedPageY),
            documentProgress.isFinite,
            (0...1).contains(documentProgress)
        else { return nil }

        self.scaleFactor = scaleFactor
        self.pageIndex = pageIndex
        self.normalizedPageX = normalizedPageX
        self.normalizedPageY = normalizedPageY
        self.documentProgress = documentProgress
        scrollPosition = (propertyList["scrollPosition"] as? [Double]).flatMap(
            PersistedPreviewScrollPosition.init(propertyList:)
        )
    }

    package init(
        scaleFactor: Double,
        pageIndex: Int,
        normalizedPageX: Double,
        normalizedPageY: Double,
        documentProgress: Double,
        scrollPosition: PersistedPreviewScrollPosition? = nil
    ) {
        self.scaleFactor = scaleFactor
        self.pageIndex = pageIndex
        self.normalizedPageX = normalizedPageX
        self.normalizedPageY = normalizedPageY
        self.documentProgress = documentProgress
        self.scrollPosition = scrollPosition
    }
}

package struct PersistedThumbnailSidebar: Equatable {
    let isVisible: Bool
    let width: Double
    let scrollOffset: Double

    package init(isVisible: Bool, width: Double, scrollOffset: Double) {
        self.isVisible = isVisible
        self.width = min(max(width, 120), 260)
        self.scrollOffset = max(scrollOffset, 0)
    }

    fileprivate var propertyList: [String: Any] {
        [
            "isVisible": isVisible,
            "width": width,
            "scrollOffset": scrollOffset
        ]
    }

    fileprivate init?(propertyList: [String: Any]) {
        guard let isVisible = propertyList["isVisible"] as? Bool,
              let width = propertyList["width"] as? Double,
              let scrollOffset = propertyList["scrollOffset"] as? Double,
              width.isFinite,
              scrollOffset.isFinite
        else { return nil }
        self.init(isVisible: isVisible, width: width, scrollOffset: scrollOffset)
    }
}

package struct DocumentWindowRestorationState: Equatable {
    let frame: CGRect?
    let viewport: PersistedPreviewViewport?
    let thumbnails: PersistedThumbnailSidebar?
    let explicitPageSetup: DocumentPageSetup?
    let originalSnapshotID: UUID?

    package init(
        frame: CGRect?,
        viewport: PersistedPreviewViewport?,
        thumbnails: PersistedThumbnailSidebar? = nil,
        explicitPageSetup: DocumentPageSetup? = nil,
        originalSnapshotID: UUID? = nil
    ) {
        self.frame = frame
        self.viewport = viewport
        self.thumbnails = thumbnails
        self.explicitPageSetup = explicitPageSetup
        self.originalSnapshotID = originalSnapshotID
    }

    fileprivate var propertyList: [String: Any] {
        var result: [String: Any] = [:]
        if let frame {
            result["frame"] = [
                Double(frame.origin.x),
                Double(frame.origin.y),
                Double(frame.size.width),
                Double(frame.size.height)
            ]
        }
        if let viewport {
            result["viewport"] = viewport.propertyList
        }
        if let thumbnails {
            result["thumbnails"] = thumbnails.propertyList
        }
        if let originalSnapshotID { result["originalSnapshotID"] = originalSnapshotID.uuidString }
        if let explicitPageSetup,
           let data = try? JSONEncoder().encode(explicitPageSetup) {
            result["pageSetup"] = data
        }
        return result
    }

    fileprivate init(propertyList: [String: Any]) {
        if let values = propertyList["frame"] as? [Double],
           values.count == 4,
           values.allSatisfy(\.isFinite),
           values[2] > 0,
           values[3] > 0 {
            frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        } else {
            frame = nil
        }
        viewport = (propertyList["viewport"] as? [String: Any]).flatMap(
            PersistedPreviewViewport.init(propertyList:)
        )
        thumbnails = (propertyList["thumbnails"] as? [String: Any]).flatMap(
            PersistedThumbnailSidebar.init(propertyList:)
        )
        originalSnapshotID = (propertyList["originalSnapshotID"] as? String).flatMap(UUID.init(uuidString:))
        explicitPageSetup = (propertyList["pageSetup"] as? Data).flatMap {
            try? JSONDecoder().decode(DocumentPageSetup.self, from: $0)
        }
    }
}

package struct WorkspaceTabRecord: Equatable {
    package enum Kind: String {
        case document
        case welcome
    }

    let kind: Kind
    let documentURL: URL?
    let windowState: DocumentWindowRestorationState?

    package static func document(
        _ url: URL,
        state: DocumentWindowRestorationState?
    ) -> Self {
        Self(kind: .document, documentURL: url.standardizedFileURL, windowState: state)
    }

    package static let welcome = Self(kind: .welcome, documentURL: nil, windowState: nil)

    fileprivate var propertyList: [String: Any] {
        var result: [String: Any] = ["kind": kind.rawValue]
        if let documentURL {
            result["path"] = documentURL.path
        }
        if let windowState {
            result["state"] = windowState.propertyList
        }
        return result
    }

    fileprivate init?(propertyList: [String: Any]) {
        guard let rawKind = propertyList["kind"] as? String,
              let kind = Kind(rawValue: rawKind)
        else { return nil }
        switch kind {
        case .document:
            guard let path = propertyList["path"] as? String else { return nil }
            self.kind = kind
            documentURL = URL(fileURLWithPath: path).standardizedFileURL
            windowState = (propertyList["state"] as? [String: Any]).map(
                DocumentWindowRestorationState.init(propertyList:)
            )
        case .welcome:
            self = .welcome
        }
    }

    private init(
        kind: Kind,
        documentURL: URL?,
        windowState: DocumentWindowRestorationState?
    ) {
        self.kind = kind
        self.documentURL = documentURL
        self.windowState = windowState
    }
}

package struct WorkspaceWindowGroup: Equatable {
    let identifier: String
    let tabs: [WorkspaceTabRecord]
    let selectedTabIndex: Int
    let isTabBarVisible: Bool

    package init(
        identifier: String,
        tabs: [WorkspaceTabRecord],
        selectedTabIndex: Int,
        isTabBarVisible: Bool
    ) {
        self.identifier = identifier
        self.tabs = tabs
        self.selectedTabIndex = tabs.indices.contains(selectedTabIndex) ? selectedTabIndex : 0
        self.isTabBarVisible = isTabBarVisible
    }

    fileprivate var propertyList: [String: Any] {
        [
            "identifier": identifier,
            "tabs": tabs.map(\.propertyList),
            "selectedTabIndex": selectedTabIndex,
            "isTabBarVisible": isTabBarVisible
        ]
    }

    fileprivate init?(propertyList: [String: Any]) {
        guard let identifier = propertyList["identifier"] as? String,
              let storedTabs = propertyList["tabs"] as? [[String: Any]],
              let selectedTabIndex = propertyList["selectedTabIndex"] as? Int,
              let isTabBarVisible = propertyList["isTabBarVisible"] as? Bool
        else { return nil }
        let tabs = storedTabs.compactMap(WorkspaceTabRecord.init(propertyList:))
        guard !tabs.isEmpty, tabs.contains(where: { $0.kind == .document }) else { return nil }
        self.init(
            identifier: identifier,
            tabs: tabs,
            selectedTabIndex: selectedTabIndex,
            isTabBarVisible: isTabBarVisible
        )
    }
}

package struct WorkspaceSnapshot: Equatable {
    package static let currentVersion = 1

    let version: Int
    let groups: [WorkspaceWindowGroup]

    package init(groups: [WorkspaceWindowGroup], version: Int = currentVersion) {
        self.version = version
        self.groups = groups.filter { group in
            group.tabs.contains(where: { $0.kind == .document })
        }
    }

    package var documentURLs: [URL] {
        groups.flatMap(\.tabs).compactMap(\.documentURL)
    }

    fileprivate var propertyList: [String: Any] {
        ["version": version, "groups": groups.map(\.propertyList)]
    }

    fileprivate init?(propertyList: [String: Any]) {
        guard let version = propertyList["version"] as? Int,
              version == Self.currentVersion,
              let storedGroups = propertyList["groups"] as? [[String: Any]]
        else { return nil }
        self.init(
            groups: storedGroups.compactMap(WorkspaceWindowGroup.init(propertyList:)),
            version: version
        )
    }
}

@MainActor
public final class OpenDocumentRestorationController: ObservableObject {
    package static let pendingRelaunchKey = "pendingUpdateDocumentRestoration"
    package static let lastSessionKey = "lastDocumentWorkspace"

    @Published package private(set) var canReopenLastSession = false
    package var workspaceCaptureProvider: (() -> WorkspaceSnapshot)?
    package var reopenLastSessionHandler: (() -> Void)?

    private struct StateProviderRegistration {
        let id: UUID
        let provider: () -> DocumentWindowRestorationState?
    }

    private let defaults: UserDefaults
    private let originalCoordinator: DocumentOriginalCoordinator
    private let collectsOriginals: Bool
    private var openDocumentCounts: [URL: Int] = [:]
    private var stateProviders: [URL: [StateProviderRegistration]] = [:]
    private var pendingWindowStates: [URL: DocumentWindowRestorationState] = [:]
    private var isPreparingUpdateRelaunch = false

    public init(defaults: UserDefaults = .standard, originalCoordinator: DocumentOriginalCoordinator? = nil) {
        self.defaults = defaults
        self.originalCoordinator = originalCoordinator ?? .shared
        collectsOriginals = originalCoordinator != nil || defaults === UserDefaults.standard
        refreshReopenAvailability()
    }

    public func documentDidOpen(at url: URL?) {
        guard let url = normalizedFileURL(url) else { return }
        openDocumentCounts[url, default: 0] += 1
        refreshReopenAvailability()
    }

    public func documentDidClose(at url: URL?) {
        guard let url = normalizedFileURL(url), let count = openDocumentCounts[url] else { return }
        if count > 1 {
            openDocumentCounts[url] = count - 1
        } else {
            openDocumentCounts.removeValue(forKey: url)
        }
        refreshReopenAvailability()
    }

    public func isDocumentOpen(at url: URL) -> Bool {
        guard let url = normalizedFileURL(url) else { return false }
        return openDocumentCounts[url] != nil
    }

    package func registerStateProvider(
        at url: URL?,
        id: UUID,
        provider: @escaping () -> DocumentWindowRestorationState?
    ) {
        guard let url = normalizedFileURL(url) else { return }
        var registrations = stateProviders[url, default: []]
        registrations.removeAll { $0.id == id }
        registrations.append(StateProviderRegistration(id: id, provider: provider))
        stateProviders[url] = registrations
    }

    package func unregisterStateProvider(at url: URL?, id: UUID) {
        guard let url = normalizedFileURL(url), var registrations = stateProviders[url] else {
            return
        }
        registrations.removeAll { $0.id == id }
        if registrations.isEmpty {
            stateProviders.removeValue(forKey: url)
        } else {
            stateProviders[url] = registrations
        }
    }

    package func prepareForRelaunch(targetBuild: String) {
        isPreparingUpdateRelaunch = true
        let workspace = captureWorkspace()
        guard !workspace.documentURLs.isEmpty else {
            defaults.removeObject(forKey: Self.pendingRelaunchKey)
            return
        }
        defaults.set(
            ["build": targetBuild, "workspace": workspace.propertyList],
            forKey: Self.pendingRelaunchKey
        )
    }

    package func captureLastSession() {
        guard !isPreparingUpdateRelaunch else { return }
        let workspace = captureWorkspace()
        if workspace.documentURLs.isEmpty {
            defaults.removeObject(forKey: Self.lastSessionKey)
        } else {
            defaults.set(workspace.propertyList, forKey: Self.lastSessionKey)
        }
        collectOriginalSnapshots()
        refreshReopenAvailability()
    }

    private func collectOriginalSnapshots() {
        guard collectsOriginals else { return }
        var retained = Set(lastSessionWorkspace()?.groups.flatMap(\.tabs).compactMap { $0.windowState?.originalSnapshotID } ?? [])
        if let record = defaults.dictionary(forKey: Self.pendingRelaunchKey),
           let plist = record["workspace"] as? [String: Any], let workspace = WorkspaceSnapshot(propertyList: plist) {
            retained.formUnion(workspace.groups.flatMap(\.tabs).compactMap { $0.windowState?.originalSnapshotID })
        }
        originalCoordinator.collect(retaining: retained)
    }

    package func reopenLastSession() {
        guard canReopenLastSession else { return }
        reopenLastSessionHandler?()
    }

    package func lastSessionWorkspace() -> WorkspaceSnapshot? {
        guard let propertyList = defaults.dictionary(forKey: Self.lastSessionKey) else {
            return nil
        }
        return WorkspaceSnapshot(propertyList: propertyList)
    }

    package func consumeWorkspaceForRelaunch(currentBuild: String) -> WorkspaceSnapshot? {
        guard let record = defaults.dictionary(forKey: Self.pendingRelaunchKey),
              record["build"] as? String == currentBuild
        else { return nil }

        let workspace: WorkspaceSnapshot?
        if let storedWorkspace = record["workspace"] as? [String: Any] {
            workspace = WorkspaceSnapshot(propertyList: storedWorkspace)
        } else {
            workspace = legacyWorkspace(from: record)
        }
        guard let workspace else { return nil }
        defaults.removeObject(forKey: Self.pendingRelaunchKey)
        prepareWindowStates(for: workspace)
        return workspace
    }

    public func consumeDocumentsForRelaunch(currentBuild: String) -> [URL] {
        consumeWorkspaceForRelaunch(currentBuild: currentBuild)?.documentURLs ?? []
    }

    package func prepareWindowStates(for workspace: WorkspaceSnapshot) {
        pendingWindowStates.removeAll()
        for tab in workspace.groups.flatMap(\.tabs) {
            guard let url = tab.documentURL, let state = tab.windowState else { continue }
            pendingWindowStates[url.standardizedFileURL] = state
            if let id = state.originalSnapshotID {
                do { try originalCoordinator.enqueue(MarkdownOpenRequest(fileURL: url, originalID: id)) }
                catch { originalCoordinator.reportRestorationError(error, for: url) }
            }
        }
    }

    package func currentWindowState(for url: URL) -> DocumentWindowRestorationState? {
        stateProviders[url.standardizedFileURL]?.last?.provider()
    }

    package func takeWindowState(for url: URL?) -> DocumentWindowRestorationState? {
        guard let url = normalizedFileURL(url) else { return nil }
        return pendingWindowStates.removeValue(forKey: url)
    }

    private func normalizedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    private func captureWorkspace() -> WorkspaceSnapshot {
        if let captured = workspaceCaptureProvider?(), !captured.documentURLs.isEmpty {
            return captured
        }
        let groups = openDocumentCounts.keys.sorted { $0.path < $1.path }.enumerated().map {
            index, url in
            WorkspaceWindowGroup(
                identifier: "window-\(index)",
                tabs: [.document(url, state: currentWindowState(for: url))],
                selectedTabIndex: 0,
                isTabBarVisible: false
            )
        }
        return WorkspaceSnapshot(groups: groups)
    }

    private func legacyWorkspace(from record: [String: Any]) -> WorkspaceSnapshot? {
        let documents: [[String: Any]]
        if let storedDocuments = record["documents"] as? [[String: Any]] {
            documents = storedDocuments
        } else if let paths = record["paths"] as? [String] {
            documents = paths.map { ["path": $0] }
        } else {
            return nil
        }
        let groups = documents.enumerated().compactMap { index, document -> WorkspaceWindowGroup? in
            guard let path = document["path"] as? String else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let state = DocumentWindowRestorationState(propertyList: document)
            let hasState = state.frame != nil || state.viewport != nil
                || state.thumbnails != nil || state.explicitPageSetup != nil
            return WorkspaceWindowGroup(
                identifier: "legacy-\(index)",
                tabs: [.document(url, state: hasState ? state : nil)],
                selectedTabIndex: 0,
                isTabBarVisible: false
            )
        }
        return WorkspaceSnapshot(groups: groups)
    }

    private func refreshReopenAvailability() {
        guard let workspace = lastSessionWorkspace() else {
            canReopenLastSession = false
            return
        }
        canReopenLastSession = workspace.documentURLs.contains { url in
            openDocumentCounts[url.standardizedFileURL] == nil
        }
    }
}

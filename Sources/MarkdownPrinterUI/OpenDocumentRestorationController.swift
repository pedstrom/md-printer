import Combine
import Foundation

package struct PersistedPreviewViewport: Equatable {
    let scaleFactor: Double
    let pageIndex: Int
    let normalizedPageX: Double
    let normalizedPageY: Double
    let documentProgress: Double

    fileprivate var propertyList: [String: Any] {
        [
            "scaleFactor": scaleFactor,
            "pageIndex": pageIndex,
            "normalizedPageX": normalizedPageX,
            "normalizedPageY": normalizedPageY,
            "documentProgress": documentProgress
        ]
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
    }

    package init(
        scaleFactor: Double,
        pageIndex: Int,
        normalizedPageX: Double,
        normalizedPageY: Double,
        documentProgress: Double
    ) {
        self.scaleFactor = scaleFactor
        self.pageIndex = pageIndex
        self.normalizedPageX = normalizedPageX
        self.normalizedPageY = normalizedPageY
        self.documentProgress = documentProgress
    }
}

package struct DocumentWindowRestorationState: Equatable {
    let frame: CGRect?
    let viewport: PersistedPreviewViewport?

    package init(frame: CGRect?, viewport: PersistedPreviewViewport?) {
        self.frame = frame
        self.viewport = viewport
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
    }
}

@MainActor
public final class OpenDocumentRestorationController: ObservableObject {
    package static let pendingRelaunchKey = "pendingUpdateDocumentRestoration"

    private struct StateProviderRegistration {
        let id: UUID
        let provider: () -> DocumentWindowRestorationState?
    }

    private let defaults: UserDefaults
    private var openDocumentCounts: [URL: Int] = [:]
    private var stateProviders: [URL: [StateProviderRegistration]] = [:]
    private var pendingWindowStates: [URL: DocumentWindowRestorationState] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func documentDidOpen(at url: URL?) {
        guard let url = normalizedFileURL(url) else { return }
        openDocumentCounts[url, default: 0] += 1
    }

    public func documentDidClose(at url: URL?) {
        guard let url = normalizedFileURL(url), let count = openDocumentCounts[url] else { return }
        if count > 1 {
            openDocumentCounts[url] = count - 1
        } else {
            openDocumentCounts.removeValue(forKey: url)
        }
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
        let urls = openDocumentCounts.keys.sorted { $0.path < $1.path }
        guard !urls.isEmpty else {
            defaults.removeObject(forKey: Self.pendingRelaunchKey)
            return
        }
        let documents: [[String: Any]] = urls.map { url in
            var record: [String: Any] = ["path": url.path]
            if let state = stateProviders[url]?.last?.provider() {
                record.merge(state.propertyList) { _, new in new }
            }
            return record
        }
        defaults.set(
            ["build": targetBuild, "documents": documents],
            forKey: Self.pendingRelaunchKey
        )
    }

    public func consumeDocumentsForRelaunch(currentBuild: String) -> [URL] {
        guard
            let record = defaults.dictionary(forKey: Self.pendingRelaunchKey),
            record["build"] as? String == currentBuild
        else {
            return []
        }

        let documents: [[String: Any]]
        if let storedDocuments = record["documents"] as? [[String: Any]] {
            documents = storedDocuments
        } else if let paths = record["paths"] as? [String] {
            documents = paths.map { ["path": $0] }
        } else {
            return []
        }

        defaults.removeObject(forKey: Self.pendingRelaunchKey)
        pendingWindowStates.removeAll()
        return documents.compactMap { document in
            guard let path = document["path"] as? String else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let state = DocumentWindowRestorationState(propertyList: document)
            if state.frame != nil || state.viewport != nil {
                pendingWindowStates[url] = state
            }
            return url
        }
    }

    package func takeWindowState(for url: URL?) -> DocumentWindowRestorationState? {
        guard let url = normalizedFileURL(url) else { return nil }
        return pendingWindowStates.removeValue(forKey: url)
    }

    private func normalizedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }
}

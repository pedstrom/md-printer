import Combine
import Foundation

@MainActor
public final class OpenDocumentRestorationController: ObservableObject {
    package static let pendingRelaunchKey = "pendingUpdateDocumentRestoration"

    private let defaults: UserDefaults
    private var openDocumentCounts: [URL: Int] = [:]

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

    package func prepareForRelaunch(targetBuild: String) {
        let paths = openDocumentCounts.keys
            .map(\.path)
            .sorted()
        guard !paths.isEmpty else {
            defaults.removeObject(forKey: Self.pendingRelaunchKey)
            return
        }
        defaults.set(
            ["build": targetBuild, "paths": paths],
            forKey: Self.pendingRelaunchKey
        )
    }

    public func consumeDocumentsForRelaunch(currentBuild: String) -> [URL] {
        guard
            let record = defaults.dictionary(forKey: Self.pendingRelaunchKey),
            record["build"] as? String == currentBuild,
            let paths = record["paths"] as? [String]
        else {
            return []
        }

        defaults.removeObject(forKey: Self.pendingRelaunchKey)
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func normalizedFileURL(_ url: URL?) -> URL? {
        guard let url, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }
}

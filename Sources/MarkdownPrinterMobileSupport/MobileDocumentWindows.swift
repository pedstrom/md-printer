#if canImport(UIKit)
import Combine
import Foundation
import MarkdownPrinterCore

public enum MobileDocumentIdentity {
    public static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    public static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().absoluteString
    }
}

public enum MobileMarkdownWindowLinks {
    public static func links(in nodes: [InlineNode], relativeTo baseURL: URL?) -> [(label: String, url: URL)] {
        var result: [(label: String, url: URL)] = []
        for node in nodes {
            switch node {
            case let .link(children, destination, _):
                if let resolved = MarkdownLinkTarget.resolvedURL(for: destination, relativeTo: baseURL),
                   let url = MarkdownLinkTarget.fileURL(from: resolved),
                   !result.contains(where: { $0.url == url }) {
                    result.append((url.lastPathComponent, url))
                }
                result += links(in: children, relativeTo: baseURL)
            case let .emphasis(children), let .strong(children), let .underline(children), let .strikethrough(children):
                result += links(in: children, relativeTo: baseURL)
            default: break
            }
        }
        var seen = Set<URL>()
        return result.filter { seen.insert($0.url).inserted }
    }
}

public struct MobileReaderRestoration: Codable, Equatable {
    public var query = ""
    public var matchCase = false
    public var wholeWord = false
    public var selectedMatch = 0
    public var visibleBlock: String?
    public var toolbarsVisible = true
    public init() {}
}

public struct MobileDocumentBookmark: Codable, Equatable {
    public let fallbackURL: URL
    public let data: Data?

    public init(url: URL, create: (URL) throws -> Data = {
        try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }) {
        fallbackURL = url
        data = try? create(url)
    }

    public func resolve(using resolver: (Data) throws -> URL = { data in
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }) -> URL {
        // A failed/stale grant still has an address for the normal permission/retry UI.
        data.flatMap { try? resolver($0) } ?? fallbackURL
    }
}

public struct MobileWindowRestoration: Codable, Equatable {
    public var documents: [MobileDocumentBookmark] = []
    public var readers: [String: MobileReaderRestoration] = [:]
    public init() {}

    public var encoded: String {
        // All members are concrete Codable values; no document contents are persisted here.
        (try? JSONEncoder().encode(self).base64EncodedString()) ?? ""
    }

    public static func decode(_ value: String) -> Self {
        guard let data = Data(base64Encoded: value),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }
}

@MainActor
public final class MobileDocumentWindowState: ObservableObject {
    @Published public private(set) var rootURL: URL?
    @Published public var linkedDocuments: [URL] = []
    @Published public private(set) var readers: [String: MobileReaderRestoration] = [:]
    // Hold restored grants for the entire scene, including links below the top of the stack.
    private var leases: [SecurityScopedResourceLease] = []

    public init() {}

    public var documentURLs: [URL] { rootURL.map { [$0] + linkedDocuments } ?? [] }

    public func open(_ url: URL) {
        guard MobileDocumentIdentity.accepts(url) else { return }
        let key = MobileDocumentIdentity.key(for: url)
        if let index = documentURLs.firstIndex(where: { MobileDocumentIdentity.key(for: $0) == key }) {
            linkedDocuments = Array(linkedDocuments.prefix(index))
        } else {
            leases = [SecurityScopedResourceLease(url: url)]
            linkedDocuments = []
            readers = [:]
            rootURL = url
        }
    }

    public func browse() {
        rootURL = nil
        linkedDocuments = []
        readers = [:]
        leases = []
    }

    public func reader(for url: URL?) -> MobileReaderRestoration {
        guard let url else { return MobileReaderRestoration() }
        return readers[MobileDocumentIdentity.key(for: url)] ?? MobileReaderRestoration()
    }

    public func saveReader(_ reader: MobileReaderRestoration, for url: URL?) {
        guard let url else { return }
        let key = MobileDocumentIdentity.key(for: url)
        if readers[key] != reader { readers[key] = reader }
    }

    public var restoration: MobileWindowRestoration {
        var state = MobileWindowRestoration()
        state.documents = documentURLs.map { MobileDocumentBookmark(url: $0) }
        state.readers = readers
        return state
    }

    public func restore(_ state: MobileWindowRestoration) {
        let resolved = state.documents.compactMap { bookmark -> (MobileDocumentBookmark, URL)? in
            let url = bookmark.resolve()
            return MobileDocumentIdentity.accepts(url) ? (bookmark, url) : nil
        }
        let urls = resolved.map { $0.1 }
        leases = urls.map(SecurityScopedResourceLease.init(url:))
        rootURL = urls.first
        linkedDocuments = Array(urls.dropFirst())
        readers = [:]
        for (bookmark, url) in resolved {
            if let reader = state.readers[MobileDocumentIdentity.key(for: bookmark.fallbackURL)] {
                readers[MobileDocumentIdentity.key(for: url)] = reader
            }
        }
    }
}

@MainActor
public final class MobileWindowOpenRequest {
    public let id = UUID()
    public let url: URL
    private let lease: SecurityScopedResourceLease
    public init(url: URL) {
        self.url = url
        lease = SecurityScopedResourceLease(url: url)
    }
}

/// Routes requests only. Document data and work belong to each scene's session.
@MainActor
public final class MobileDocumentWindowRouter: ObservableObject {
    @Published public private(set) var requests: [UUID: MobileWindowOpenRequest] = [:]
    private var documents: [UUID: [String]] = [:]
    private var sessions: [String: UUID] = [:]

    public init() {}

    public func register(_ window: UUID, urls: [URL], sessionID: String? = nil) {
        let pendingURL = requests[window]?.url
        documents[window] = urls.isEmpty ? pendingURL.map { [MobileDocumentIdentity.key(for: $0)] } ?? [] : urls.map(MobileDocumentIdentity.key)
        if let sessionID { sessions[sessionID] = window }
    }

    public func sessionID(for window: UUID) -> String? {
        sessions.first(where: { $0.value == window })?.key
    }

    public func discard(sessionID: String) {
        guard let window = sessions.removeValue(forKey: sessionID) else { return }
        documents.removeValue(forKey: window)
        requests.removeValue(forKey: window)
    }

    @discardableResult
    public func route(_ url: URL, from current: UUID, multipleWindows: Bool) -> UUID? {
        guard MobileDocumentIdentity.accepts(url) else { return nil }
        let key = MobileDocumentIdentity.key(for: url)
        let target: UUID
        if !multipleWindows {
            target = current
        } else if let existing = documents.first(where: { $0.value.contains(key) })?.key {
            target = existing
        } else if documents[current, default: []].isEmpty {
            target = current
        } else {
            target = UUID()
        }
        // Reserve immediately so simultaneous requests cannot create duplicate windows.
        if documents[target, default: []].isEmpty || !multipleWindows {
            documents[target] = [key]
        }
        requests[target] = MobileWindowOpenRequest(url: url)
        return target
    }

    public func complete(_ request: MobileWindowOpenRequest, in window: UUID) {
        if requests[window]?.id == request.id { requests.removeValue(forKey: window) }
    }
}
/// An atomic local copy supplements the OS scene snapshot when the process is terminated quickly.
public struct MobileWindowRestorationStore {
    public let directory: URL
    public init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("DocumentWindows", isDirectory: true)) {
        self.directory = directory
    }
    public func fileURL(for sessionID: String) -> URL {
        let name = sessionID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
    public func load(sessionID: String) -> MobileWindowRestoration? {
        guard let data = try? Data(contentsOf: fileURL(for: sessionID)) else { return nil }
        return try? JSONDecoder().decode(MobileWindowRestoration.self, from: data)
    }
    public func save(_ state: MobileWindowRestoration, sessionID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: fileURL(for: sessionID), options: .atomic)
    }
    public func discard(sessionID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: sessionID))
    }
}
#endif

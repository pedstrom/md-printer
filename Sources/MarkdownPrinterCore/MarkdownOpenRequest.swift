#if canImport(AppKit)
import AppKit

public struct OriginalDocumentSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let markdown: String
    public let title: String
    public let sourceURL: URL?

    public init(document: MarkdownDocument, id: UUID = UUID()) {
        self.id = id; markdown = document.markdown; title = document.title; sourceURL = document.sourceURL
    }
    public var document: MarkdownDocument {
        MarkdownDocument(sourceURL: sourceURL, title: title, markdown: markdown)
    }
}

/// Shared by the bundled CLI and app. Document text stays in local application
/// support, rather than URL parameters, defaults, or project files.
public struct OriginalSnapshotStore {
    public let directory: URL
    public static func defaultDirectory(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let identifier = bundleIdentifier ?? "com.peteedstrom.markdown-printer"
        let folder = identifier == "com.peteedstrom.markdown-printer" ? "Markdown Printer" : "Markdown Printer-" + identifier
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder + "/Originals", isDirectory: true)
    }
    public init(directory: URL = OriginalSnapshotStore.defaultDirectory()) {
        self.directory = directory
    }
    @discardableResult
    public func save(_ snapshot: OriginalDocumentSnapshot, pending: Bool = false) throws -> UUID {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: url(for: snapshot.id), options: .atomic)
        if pending { try Data().write(to: directory.appendingPathComponent(snapshot.id.uuidString + ".pending"), options: .atomic) }
        return snapshot.id
    }
    public func load(_ id: UUID) throws -> OriginalDocumentSnapshot {
        let snapshot = try JSONDecoder().decode(OriginalDocumentSnapshot.self, from: Data(contentsOf: url(for: id)))
        guard snapshot.id == id else { throw MarkdownOpenError.invalidOriginal }
        return snapshot
    }
    public func consume(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".pending"))
    }
    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id)); consume(id)
    }
    public func collect(retaining ids: Set<UUID>, now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        func pendingIsRecent(_ file: URL) -> Bool {
            guard FileManager.default.fileExists(atPath: file.path),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return false }
            // A handoff must survive cold launch, but a crashed CLI/app must not
            // retain an unreferenced document indefinitely.
            return now.timeIntervalSince(modified) < 24 * 60 * 60
        }
        for file in files where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id),
                  !pendingIsRecent(directory.appendingPathComponent(id.uuidString + ".pending")) else { continue }
            try FileManager.default.removeItem(at: file)
            consume(id)
        }
        for file in files where file.pathExtension == "pending" {
            guard !FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("json").path),
                  !pendingIsRecent(file) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
    private func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

public enum MarkdownOpenError: LocalizedError, Equatable {
    case arguments, invalidOriginal, applicationUnavailable
    public var errorDescription: String? {
        switch self {
        case .arguments: "Usage: MarkdownPrinterCLI open <file.md> [more.md …] [--original <older.md>]. An original requires exactly one current file."
        case .invalidOriginal: "The saved original document could not be loaded."
        case .applicationUnavailable: "Markdown Printer could not be opened. Run the CLI bundled inside the app, or launch Markdown Printer once first."
        }
    }
}

@MainActor
public enum MarkdownOpenLauncher {
    public typealias Opener = @MainActor ([URL], URL?) async throws -> Void

    public static func launch(_ arguments: [String], executable: URL,
                              store: OriginalSnapshotStore? = nil,
                              opener: Opener = openInWorkspace) async throws {
        let application = applicationURL(for: executable)
        let identifier = application.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let store = store ?? OriginalSnapshotStore(directory: OriginalSnapshotStore.defaultDirectory(bundleIdentifier: identifier))
        let requests = try MarkdownOpenArguments.parse(arguments).requests(store: store)
        do { try await opener(requests.map(\.url), application) }
        catch {
            for request in requests { if let id = request.originalID { store.remove(id) } }
            throw error
        }
    }

    public static func applicationURL(for executable: URL) -> URL? {
        var url = executable.standardizedFileURL.deletingLastPathComponent()
        while url.path != "/" {
            if url.pathExtension == "app" { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    public static func openInWorkspace(_ urls: [URL], application: URL?) async throws {
        guard let application = application ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.peteedstrom.markdown-printer") else {
            throw MarkdownOpenError.applicationUnavailable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

public struct MarkdownOpenArguments: Equatable {
    public let files: [URL]
    public let original: URL?

    public static func parse(_ arguments: [String], directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> Self {
        guard arguments.first == "open" else { throw MarkdownOpenError.arguments }
        var paths: [String] = [], original: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--original" {
                guard original == nil, index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw MarkdownOpenError.arguments }
                original = arguments[index + 1]; index += 2
            } else {
                guard !argument.hasPrefix("--") else { throw MarkdownOpenError.arguments }
                paths.append(argument); index += 1
            }
        }
        guard !paths.isEmpty, original == nil || paths.count == 1 else { throw MarkdownOpenError.arguments }
        func file(_ path: String) throws -> URL {
            let url = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
            guard MarkdownLinkTarget.supportedPathExtensions.contains(url.pathExtension.lowercased()) else { throw MarkdownOpenError.arguments }
            return url
        }
        return try Self(files: paths.map(file), original: original.map(file))
    }

    public func requests(store: OriginalSnapshotStore) throws -> [MarkdownOpenRequest] {
        for file in files { _ = try MarkdownDocument.load(from: file) }
        let snapshot = try original.map { OriginalDocumentSnapshot(document: try MarkdownDocument.load(from: $0)) }
        if let snapshot { try store.save(snapshot, pending: true) }
        return files.map { MarkdownOpenRequest(fileURL: $0, originalID: snapshot?.id) }
    }
}

public struct MarkdownOpenRequest: Equatable {
    public let fileURL: URL
    public let originalID: UUID?
    public init(fileURL: URL, originalID: UUID? = nil) { self.fileURL = fileURL.standardizedFileURL; self.originalID = originalID }
    public var url: URL {
        var components = URLComponents(url: MarkdownLinkTarget.hostAppURL(for: MarkdownNavigationRequest(fileURL: fileURL)), resolvingAgainstBaseURL: false)!
        if let originalID { components.queryItems?.append(URLQueryItem(name: "original", value: originalID.uuidString)) }
        return components.url!
    }
    public static func parse(_ url: URL) throws -> Self? {
        guard let target = MarkdownLinkTarget.hostAppTarget(from: url) else { return nil }
        let originals = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "original" } ?? []
        guard originals.count <= 1 else { throw MarkdownOpenError.invalidOriginal }
        if let original = originals.first {
            guard let value = original.value, let id = UUID(uuidString: value) else { throw MarkdownOpenError.invalidOriginal }
            return Self(fileURL: target.fileURL, originalID: id)
        }
        return Self(fileURL: target.fileURL)
    }
}
#endif

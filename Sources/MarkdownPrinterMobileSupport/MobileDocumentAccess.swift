#if canImport(UIKit)
import Foundation
import MarkdownPrinterCore

public enum MobileDocumentAccessError: LocalizedError, Equatable, Sendable {
    case unreadableDocument
    case unsupportedTextEncoding
    case permissionRequired(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            return "Markdown Printer couldn’t read this file."
        case .unsupportedTextEncoding:
            return "This Markdown file isn’t valid UTF-8 or UTF-16 text."
        case let .permissionRequired(filename):
            return "Allow access to the folder containing “\(filename)” so Markdown Printer can open it."
        }
    }

    static func readingFailure(for error: Error, at url: URL) -> MobileDocumentAccessError {
        isReadPermissionError(error)
            ? .permissionRequired(url.lastPathComponent)
            : .unreadableDocument
    }

    private static func isReadPermissionError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return true
        }
        if cocoaError.domain == NSPOSIXErrorDomain,
           [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)]
            .contains(cocoaError.code) {
            return true
        }
        guard let underlying = cocoaError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isReadPermissionError(underlying)
    }
}

public struct MobileDocumentPermissionRequest: Equatable, Sendable {
    public let url: URL
    public let filename: String
    public let directoryURL: URL

    public init(url: URL) {
        self.url = url
        self.filename = url.lastPathComponent
        self.directoryURL = url.deletingLastPathComponent()
    }
}

public enum MobileDirectoryAccessError: LocalizedError, Equatable, Sendable {
    case wrongFolder(String)
    case accessDenied
    case bookmarkFailed
    case noPendingRequest

    public var errorDescription: String? {
        switch self {
        case let .wrongFolder(filename):
            return "Choose a folder that contains “\(filename)”."
        case .accessDenied:
            return "Markdown Printer couldn’t access that folder. Check Files and Folders access in Settings."
        case .bookmarkFailed:
            return "Markdown Printer couldn’t remember that folder. Choose it again."
        case .noPendingRequest:
            return "There isn’t a linked document waiting for folder access."
        }
    }
}

public enum MobileDirectoryAuthorization {
    public static func contains(_ documentURL: URL, within directoryURL: URL) -> Bool {
        let documentComponents = documentURL.standardizedFileURL.pathComponents
        let directoryComponents = directoryURL.standardizedFileURL.pathComponents
        guard documentComponents.count > directoryComponents.count else { return false }
        return zip(documentComponents, directoryComponents).allSatisfy { $0.0 == $0.1 }
    }
}

@MainActor
public final class MobileDirectoryAccessStore {
    public static let shared = MobileDirectoryAccessStore()

    private struct ActiveDirectory {
        let url: URL
        let bookmarkData: Data
        let lease: SecurityScopedResourceLease
    }

    private static let defaultBookmarkKey =
        "com.peteedstrom.markdown-printer.authorized-directories.v1"

    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let bookmarkCreator: (URL) throws -> Data
    private let bookmarkResolver: (Data) throws -> (url: URL, isStale: Bool)
    private let leaseFactory: (URL) -> SecurityScopedResourceLease
    private let isReadableDirectory: (URL) -> Bool
    private var activeDirectories: [ActiveDirectory] = []

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            bookmarkKey: Self.defaultBookmarkKey,
            bookmarkCreator: { url in
                try url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            bookmarkResolver: { data in
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return (url, isStale)
            },
            leaseFactory: SecurityScopedResourceLease.init(url:),
            isReadableDirectory: Self.isReadableDirectory(at:)
        )
    }

    init(
        defaults: UserDefaults,
        bookmarkKey: String,
        bookmarkCreator: @escaping (URL) throws -> Data,
        bookmarkResolver: @escaping (Data) throws -> (url: URL, isStale: Bool),
        leaseFactory: @escaping (URL) -> SecurityScopedResourceLease,
        isReadableDirectory: @escaping (URL) -> Bool
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
        self.bookmarkCreator = bookmarkCreator
        self.bookmarkResolver = bookmarkResolver
        self.leaseFactory = leaseFactory
        self.isReadableDirectory = isReadableDirectory
        restoreStoredAccess()
    }

    public func authorize(directoryURL: URL) throws {
        let directoryURL = directoryURL.standardizedFileURL
        let replacedBookmarks = Set(
            activeDirectories.lazy
                .filter { $0.url == directoryURL }
                .map(\.bookmarkData)
        )
        activeDirectories.removeAll { $0.url == directoryURL }

        let lease = leaseFactory(directoryURL)
        guard lease.isSecurityScoped || isReadableDirectory(directoryURL) else {
            throw MobileDirectoryAccessError.accessDenied
        }
        let bookmarkData: Data
        do {
            bookmarkData = try bookmarkCreator(directoryURL)
        } catch {
            throw MobileDirectoryAccessError.bookmarkFailed
        }
        activeDirectories.append(
            ActiveDirectory(url: directoryURL, bookmarkData: bookmarkData, lease: lease)
        )
        saveBookmarks(storedBookmarks.filter { !replacedBookmarks.contains($0) } + [bookmarkData])
    }

    @discardableResult
    public func activateStoredAccess(containing documentURL: URL) -> Bool {
        if hasAccess(to: documentURL) { return true }
        restoreStoredAccess()
        return hasAccess(to: documentURL)
    }

    public func hasAccess(to documentURL: URL) -> Bool {
        activeDirectories.contains {
            MobileDirectoryAuthorization.contains(documentURL, within: $0.url)
        }
    }

    private var storedBookmarks: [Data] {
        defaults.array(forKey: bookmarkKey) as? [Data] ?? []
    }

    private func restoreStoredAccess() {
        var bookmarks = storedBookmarks
        var didChange = false
        for (index, bookmarkData) in bookmarks.enumerated() {
            guard !activeDirectories.contains(where: { $0.bookmarkData == bookmarkData }) else {
                continue
            }
            guard let resolved = try? bookmarkResolver(bookmarkData) else { continue }
            let directoryURL = resolved.url.standardizedFileURL
            guard !activeDirectories.contains(where: { $0.url == directoryURL }) else { continue }
            let lease = leaseFactory(directoryURL)
            guard lease.isSecurityScoped || isReadableDirectory(directoryURL) else { continue }

            var retainedBookmark = bookmarkData
            if resolved.isStale, let refreshed = try? bookmarkCreator(directoryURL) {
                retainedBookmark = refreshed
                bookmarks[index] = refreshed
                didChange = true
            }
            activeDirectories.append(
                ActiveDirectory(url: directoryURL, bookmarkData: retainedBookmark, lease: lease)
            )
        }
        if didChange { saveBookmarks(bookmarks) }
    }

    private func saveBookmarks(_ bookmarks: [Data]) {
        var seen = Set<Data>()
        defaults.set(bookmarks.filter { seen.insert($0).inserted }, forKey: bookmarkKey)
    }

    private static func isReadableDirectory(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        return values?.isDirectory == true && values?.isReadable == true
    }
}

public enum MobileBackSwipeEdge: Equatable, Sendable {
    case leading
    case trailing
}

public enum MobileBackSwipePolicy {
    public static let minimumHorizontalTravel = 60.0

    public static func shouldNavigateBack(
        from edge: MobileBackSwipeEdge,
        horizontalTravel: Double,
        verticalTravel: Double
    ) -> Bool {
        guard abs(horizontalTravel) >= minimumHorizontalTravel,
              abs(horizontalTravel) > abs(verticalTravel) * 1.25 else {
            return false
        }
        switch edge {
        case .leading:
            return horizontalTravel > 0
        case .trailing:
            return horizontalTravel < 0
        }
    }
}

public final class SecurityScopedResourceLease {
    public let url: URL
    public let isSecurityScoped: Bool
    private let stopAccessing: () -> Void

    public init(url: URL) {
        self.url = url
        isSecurityScoped = url.startAccessingSecurityScopedResource()
        stopAccessing = { url.stopAccessingSecurityScopedResource() }
    }

    init(url: URL, startAccessing: () -> Bool, stopAccessing: @escaping () -> Void) {
        self.url = url
        isSecurityScoped = startAccessing()
        self.stopAccessing = stopAccessing
    }

    deinit {
        if isSecurityScoped { stopAccessing() }
    }
}

public struct MobileDocumentLoader: Sendable {
    private let dataLoader: @Sendable (URL) throws -> Data

    public init() {
        dataLoader = Self.coordinatedData
    }

    init(dataLoader: @escaping @Sendable (URL) throws -> Data) {
        self.dataLoader = dataLoader
    }

    public func load(at url: URL) async throws -> MarkdownDocument {
        let dataLoader = dataLoader
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            do {
                let data = try dataLoader(url)
                try Task.checkCancellation()
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return try MarkdownDocument.decode(
                    data: data,
                    sourceURL: url,
                    sourceModificationDate: values?.contentModificationDate
                )
            } catch MarkdownDocumentError.unsupportedTextEncoding {
                throw MobileDocumentAccessError.unsupportedTextEncoding
            } catch let error as MobileDocumentAccessError {
                throw error
            } catch {
                throw MobileDocumentAccessError.readingFailure(for: error, at: url)
            }
        }.value
    }

    private static func coordinatedData(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe]) }
        }
        if let coordinationError { throw coordinationError }
        guard let data = try result?.get() else {
            throw MobileDocumentAccessError.unreadableDocument
        }
        return data
    }
}

#endif

#if canImport(UIKit)
import Foundation
import MarkdownPrinterCore

public enum MobileDocumentAccessError: LocalizedError, Equatable, Sendable {
    case unreadableDocument
    case unsupportedTextEncoding
    case invalidFilename
    case fileOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            return "Markdown Printer couldn’t read this file."
        case .unsupportedTextEncoding:
            return "This Markdown file isn’t valid UTF-8 or UTF-16 text."
        case .invalidFilename:
            return "Enter a valid filename."
        case let .fileOperationFailed(message):
            return message
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
    public init() {}

    public func load(at url: URL) async throws -> MarkdownDocument {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            do {
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
                throw MobileDocumentAccessError.unreadableDocument
            }
        }.value
    }
}

public struct MobileFileActionAvailability: Equatable, Sendable {
    public let canRename: Bool
    public let canMove: Bool
    public let canDuplicate: Bool
    public let unavailableReason: String?

    public init(
        canRename: Bool,
        canMove: Bool,
        canDuplicate: Bool,
        unavailableReason: String? = nil
    ) {
        self.canRename = canRename
        self.canMove = canMove
        self.canDuplicate = canDuplicate
        self.unavailableReason = unavailableReason
    }

    public static func resolve(for url: URL?) -> MobileFileActionAvailability {
        guard let url else {
            return MobileFileActionAvailability(
                canRename: false,
                canMove: false,
                canDuplicate: false,
                unavailableReason: "This document doesn’t have a file location."
            )
        }
        let values = try? url.resourceValues(forKeys: [.isWritableKey, .isRegularFileKey])
        let isRegularFile = values?.isRegularFile == true
        let isWritable = values?.isWritable == true || FileManager.default.isWritableFile(atPath: url.path)
        guard isRegularFile else {
            return MobileFileActionAvailability(
                canRename: false,
                canMove: false,
                canDuplicate: false,
                unavailableReason: "This file provider doesn’t expose an editable file."
            )
        }
        return MobileFileActionAvailability(
            canRename: isWritable,
            canMove: isWritable,
            canDuplicate: true,
            unavailableReason: isWritable ? nil : "This file provider allows viewing only."
        )
    }
}

public struct MobileFileOperator {
    public init() {}

    public func rename(_ sourceURL: URL, to proposedName: String) throws -> URL {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw MobileDocumentAccessError.invalidFilename
        }
        let sourceExtension = sourceURL.pathExtension
        let resolvedName = URL(fileURLWithPath: trimmed).pathExtension.isEmpty && !sourceExtension.isEmpty
            ? trimmed + "." + sourceExtension
            : trimmed
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(resolvedName)
        guard destinationURL.standardizedFileURL != sourceURL.standardizedFileURL else { return sourceURL }
        return try coordinatedMove(from: sourceURL, to: destinationURL)
    }

    public func duplicate(_ sourceURL: URL) throws -> URL {
        let manager = FileManager.default
        let directory = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        var suffix = " copy"
        var candidate = directory.appendingPathComponent(base + suffix).appendingPathExtension(pathExtension)
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            suffix = " copy \(index)"
            candidate = directory.appendingPathComponent(base + suffix).appendingPathExtension(pathExtension)
            index += 1
        }

        var coordinationError: NSError?
        var operationError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [],
            writingItemAt: candidate,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                try manager.copyItem(at: coordinatedSource, to: coordinatedDestination)
            } catch {
                operationError = error
            }
        }
        if let error = coordinationError ?? operationError as NSError? {
            throw MobileDocumentAccessError.fileOperationFailed(error.localizedDescription)
        }
        return candidate
    }

    private func coordinatedMove(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        var coordinationError: NSError?
        var operationError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            do {
                try FileManager.default.moveItem(at: coordinatedSource, to: coordinatedDestination)
            } catch {
                operationError = error
            }
        }
        if let error = coordinationError ?? operationError as NSError? {
            throw MobileDocumentAccessError.fileOperationFailed(error.localizedDescription)
        }
        return destinationURL
    }
}

public struct MobileDocumentMetadata: Equatable, Sendable {
    public let filename: String
    public let kind: String
    public let byteSize: Int?
    public let modificationDate: Date?
    public let locationName: String?

    public init(
        filename: String,
        kind: String = "Markdown Document",
        byteSize: Int?,
        modificationDate: Date?,
        locationName: String?
    ) {
        self.filename = filename
        self.kind = kind
        self.byteSize = byteSize
        self.modificationDate = modificationDate
        self.locationName = locationName
    }

    public static func load(from url: URL?) -> MobileDocumentMetadata? {
        guard let url else { return nil }
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .contentModificationDateKey,
            .volumeNameKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return MobileDocumentMetadata(
            filename: url.lastPathComponent,
            byteSize: values?.fileSize,
            modificationDate: values?.contentModificationDate,
            locationName: values?.volumeName ?? url.deletingLastPathComponent().lastPathComponent
        )
    }
}
#endif

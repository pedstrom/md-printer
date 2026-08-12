import AppKit
import Foundation

struct PDFDragArtifact: Equatable {
    let fileURL: URL
    let directoryURL: URL
}

enum PDFDragFileStoreError: LocalizedError, Equatable {
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .invalidFileName:
            return "The PDF could not be prepared for dragging because its filename is invalid."
        }
    }
}

final class PDFDragFileStore {
    typealias CleanupScheduler = (_ delay: TimeInterval, _ workItem: DispatchWorkItem) -> Void

    static let acceptedDragRetention: TimeInterval = 10 * 60
    static let abandonedArtifactAge: TimeInterval = 24 * 60 * 60

    let rootDirectoryURL: URL
    private let fileManager: FileManager
    private let cleanupDelay: TimeInterval
    private let abandonedArtifactAge: TimeInterval
    private let now: () -> Date
    private let scheduleCleanup: CleanupScheduler

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        cleanupDelay: TimeInterval = PDFDragFileStore.acceptedDragRetention,
        abandonedArtifactAge: TimeInterval = PDFDragFileStore.abandonedArtifactAge,
        now: @escaping () -> Date = Date.init,
        scheduleCleanup: @escaping CleanupScheduler = { delay, workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    ) {
        self.fileManager = fileManager
        rootDirectoryURL = (temporaryDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("com.peteedstrom.markdown-printer.drag-files", isDirectory: true)
        self.cleanupDelay = cleanupDelay
        self.abandonedArtifactAge = abandonedArtifactAge
        self.now = now
        self.scheduleCleanup = scheduleCleanup
    }

    func materialize(pdfData: Data, fileName: String) throws -> PDFDragArtifact {
        guard Self.isValidFileName(fileName) else {
            throw PDFDragFileStoreError.invalidFileName
        }

        try prepareRootDirectory()
        removeAbandonedArtifacts()

        let directoryURL = rootDirectoryURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            try pdfData.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return PDFDragArtifact(fileURL: fileURL, directoryURL: directoryURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    func finish(_ artifact: PDFDragArtifact, operation: NSDragOperation) {
        guard operation.contains(.copy) else {
            remove(artifact)
            return
        }

        let cleanup = DispatchWorkItem { [weak self] in
            self?.remove(artifact)
        }
        scheduleCleanup(cleanupDelay, cleanup)
    }

    func remove(_ artifact: PDFDragArtifact) {
        try? fileManager.removeItem(at: artifact.directoryURL)
    }

    func removeAbandonedArtifacts() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = now().addingTimeInterval(-abandonedArtifactAge)
        for url in contents {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey]
            ),
            values.isDirectory == true,
            let artifactDate = values.contentModificationDate ?? values.creationDate,
            artifactDate < cutoff
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private func prepareRootDirectory() throws {
        try fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectoryURL.path
        )
    }

    private static func isValidFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty
            && fileName != "."
            && fileName != ".."
            && (fileName as NSString).lastPathComponent == fileName
    }
}

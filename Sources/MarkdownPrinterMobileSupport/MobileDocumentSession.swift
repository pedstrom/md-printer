#if canImport(UIKit)
import Combine
import Foundation
import MarkdownPrinterCore

public enum MobilePDFPreparationState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed(String)
}

public enum MobileDocumentSessionError: LocalizedError, Equatable, Sendable {
    case noDocument

    public var errorDescription: String? {
        "No Markdown document is open."
    }
}

@MainActor
public final class MobileDocumentSession: ObservableObject {
    @Published public private(set) var document: MarkdownDocument?
    @Published public private(set) var presentation: MobileMarkdownPresentation?
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var pdfState: MobilePDFPreparationState = .idle
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var permissionRequest: MobileDocumentPermissionRequest?
    @Published public private(set) var revision: UInt64 = 0
    @Published public private(set) var documentRevision: UInt64 = 0
    @Published public private(set) var remoteImageRevision: UInt64 = 0
    @Published public private(set) var downloadingRemoteImageSources = Set<String>()

    public var title: String { presentation?.title ?? sourceURL?.lastPathComponent ?? "Markdown Printer" }
    public let remoteImageCache: RemoteImageCache

    private let presenter: MobileMarkdownPresenter
    private let loader: MobileDocumentLoader
    private let directoryAccessStore: MobileDirectoryAccessStore
    private let pdfProvider: @MainActor (MarkdownDocument) async throws -> Data
    private let remoteImageDownloader: any RemoteImageDownloading
    private var securityLease: SecurityScopedResourceLease?
    private var cachedPDF: (revision: UInt64, data: Data)?
    private var pdfTask: Task<Data, Error>?

    public init(
        document: MarkdownDocument? = nil,
        sourceURL: URL? = nil,
        presenter: MobileMarkdownPresenter = MobileMarkdownPresenter(),
        loader: MobileDocumentLoader = MobileDocumentLoader(),
        directoryAccessStore: MobileDirectoryAccessStore = .shared,
        pdfConfiguration: MobilePDFConfiguration = .letter,
        remoteImageCache: RemoteImageCache = .applicationDefault,
        remoteImageDownloader: (any RemoteImageDownloading)? = nil
    ) {
        self.presenter = presenter
        self.loader = loader
        self.directoryAccessStore = directoryAccessStore
        self.remoteImageCache = remoteImageCache
        self.remoteImageDownloader = remoteImageDownloader
            ?? RemoteImageDownloader(cache: remoteImageCache)
        let exporter = MobilePDFExporter(
            configuration: pdfConfiguration,
            remoteImageCache: remoteImageCache
        )
        self.pdfProvider = { document in
            try await exporter.pdfData(for: document)
        }
        if let document {
            apply(document, sourceURL: sourceURL ?? document.sourceURL)
        }
    }

    init(
        document: MarkdownDocument? = nil,
        sourceURL: URL? = nil,
        presenter: MobileMarkdownPresenter = MobileMarkdownPresenter(),
        loader: MobileDocumentLoader = MobileDocumentLoader(),
        directoryAccessStore: MobileDirectoryAccessStore = .shared,
        remoteImageCache: RemoteImageCache = .applicationDefault,
        remoteImageDownloader: (any RemoteImageDownloading)? = nil,
        pdfProvider: @escaping @MainActor (MarkdownDocument) async throws -> Data
    ) {
        self.presenter = presenter
        self.loader = loader
        self.directoryAccessStore = directoryAccessStore
        self.remoteImageCache = remoteImageCache
        self.remoteImageDownloader = remoteImageDownloader
            ?? RemoteImageDownloader(cache: remoteImageCache)
        self.pdfProvider = pdfProvider
        if let document {
            apply(document, sourceURL: sourceURL ?? document.sourceURL)
        }
    }

    public func load(url: URL) async {
        cancelPDFGeneration()
        errorMessage = nil
        permissionRequest = nil
        directoryAccessStore.activateStoredAccess(containing: url)
        let nextLease = SecurityScopedResourceLease(url: url)
        do {
            let document = try await loader.load(at: url)
            securityLease = nextLease
            apply(document, sourceURL: url)
        } catch is CancellationError {
            return
        } catch {
            if let accessError = error as? MobileDocumentAccessError,
               case .permissionRequired = accessError {
                permissionRequest = MobileDocumentPermissionRequest(url: url)
            }
            errorMessage = error.localizedDescription
        }
    }

    public func refreshIfChanged() async {
        guard let sourceURL else { return }
        var refreshedURL = sourceURL
        refreshedURL.removeCachedResourceValue(forKey: .contentModificationDateKey)
        let values = try? refreshedURL.resourceValues(forKeys: [.contentModificationDateKey])
        guard values?.contentModificationDate != document?.sourceModificationDate else { return }
        await load(url: refreshedURL)
    }

    public func apply(_ document: MarkdownDocument, sourceURL: URL? = nil) {
        let resolvedURL = sourceURL ?? document.sourceURL
        let resolvedDocument = MarkdownDocument(
            sourceURL: resolvedURL,
            sourceModificationDate: document.sourceModificationDate,
            title: document.title,
            markdown: document.markdown,
            blocks: document.blocks
        )
        revision &+= 1
        documentRevision &+= 1
        self.document = resolvedDocument
        self.sourceURL = resolvedURL
        presentation = presenter.prepare(document: resolvedDocument)
        cachedPDF = nil
        pdfState = .idle
        errorMessage = nil
        permissionRequest = nil
    }

    public var remoteImageReferences: [RemoteImageReference] {
        document.map(RemoteImageCatalog.references) ?? []
    }

    public var uncachedRemoteImageSources: [String] {
        remoteImageReferences
            .map(\.source)
            .filter { remoteImageCache.cachedFileURL(for: $0) == nil }
    }

    public func authorizeDirectory(_ directoryURL: URL) throws {
        guard let permissionRequest else {
            throw MobileDirectoryAccessError.noPendingRequest
        }
        guard MobileDirectoryAuthorization.contains(permissionRequest.url, within: directoryURL) else {
            throw MobileDirectoryAccessError.wrongFolder(permissionRequest.filename)
        }
        try directoryAccessStore.authorize(directoryURL: directoryURL)
    }

    public func pdfData() async throws -> Data {
        guard let document else { throw MobileDocumentSessionError.noDocument }
        if let cachedPDF, cachedPDF.revision == revision {
            pdfState = .ready
            return cachedPDF.data
        }
        if let pdfTask { return try await pdfTask.value }

        let requestedRevision = revision
        pdfState = .preparing
        let provider = pdfProvider
        let task = Task { try await provider(document) }
        pdfTask = task
        do {
            let data = try await task.value
            guard requestedRevision == revision else { throw CancellationError() }
            cachedPDF = (requestedRevision, data)
            pdfState = .ready
            pdfTask = nil
            return data
        } catch is CancellationError {
            pdfTask = nil
            if pdfState == .preparing { pdfState = .idle }
            throw CancellationError()
        } catch {
            pdfTask = nil
            pdfState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            throw error
        }
    }

    public func cancelPDFGeneration() {
        pdfTask?.cancel()
        pdfTask = nil
        if pdfState == .preparing { pdfState = .idle }
    }

    public func downloadRemoteImage(source: String) async {
        guard remoteImageReferences.contains(where: { $0.source == source }),
              remoteImageCache.cachedFileURL(for: source) == nil,
              !downloadingRemoteImageSources.contains(source) else {
            return
        }
        errorMessage = nil
        downloadingRemoteImageSources.insert(source)
        defer { downloadingRemoteImageSources.remove(source) }
        do {
            _ = try await remoteImageDownloader.download(source: source)
            remoteImageDidChange()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func downloadAllRemoteImages() async {
        await downloadAllRemoteImages(reportFailures: true)
    }

    public func loadRemoteImagesIfAvailable() async {
        await downloadAllRemoteImages(reportFailures: false)
    }

    private func downloadAllRemoteImages(reportFailures: Bool) async {
        let sources = uncachedRemoteImageSources.filter {
            !downloadingRemoteImageSources.contains($0)
        }
        guard !sources.isEmpty else { return }
        errorMessage = nil
        downloadingRemoteImageSources.formUnion(sources)
        let downloader = remoteImageDownloader
        let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        _ = try await downloader.download(source: source)
                        return false
                    } catch {
                        return true
                    }
                }
            }
            var failures = 0
            for await failed in group where failed { failures += 1 }
            return failures
        }
        downloadingRemoteImageSources.subtract(sources)
        if failures < sources.count { remoteImageDidChange() }
        if reportFailures && failures > 0 {
            errorMessage = failures == 1
                ? "One remote image could not be downloaded."
                : "\(failures) remote images could not be downloaded."
        }
    }

    private func remoteImageDidChange() {
        cancelPDFGeneration()
        cachedPDF = nil
        pdfState = .idle
        revision &+= 1
        remoteImageRevision &+= 1
    }

    public func clearError() {
        errorMessage = nil
    }
}
#endif

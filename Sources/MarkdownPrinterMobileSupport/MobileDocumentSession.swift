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
    @Published public private(set) var metadata: MobileDocumentMetadata?
    @Published public private(set) var pdfState: MobilePDFPreparationState = .idle
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var revision: UInt64 = 0

    public var title: String { presentation?.title ?? sourceURL?.lastPathComponent ?? "Markdown Printer" }
    public var fileActions: MobileFileActionAvailability {
        MobileFileActionAvailability.resolve(for: sourceURL)
    }

    private let presenter: MobileMarkdownPresenter
    private let loader: MobileDocumentLoader
    private let pdfProvider: @MainActor (MarkdownDocument) async throws -> Data
    private var securityLease: SecurityScopedResourceLease?
    private var cachedPDF: (revision: UInt64, data: Data)?
    private var pdfTask: Task<Data, Error>?

    public init(
        document: MarkdownDocument? = nil,
        sourceURL: URL? = nil,
        presenter: MobileMarkdownPresenter = MobileMarkdownPresenter(),
        loader: MobileDocumentLoader = MobileDocumentLoader(),
        pdfConfiguration: MobilePDFConfiguration = .letter
    ) {
        self.presenter = presenter
        self.loader = loader
        let exporter = MobilePDFExporter(configuration: pdfConfiguration)
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
        pdfProvider: @escaping @MainActor (MarkdownDocument) async throws -> Data
    ) {
        self.presenter = presenter
        self.loader = loader
        self.pdfProvider = pdfProvider
        if let document {
            apply(document, sourceURL: sourceURL ?? document.sourceURL)
        }
    }

    public func load(url: URL) async {
        cancelPDFGeneration()
        let nextLease = SecurityScopedResourceLease(url: url)
        do {
            let document = try await loader.load(at: url)
            securityLease = nextLease
            apply(document, sourceURL: url)
        } catch is CancellationError {
            return
        } catch {
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
        self.document = resolvedDocument
        self.sourceURL = resolvedURL
        presentation = presenter.prepare(document: resolvedDocument)
        metadata = MobileDocumentMetadata.load(from: resolvedURL)
        cachedPDF = nil
        pdfState = .idle
        errorMessage = nil
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

    public func updateSourceURL(_ url: URL) {
        securityLease = SecurityScopedResourceLease(url: url)
        sourceURL = url
        metadata = MobileDocumentMetadata.load(from: url)
        if let document { apply(document, sourceURL: url) }
    }

    public func clearError() {
        errorMessage = nil
    }
}
#endif

import AppKit
import Combine
import Foundation
import MarkdownPrinterCore

@MainActor
public final class DocumentSession: ObservableObject {
    @Published public private(set) var renderedSnapshot: RenderedDocumentSnapshot?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isPreparingDocument = false
    @Published public private(set) var downloadingRemoteImageSources = Set<String>()

    public private(set) var renderer: MarkdownRenderer
    public private(set) var exporter: PDFExporter
    public let wordExporter: WordExporter
    public let remoteImageCache: RemoteImageCache
    @Published public private(set) var activePageSetup: DocumentPageSetup
    @Published public private(set) var hasExplicitPageSetup = false
    private let baseRendererConfiguration: RendererConfiguration
    private let pagePreferences: PagePreferences?
    private var preferenceObservation: AnyCancellable?
    private let sourceMonitorFactory: (URL, @escaping () -> Void) -> SourceChangeMonitoring
    private let remoteImageDownloader: any RemoteImageDownloading
    private var sourceMonitor: SourceChangeMonitoring?
    private var sourceMonitorLifetime: SourceMonitorLifetime?
    private var nextRenderRevision: UInt64 = 0
    private var nextPreparationRevision: UInt64 = 0

    public init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        exporter: PDFExporter? = nil,
        wordExporter: WordExporter? = nil,
        pagePreferences: PagePreferences? = nil,
        remoteImageCache: RemoteImageCache = .applicationDefault,
        remoteImageDownloader: (any RemoteImageDownloading)? = nil
    ) {
        baseRendererConfiguration = renderer.configuration
        self.pagePreferences = pagePreferences
        self.remoteImageCache = remoteImageCache
        self.remoteImageDownloader = remoteImageDownloader
            ?? RemoteImageDownloader(cache: remoteImageCache)
        let initialPageSetup = pagePreferences?.defaultPageSetup ?? .letter
        activePageSetup = initialPageSetup
        let configuredRenderer = MarkdownRenderer(
            configuration: pagePreferences == nil
                ? renderer.configuration
                : renderer.configuration.applying(initialPageSetup),
            remoteImageCache: remoteImageCache
        )
        self.renderer = configuredRenderer
        self.exporter = exporter ?? PDFExporter(
            configuration: configuredRenderer.configuration,
            pageSetup: initialPageSetup
        )
        self.wordExporter = wordExporter ?? WordExporter()
        self.sourceMonitorFactory = { url, onChange in
            SourceFileMonitor(sourceURL: url, onChange: onChange)
        }
        observePagePreferences()
    }

    init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        exporter: PDFExporter? = nil,
        wordExporter: WordExporter? = nil,
        pagePreferences: PagePreferences? = nil,
        remoteImageCache: RemoteImageCache = .applicationDefault,
        remoteImageDownloader: (any RemoteImageDownloading)? = nil,
        sourceMonitorFactory: @escaping (URL, @escaping () -> Void) -> SourceChangeMonitoring
    ) {
        baseRendererConfiguration = renderer.configuration
        self.pagePreferences = pagePreferences
        self.remoteImageCache = remoteImageCache
        self.remoteImageDownloader = remoteImageDownloader
            ?? RemoteImageDownloader(cache: remoteImageCache)
        let initialPageSetup = pagePreferences?.defaultPageSetup ?? .letter
        activePageSetup = initialPageSetup
        let configuredRenderer = MarkdownRenderer(
            configuration: pagePreferences == nil
                ? renderer.configuration
                : renderer.configuration.applying(initialPageSetup),
            remoteImageCache: remoteImageCache
        )
        self.renderer = configuredRenderer
        self.exporter = exporter ?? PDFExporter(
            configuration: configuredRenderer.configuration,
            pageSetup: initialPageSetup
        )
        self.wordExporter = wordExporter ?? WordExporter()
        self.sourceMonitorFactory = sourceMonitorFactory
        observePagePreferences()
    }

    public var document: MarkdownDocument? {
        renderedSnapshot?.document
    }

    public var renderedText: NSAttributedString {
        renderedSnapshot?.renderedText ?? NSAttributedString(string: "")
    }

    public var renderedPDFData: Data? {
        renderedSnapshot?.pdfData
    }

    public var title: String {
        document?.title ?? "Markdown Printer"
    }

    public var hasDocument: Bool {
        document != nil
    }

    public var remoteImageReferences: [RemoteImageReference] {
        document.map(RemoteImageCatalog.references) ?? []
    }

    public var uncachedRemoteImageSources: [String] {
        remoteImageReferences
            .map(\.source)
            .filter { remoteImageCache.cachedFileURL(for: $0) == nil }
    }

    public var suggestedPDFFileName: String {
        suggestedFileName(for: .pdf)
    }

    public var suggestedWordFileName: String {
        suggestedFileName(for: .word)
    }

    public func suggestedFileName(for format: ExportFormat) -> String {
        if let sourceURL = document?.sourceURL {
            return sourceURL.deletingPathExtension().lastPathComponent + ".\(format.pathExtension)"
        }

        let fallback = title
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = fallback.isEmpty ? "Untitled" : fallback
        if baseName.lowercased().hasSuffix(".\(format.pathExtension)") {
            return baseName
        }
        let lowercasedBaseName = baseName.lowercased()
        let nameWithoutExportExtension = ExportFormat.allCases.contains {
            lowercasedBaseName.hasSuffix(".\($0.pathExtension)")
        } ? (baseName as NSString).deletingPathExtension : baseName
        return nameWithoutExportExtension + ".\(format.pathExtension)"
    }

    public func load(url: URL) {
        do {
            let accessesSecurityScopedResource = url.startAccessingSecurityScopedResource()
            defer {
                if accessesSecurityScopedResource { url.stopAccessingSecurityScopedResource() }
            }
            try apply(MarkdownDocument.load(from: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func load(data: Data, suggestedTitle: String = "Untitled") {
        do {
            try apply(MarkdownDocument.decode(data: data, suggestedTitle: suggestedTitle))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func apply(_ document: MarkdownDocument) throws {
        try rebuild(document: document, pageSetup: activePageSetup)
    }

    public func applyAsync(_ document: MarkdownDocument) async throws {
        try await rebuildAsync(document: document, pageSetup: activePageSetup)
    }

    public func applyExplicitPageSetup(_ pageSetup: DocumentPageSetup) throws {
        if let document {
            try rebuild(document: document, pageSetup: pageSetup, explicit: true)
        } else {
            activePageSetup = pageSetup
            hasExplicitPageSetup = true
        }
    }

    public func clearPageSetupOverride() throws {
        let pageSetup = pagePreferences?.defaultPageSetup ?? .letter
        if let document {
            try rebuild(document: document, pageSetup: pageSetup, explicit: false)
        } else {
            activePageSetup = pageSetup
            hasExplicitPageSetup = false
        }
    }

    private func rebuild(
        document: MarkdownDocument,
        pageSetup: DocumentPageSetup,
        explicit: Bool? = nil,
        footers: ResolvedFooterConfiguration? = nil
    ) throws {
        nextPreparationRevision &+= 1
        isPreparingDocument = false
        let nextConfiguration = baseRendererConfiguration.applying(pageSetup)
        let nextRenderer = MarkdownRenderer(
            configuration: nextConfiguration,
            remoteImageCache: remoteImageCache
        )
        let nextExporter = PDFExporter(
            configuration: nextConfiguration,
            pageSetup: pageSetup
        )
        let nextRenderedText = NSAttributedString(
            attributedString: nextRenderer.render(document: document)
        )
        let footers = footers ?? pagePreferences?.resolvedFooters(for: document)
            ?? ResolvedFooterConfiguration()
        let nextPDFData = try nextExporter.pdfData(from: nextRenderedText, footers: footers)
        nextRenderRevision &+= 1
        renderer = nextRenderer
        exporter = nextExporter
        activePageSetup = pageSetup
        if let explicit { hasExplicitPageSetup = explicit }
        renderedSnapshot = RenderedDocumentSnapshot(
            document: document,
            renderedText: nextRenderedText,
            pdfData: nextPDFData,
            pageSetup: pageSetup,
            footers: footers,
            revision: nextRenderRevision
        )
        errorMessage = nil
    }

    private func rebuildAsync(
        document: MarkdownDocument,
        pageSetup: DocumentPageSetup,
        explicit: Bool? = nil,
        footers: ResolvedFooterConfiguration? = nil
    ) async throws {
        nextPreparationRevision &+= 1
        let preparationRevision = nextPreparationRevision
        isPreparingDocument = true
        defer {
            if preparationRevision == nextPreparationRevision {
                isPreparingDocument = false
            }
        }
        let nextConfiguration = baseRendererConfiguration.applying(pageSetup)
        let resolvedFooters = footers ?? pagePreferences?.resolvedFooters(for: document)
            ?? ResolvedFooterConfiguration()
        let job = DocumentAttributedTextJob(
            document: document,
            configuration: nextConfiguration,
            remoteImageCache: remoteImageCache
        )
        let preparedText = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return job.run()
        }.value
        let renderedText = preparedText.value
        try Task.checkCancellation()
        guard preparationRevision == nextPreparationRevision else { return }
        let pdfData = try await PDFExporter(
            configuration: nextConfiguration,
            pageSetup: pageSetup
        ).pdfDataAsync(from: renderedText, footers: resolvedFooters)
        try Task.checkCancellation()
        guard preparationRevision == nextPreparationRevision else { return }

        nextRenderRevision &+= 1
        renderer = MarkdownRenderer(
            configuration: nextConfiguration,
            remoteImageCache: remoteImageCache
        )
        exporter = PDFExporter(configuration: nextConfiguration, pageSetup: pageSetup)
        activePageSetup = pageSetup
        if let explicit { hasExplicitPageSetup = explicit }
        renderedSnapshot = RenderedDocumentSnapshot(
            document: document,
            renderedText: renderedText,
            pdfData: pdfData,
            pageSetup: pageSetup,
            footers: resolvedFooters,
            revision: nextRenderRevision
        )
        errorMessage = nil
    }

    @discardableResult
    public func synchronize(with document: MarkdownDocument) throws -> Bool {
        let document = preservingKnownModificationDate(in: document)
        guard document != self.document else { return false }
        try apply(document)
        return true
    }

    @discardableResult
    public func synchronizeAsync(with document: MarkdownDocument) async throws -> Bool {
        let document = preservingKnownModificationDate(in: document)
        guard document != self.document else { return false }
        try await applyAsync(document)
        return true
    }

    private func preservingKnownModificationDate(
        in document: MarkdownDocument
    ) -> MarkdownDocument {
        guard document.sourceModificationDate == nil,
              document.sourceURL?.standardizedFileURL == self.document?.sourceURL?.standardizedFileURL,
              let knownDate = self.document?.sourceModificationDate
        else { return document }
        return MarkdownDocument(
            sourceURL: document.sourceURL,
            sourceModificationDate: knownDate,
            title: document.title,
            markdown: document.markdown,
            blocks: document.blocks
        )
    }

    public func startMonitoringSourceChanges() {
        guard let sourceURL = document?.sourceURL else { return }
        if sourceMonitor?.sourceURL == sourceURL.standardizedFileURL,
           sourceMonitor?.isMonitoring == true {
            reloadSourceIfChanged()
            return
        }

        stopMonitoringSourceChanges()
        let monitor = sourceMonitorFactory(sourceURL) { [weak self] in
            self?.reloadSourceIfChanged()
        }
        sourceMonitor = monitor
        sourceMonitorLifetime = SourceMonitorLifetime(monitor: monitor)
        monitor.start()
        reloadSourceIfChanged()
    }

    public func stopMonitoringSourceChanges() {
        sourceMonitor?.stop()
        sourceMonitorLifetime?.cancel()
        sourceMonitorLifetime = nil
        sourceMonitor = nil
    }

    private func reloadSourceIfChanged() {
        guard let sourceURL = document?.sourceURL else { return }
        do {
            let accessesSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessesSecurityScopedResource { sourceURL.stopAccessingSecurityScopedResource() }
            }
            let nextDocument = try MarkdownDocument.load(from: sourceURL)
            try synchronize(with: nextDocument)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearError() {
        errorMessage = nil
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
            guard let document else { return }
            try rebuild(document: document, pageSetup: activePageSetup)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func downloadAllRemoteImages() async {
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
        if failures < sources.count, let document {
            do {
                try rebuild(document: document, pageSetup: activePageSetup)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if failures > 0 {
            errorMessage = failures == 1
                ? "One remote image could not be downloaded."
                : "\(failures) remote images could not be downloaded."
        }
    }

    public func report(error: Error) {
        errorMessage = error.localizedDescription
    }

    public func pdfData() throws -> Data {
        guard let renderedPDFData else { throw DocumentSessionError.noDocument }
        return renderedPDFData
    }

    public func exportData(as format: ExportFormat) throws -> Data {
        guard hasDocument else { throw DocumentSessionError.noDocument }
        switch format {
        case .pdf:
            return try pdfData()
        case .word:
            guard let renderedSnapshot else { throw DocumentSessionError.noDocument }
            return try wordExporter.wordData(
                from: renderedSnapshot.renderedText,
                pageSetup: renderedSnapshot.pageSetup,
                footers: renderedSnapshot.footers
            )
        }
    }

    public func savePDF(to url: URL) throws {
        try save(to: url, as: .pdf)
    }

    public func save(to url: URL, as format: ExportFormat) throws {
        try exportData(as: format).write(to: url, options: .atomic)
    }

    public func printOperation() throws -> NSPrintOperation {
        guard let renderedPDFData else { throw DocumentSessionError.noDocument }
        return try exporter.printOperation(forPDFData: renderedPDFData)
    }

    private func observePagePreferences() {
        guard let pagePreferences else { return }
        preferenceObservation = Publishers.CombineLatest3(
            pagePreferences.$defaultPageSetup,
            pagePreferences.$leftFooter,
            pagePreferences.$rightFooter
        )
        .dropFirst()
        .sink { [weak self] defaultPageSetup, leftFooter, rightFooter in
            guard let self, let document = self.document else { return }
            let pageSetup = self.hasExplicitPageSetup ? self.activePageSetup : defaultPageSetup
            let footers = ResolvedFooterConfiguration(
                left: leftFooter.resolved(for: document),
                right: rightFooter.resolved(for: document)
            )
            do {
                try self.rebuild(
                    document: document,
                    pageSetup: pageSetup,
                    footers: footers
                )
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

public struct RenderedDocumentSnapshot {
    public let document: MarkdownDocument
    public let renderedText: NSAttributedString
    public let pdfData: Data
    public let pageSetup: DocumentPageSetup
    public let footers: ResolvedFooterConfiguration
    public let revision: UInt64
}

private struct DocumentAttributedTextJob: @unchecked Sendable {
    let document: MarkdownDocument
    let configuration: RendererConfiguration
    let remoteImageCache: RemoteImageCache

    func run() -> PreparedAttributedText {
        let renderer = MarkdownRenderer(
            configuration: configuration,
            remoteImageCache: remoteImageCache
        )
        return PreparedAttributedText(
            value: NSAttributedString(
                attributedString: renderer.render(document: document)
            )
        )
    }
}

private struct PreparedAttributedText: @unchecked Sendable {
    let value: NSAttributedString
}

private final class SourceMonitorLifetime {
    private var monitor: SourceChangeMonitoring?

    init(monitor: SourceChangeMonitoring) {
        self.monitor = monitor
    }

    func cancel() {
        monitor = nil
    }

    deinit {
        guard let monitor else { return }
        Task { @MainActor in
            monitor.stop()
        }
    }
}

public enum DocumentSessionError: LocalizedError, Equatable {
    case noDocument

    public var errorDescription: String? {
        "Open a Markdown file before saving or printing."
    }
}

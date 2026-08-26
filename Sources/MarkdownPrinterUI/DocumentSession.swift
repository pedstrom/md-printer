import AppKit
import Combine
import Foundation
import MarkdownPrinterCore

@MainActor
public final class DocumentSession: ObservableObject {
    @Published public private(set) var renderedSnapshot: RenderedDocumentSnapshot?
    @Published public private(set) var errorMessage: String?

    public private(set) var renderer: MarkdownRenderer
    public private(set) var exporter: PDFExporter
    public let wordExporter: WordExporter
    @Published public private(set) var activePageSetup: DocumentPageSetup
    @Published public private(set) var hasExplicitPageSetup = false
    private let baseRendererConfiguration: RendererConfiguration
    private let pagePreferences: PagePreferences?
    private var preferenceObservation: AnyCancellable?
    private let sourceMonitorFactory: (URL, @escaping () -> Void) -> SourceChangeMonitoring
    private var sourceMonitor: SourceChangeMonitoring?
    private var sourceMonitorLifetime: SourceMonitorLifetime?
    private var nextRenderRevision: UInt64 = 0

    public init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        exporter: PDFExporter? = nil,
        wordExporter: WordExporter? = nil,
        pagePreferences: PagePreferences? = nil
    ) {
        baseRendererConfiguration = renderer.configuration
        self.pagePreferences = pagePreferences
        let initialPageSetup = pagePreferences?.defaultPageSetup ?? .letter
        activePageSetup = initialPageSetup
        let configuredRenderer = pagePreferences == nil
            ? renderer
            : MarkdownRenderer(configuration: renderer.configuration.applying(initialPageSetup))
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
        sourceMonitorFactory: @escaping (URL, @escaping () -> Void) -> SourceChangeMonitoring
    ) {
        baseRendererConfiguration = renderer.configuration
        self.pagePreferences = pagePreferences
        let initialPageSetup = pagePreferences?.defaultPageSetup ?? .letter
        activePageSetup = initialPageSetup
        let configuredRenderer = pagePreferences == nil
            ? renderer
            : MarkdownRenderer(configuration: renderer.configuration.applying(initialPageSetup))
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
        let nextConfiguration = baseRendererConfiguration.applying(pageSetup)
        let nextRenderer = MarkdownRenderer(configuration: nextConfiguration)
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

    @discardableResult
    public func synchronize(with document: MarkdownDocument) throws -> Bool {
        let document = preservingKnownModificationDate(in: document)
        guard document != self.document else { return false }
        try apply(document)
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
            markdown: document.markdown
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

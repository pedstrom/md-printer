import AppKit
import Foundation
import MarkdownPrinterCore

@MainActor
public final class DocumentSession: ObservableObject {
    @Published public private(set) var renderedSnapshot: RenderedDocumentSnapshot?
    @Published public private(set) var errorMessage: String?

    public let renderer: MarkdownRenderer
    public let exporter: PDFExporter
    public let wordExporter: WordExporter
    private let sourceMonitorFactory: (URL, @escaping () -> Void) -> SourceChangeMonitoring
    private var sourceMonitor: SourceChangeMonitoring?
    private var sourceMonitorLifetime: SourceMonitorLifetime?
    private var nextRenderRevision: UInt64 = 0

    public init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        exporter: PDFExporter? = nil,
        wordExporter: WordExporter? = nil
    ) {
        self.renderer = renderer
        self.exporter = exporter ?? PDFExporter(configuration: renderer.configuration)
        self.wordExporter = wordExporter ?? WordExporter()
        self.sourceMonitorFactory = { url, onChange in
            SourceFileMonitor(sourceURL: url, onChange: onChange)
        }
    }

    init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        exporter: PDFExporter? = nil,
        wordExporter: WordExporter? = nil,
        sourceMonitorFactory: @escaping (URL, @escaping () -> Void) -> SourceChangeMonitoring
    ) {
        self.renderer = renderer
        self.exporter = exporter ?? PDFExporter(configuration: renderer.configuration)
        self.wordExporter = wordExporter ?? WordExporter()
        self.sourceMonitorFactory = sourceMonitorFactory
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
        let nextRenderedText = NSAttributedString(
            attributedString: renderer.render(document: document)
        )
        let nextPDFData = try exporter.pdfData(from: nextRenderedText)
        nextRenderRevision &+= 1
        renderedSnapshot = RenderedDocumentSnapshot(
            document: document,
            renderedText: nextRenderedText,
            pdfData: nextPDFData,
            revision: nextRenderRevision
        )
        errorMessage = nil
    }

    @discardableResult
    public func synchronize(with document: MarkdownDocument) throws -> Bool {
        guard document != self.document else { return false }
        try apply(document)
        return true
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
            return try wordExporter.wordData(from: renderedText)
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
}

public struct RenderedDocumentSnapshot {
    public let document: MarkdownDocument
    public let renderedText: NSAttributedString
    public let pdfData: Data
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

import AppKit
import Foundation
import MarkdownPrinterCore

@MainActor
public final class DocumentSession: ObservableObject {
    @Published public private(set) var document: MarkdownDocument?
    @Published public private(set) var renderedText = NSAttributedString(string: "")
    @Published public private(set) var renderedPDFData: Data?
    @Published public private(set) var errorMessage: String?

    public let renderer: MarkdownRenderer
    public let exporter: PDFExporter
    public let wordExporter: WordExporter

    public init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        exporter: PDFExporter? = nil,
        wordExporter: WordExporter? = nil
    ) {
        self.renderer = renderer
        self.exporter = exporter ?? PDFExporter(configuration: renderer.configuration)
        self.wordExporter = wordExporter ?? WordExporter()
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
        let nextRenderedText = renderer.render(document: document)
        let nextPDFData = try exporter.pdfData(from: nextRenderedText)
        self.document = document
        renderedText = nextRenderedText
        renderedPDFData = nextPDFData
        errorMessage = nil
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

public enum DocumentSessionError: LocalizedError, Equatable {
    case noDocument

    public var errorDescription: String? {
        "Open a Markdown file before saving or printing."
    }
}

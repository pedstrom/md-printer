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

    public init(
        renderer: MarkdownRenderer = MarkdownRenderer(),
        exporter: PDFExporter? = nil
    ) {
        self.renderer = renderer
        self.exporter = exporter ?? PDFExporter(configuration: renderer.configuration)
    }

    public var title: String {
        document?.title ?? "Markdown Printer"
    }

    public var hasDocument: Bool {
        document != nil
    }

    public var suggestedPDFFileName: String {
        if let sourceURL = document?.sourceURL {
            return sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
        }

        let fallback = title
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = fallback.isEmpty ? "Untitled" : fallback
        return baseName.lowercased().hasSuffix(".pdf") ? baseName : baseName + ".pdf"
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

    public func savePDF(to url: URL) throws {
        guard let renderedPDFData else { throw DocumentSessionError.noDocument }
        try renderedPDFData.write(to: url, options: .atomic)
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

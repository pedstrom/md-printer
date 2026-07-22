import Foundation
import MarkdownPrinterCore
import SwiftUI
import UniformTypeIdentifiers

public struct MarkdownFileDocument: FileDocument {
    public static let markdownContentType = UTType(importedAs: "net.daringfireball.markdown")
    public static let readableContentTypes: [UTType] = [markdownContentType]

    private let data: Data
    private let decodedDocument: MarkdownDocument

    public init(data: Data) throws {
        self.data = data
        self.decodedDocument = try MarkdownDocument.decode(data: data)
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    public func markdownDocument(sourceURL: URL?) -> MarkdownDocument {
        MarkdownDocument(
            sourceURL: sourceURL,
            title: sourceURL?.deletingPathExtension().lastPathComponent ?? decodedDocument.title,
            markdown: decodedDocument.markdown
        )
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

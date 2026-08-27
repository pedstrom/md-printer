import MarkdownPrinterCore
import SwiftUI
import UniformTypeIdentifiers

struct MobileMarkdownFileDocument: FileDocument {
    static let markdownContentType = UTType(importedAs: "net.daringfireball.markdown")
    static let readableContentTypes: [UTType] = [markdownContentType]

    private let data: Data
    private let decodedDocument: MarkdownDocument

    init(data: Data) throws {
        self.data = data
        decodedDocument = try MarkdownDocument.decode(data: data)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    func markdownDocument(sourceURL: URL?) -> MarkdownDocument {
        let modificationDate = sourceURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } ?? nil
        return MarkdownDocument(
            sourceURL: sourceURL,
            sourceModificationDate: modificationDate,
            title: sourceURL?.deletingPathExtension().lastPathComponent ?? decodedDocument.title,
            markdown: decodedDocument.markdown,
            blocks: decodedDocument.blocks
        )
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

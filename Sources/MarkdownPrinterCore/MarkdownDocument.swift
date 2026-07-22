import Foundation

public struct MarkdownDocument: Equatable, Sendable {
    public let sourceURL: URL?
    public let title: String
    public let markdown: String

    public init(sourceURL: URL? = nil, title: String, markdown: String) {
        self.sourceURL = sourceURL
        self.title = Self.markdownTitle(in: markdown) ?? title
        self.markdown = markdown
    }

    public static func load(from url: URL) throws -> MarkdownDocument {
        let data = try Data(contentsOf: url)
        return try decode(data: data, sourceURL: url)
    }

    public static func decode(
        data: Data,
        sourceURL: URL? = nil,
        suggestedTitle: String? = nil
    ) throws -> MarkdownDocument {
        let markdown: String
        if let utf8 = String(data: data, encoding: .utf8) {
            markdown = utf8
        } else if data.hasUTF16ByteOrderMark,
                  data.count.isMultiple(of: 2),
                  let utf16 = String(data: data, encoding: .utf16) {
            markdown = utf16
        } else {
            throw MarkdownDocumentError.unsupportedTextEncoding
        }

        let title = suggestedTitle
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? "Untitled"
        return MarkdownDocument(sourceURL: sourceURL, title: title, markdown: markdown)
    }

    public var baseURL: URL? {
        sourceURL?.deletingLastPathComponent()
    }

    private static func markdownTitle(in markdown: String) -> String? {
        for block in MarkdownParser().parse(markdown) {
            guard case let .heading(level, content) = block, level == 1 else { continue }
            let title = plainText(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func plainText(from nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case let .text(text), let .code(text):
                return text
            case let .emphasis(children),
                 let .strong(children),
                 let .underline(children),
                 let .strikethrough(children):
                return plainText(from: children)
            case let .link(children, _):
                return plainText(from: children)
            case let .image(alt, _):
                return alt
            case .lineBreak:
                return " "
            }
        }.joined()
    }
}

private extension Data {
    var hasUTF16ByteOrderMark: Bool {
        count >= 2 && ((self[startIndex] == 0xFF && self[index(after: startIndex)] == 0xFE)
            || (self[startIndex] == 0xFE && self[index(after: startIndex)] == 0xFF))
    }
}

public enum MarkdownDocumentError: LocalizedError, Equatable {
    case unsupportedTextEncoding

    public var errorDescription: String? {
        switch self {
        case .unsupportedTextEncoding:
            return "The file is not valid UTF-8 or UTF-16 text."
        }
    }
}

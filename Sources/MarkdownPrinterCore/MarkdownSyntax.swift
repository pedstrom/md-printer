import Foundation

public indirect enum InlineNode: Equatable, Sendable {
    case text(String)
    case emphasis([InlineNode])
    case strong([InlineNode])
    case underline([InlineNode])
    case strikethrough([InlineNode])
    case code(String)
    case link(children: [InlineNode], destination: String)
    case image(alt: String, source: String)
    case lineBreak
}

public enum TableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

public struct MarkdownListItem: Equatable, Sendable {
    public let content: [InlineNode]
    public let checked: Bool?

    public init(content: [InlineNode], checked: Bool? = nil) {
        self.content = content
        self.checked = checked
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: [InlineNode])
    case paragraph([InlineNode])
    case blockquote([InlineNode])
    case list(items: [MarkdownListItem], ordered: Bool, start: Int)
    case codeBlock(language: String?, code: String)
    case thematicBreak
    case table(
        headers: [[InlineNode]],
        alignments: [TableAlignment],
        rows: [[[InlineNode]]]
    )
}

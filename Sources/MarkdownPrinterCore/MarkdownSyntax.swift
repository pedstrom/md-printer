import Foundation

public indirect enum InlineNode: Equatable, Sendable {
    case text(String)
    case emphasis([InlineNode])
    case strong([InlineNode])
    case underline([InlineNode])
    case strikethrough([InlineNode])
    case code(String)
    case link(children: [InlineNode], destination: String, title: String? = nil)
    case footnoteReference(label: String)
    case image(alt: String, source: String, title: String? = nil)
    case rawHTML(String)
    case softBreak
    case hardBreak
}

public enum TableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing
}

public struct MarkdownListItem: Equatable, Sendable {
    public let blocks: [MarkdownBlock]
    public let checked: Bool?

    public init(content: [InlineNode], checked: Bool? = nil) {
        self.blocks = [.paragraph(content)]
        self.checked = checked
    }

    public init(blocks: [MarkdownBlock], checked: Bool? = nil) {
        self.blocks = blocks
        self.checked = checked
    }

    public var content: [InlineNode] {
        guard case let .paragraph(content) = blocks.first else { return [] }
        return content
    }
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: [InlineNode])
    case paragraph([InlineNode])
    case blockquote([MarkdownBlock])
    case list(items: [MarkdownListItem], ordered: Bool, start: Int, tight: Bool = true)
    case codeBlock(language: String?, code: String)
    case rawHTML(String)
    case thematicBreak
    case footnoteDefinition(label: String, content: [InlineNode])
    case table(
        headers: [[InlineNode]],
        alignments: [TableAlignment],
        rows: [[[InlineNode]]]
    )
}

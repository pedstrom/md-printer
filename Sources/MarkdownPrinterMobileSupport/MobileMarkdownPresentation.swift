#if canImport(UIKit)
import Foundation
import MarkdownPrinterCore

public struct MobileMarkdownPresentation: Equatable, Sendable {
    public let title: String
    public let sourceURL: URL?
    public let blocks: [MobileMarkdownPresentationBlock]
    public let footnotes: [MobileMarkdownFootnote]
    public let footnoteNumbers: [String: Int]

    public init(
        title: String,
        sourceURL: URL?,
        blocks: [MobileMarkdownPresentationBlock],
        footnotes: [MobileMarkdownFootnote],
        footnoteNumbers: [String: Int]
    ) {
        self.title = title
        self.sourceURL = sourceURL
        self.blocks = blocks
        self.footnotes = footnotes
        self.footnoteNumbers = footnoteNumbers
    }

    public var searchIndex: MarkdownSearchIndex {
        MarkdownSearchIndex(
            entries: blocks.map {
                MarkdownSearchEntry(blockID: $0.id, text: $0.plainText)
            } + footnotes.map {
                MarkdownSearchEntry(blockID: $0.id, text: $0.plainText)
            }
        )
    }
}

public struct MobileMarkdownPresentationBlock: Identifiable, Equatable, Sendable {
    public let id: String
    public let block: MarkdownBlock
    public let plainText: String

    public init(id: String, block: MarkdownBlock, plainText: String) {
        self.id = id
        self.block = block
        self.plainText = plainText
    }
}

public struct MobileMarkdownFootnote: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let number: Int
    public let content: [InlineNode]
    public let plainText: String

    public init(
        id: String,
        label: String,
        number: Int,
        content: [InlineNode],
        plainText: String
    ) {
        self.id = id
        self.label = label
        self.number = number
        self.content = content
        self.plainText = plainText
    }
}

public struct MobileMarkdownPresenter: Sendable {
    public init() {}

    public func prepare(document: MarkdownDocument) -> MobileMarkdownPresentation {
        let body = document.blocks.filter {
            if case .footnoteDefinition = $0 { return false }
            return true
        }
        let definitions = document.blocks.compactMap { block -> (String, [InlineNode])? in
            guard case let .footnoteDefinition(label, content) = block else { return nil }
            return (label, content)
        }
        let definitionLookup = Dictionary(definitions, uniquingKeysWith: { first, _ in first })

        var orderedLabels: [String] = []
        var seen = Set<String>()
        for label in body.flatMap(footnoteReferenceLabels) where definitionLookup[label] != nil {
            if seen.insert(label).inserted { orderedLabels.append(label) }
        }
        for (label, _) in definitions where seen.insert(label).inserted {
            orderedLabels.append(label)
        }

        let footnoteNumbers = Dictionary(
            uniqueKeysWithValues: orderedLabels.enumerated().map { ($0.element, $0.offset + 1) }
        )
        let blocks = body.enumerated().map { index, block in
            MobileMarkdownPresentationBlock(
                id: "block-\(index)",
                block: block,
                plainText: plainText(from: block, footnoteNumbers: footnoteNumbers)
            )
        }
        let footnotes = orderedLabels.compactMap { label -> MobileMarkdownFootnote? in
            guard let content = definitionLookup[label], let number = footnoteNumbers[label] else {
                return nil
            }
            return MobileMarkdownFootnote(
                id: "footnote-\(label)",
                label: label,
                number: number,
                content: content,
                plainText: "\(number). " + plainText(from: content, footnoteNumbers: footnoteNumbers)
            )
        }

        return MobileMarkdownPresentation(
            title: document.title,
            sourceURL: document.sourceURL,
            blocks: blocks,
            footnotes: footnotes,
            footnoteNumbers: footnoteNumbers
        )
    }

    public func plainText(
        from nodes: [InlineNode],
        footnoteNumbers: [String: Int] = [:]
    ) -> String {
        nodes.map { node in
            switch node {
            case let .text(text), let .code(text), let .rawHTML(text):
                return text
            case let .emphasis(children),
                 let .strong(children),
                 let .underline(children),
                 let .strikethrough(children):
                return plainText(from: children, footnoteNumbers: footnoteNumbers)
            case let .link(children, _, _):
                return plainText(from: children, footnoteNumbers: footnoteNumbers)
            case let .footnoteReference(label):
                return footnoteNumbers[label].map { "[\($0)]" } ?? "[^\(label)]"
            case let .image(alt, _, _):
                return alt
            case .softBreak:
                return " "
            case .hardBreak:
                return "\n"
            }
        }.joined()
    }

    public func plainText(
        from block: MarkdownBlock,
        footnoteNumbers: [String: Int] = [:]
    ) -> String {
        switch block {
        case let .heading(_, content), let .paragraph(content), let .footnoteDefinition(_, content):
            return plainText(from: content, footnoteNumbers: footnoteNumbers)
        case let .blockquote(children):
            return children.map {
                plainText(from: $0, footnoteNumbers: footnoteNumbers)
            }.joined(separator: "\n")
        case let .list(items, ordered, start, _):
            return items.enumerated().map { index, item in
                let marker = ordered ? "\(start + index). " : "• "
                let task = item.checked.map { $0 ? "☑ " : "☐ " } ?? ""
                return marker + task + item.blocks.map {
                    plainText(from: $0, footnoteNumbers: footnoteNumbers)
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        case let .codeBlock(_, code):
            return code
        case let .rawHTML(source):
            return source
        case .thematicBreak:
            return ""
        case let .table(headers, _, rows):
            return ([headers] + rows).map { row in
                row.map {
                    plainText(from: $0, footnoteNumbers: footnoteNumbers)
                }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    private func footnoteReferenceLabels(in block: MarkdownBlock) -> [String] {
        switch block {
        case let .heading(_, content), let .paragraph(content), let .footnoteDefinition(_, content):
            return footnoteReferenceLabels(in: content)
        case let .blockquote(children):
            return children.flatMap(footnoteReferenceLabels)
        case let .list(items, _, _, _):
            return items.flatMap { $0.blocks.flatMap(footnoteReferenceLabels) }
        case let .table(headers, _, rows):
            return (headers + rows.flatMap { $0 }).flatMap(footnoteReferenceLabels)
        case .codeBlock, .rawHTML, .thematicBreak:
            return []
        }
    }

    private func footnoteReferenceLabels(in nodes: [InlineNode]) -> [String] {
        nodes.flatMap { node in
            switch node {
            case let .footnoteReference(label):
                return [label]
            case let .emphasis(children),
                 let .strong(children),
                 let .underline(children),
                 let .strikethrough(children),
                 let .link(children, _, _):
                return footnoteReferenceLabels(in: children)
            case .text, .code, .image, .rawHTML, .softBreak, .hardBreak:
                return []
            }
        }
    }
}
#endif

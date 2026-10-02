import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct MarkdownSection: Equatable, Sendable {
    public let anchor: String
    public let blockID: String
}

public struct MarkdownSectionCatalog: Equatable, Sendable {
    public let sections: [MarkdownSection]

    public init(blocks: [MarkdownBlock]) {
        var entries: [MarkdownSection] = []
        var used = Set<String>()
        func visit(_ block: MarkdownBlock, path: String) {
            switch block {
            case let .heading(_, content):
                let base = Self.slug(content)
                var anchor = base
                var suffix = 0
                while used.contains(anchor) { suffix += 1; anchor = "\(base)-\(suffix)" }
                used.insert(anchor)
                entries.append(MarkdownSection(anchor: anchor, blockID: path))
            case let .blockquote(children):
                for (index, child) in children.enumerated() { visit(child, path: "\(path)-quote-\(index)") }
            case let .list(items, _, _, _):
                for (index, item) in items.enumerated() {
                    for (childIndex, child) in item.blocks.enumerated() { visit(child, path: "\(path)-item-\(index)-\(childIndex)") }
                }
            default: break
            }
        }
        let body = blocks.filter { if case .footnoteDefinition = $0 { return false }; return true }
        for (index, block) in body.enumerated() { visit(block, path: "block-\(index)") }
        sections = entries
    }

    public func section(for fragment: String) -> MarkdownSection? {
        sections.first { $0.anchor == fragment }
    }

    public static func slug(_ content: [InlineNode]) -> String {
        let text = plainText(content).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == " " || $0 == "-" || $0 == "_" || CharacterSet.alphanumerics.contains($0)
                || CharacterSet.nonBaseCharacters.contains($0)
        })).replacingOccurrences(of: " ", with: "-")
    }

    private static func plainText(_ nodes: [InlineNode]) -> String {
        nodes.map {
            switch $0 {
            case let .text(value), let .code(value): return value
            case let .emphasis(children), let .strong(children), let .underline(children), let .strikethrough(children), let .link(children, _, _): return plainText(children)
            case let .image(alt, _, _): return alt
            case .softBreak, .hardBreak: return " "
            case .rawHTML, .footnoteReference: return ""
            }
        }.joined()
    }

    public func annotate(_ text: NSMutableAttributedString, sourceURL: URL? = nil) {
        let fullRange = NSRange(location: 0, length: text.length)
        var headings: [NSRange] = []
        text.enumerateAttribute(.markdownSectionAnchor, in: fullRange) { value, range, _ in
            if value != nil { headings.append(range) }
        }
        for (entry, range) in zip(sections, headings) { text.addAttribute(.markdownSectionAnchor, value: entry.anchor, range: range) }
        var references: [(String, NSRange)] = []
        text.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)),
                  let fragment = MarkdownLinkTarget.sectionFragment(from: url, sourceURL: sourceURL) else { return }
            references.append((fragment, range))
        }
        for (fragment, range) in references {
            text.removeAttribute(.link, range: range)
            text.addAttribute(.markdownSectionReference, value: fragment, range: range)
        }
    }
}

public extension NSAttributedString.Key {
    static let markdownSectionAnchor = Self("MarkdownPrinterSectionAnchor")
    static let markdownSectionReference = Self("MarkdownPrinterSectionReference")
}

public struct MarkdownNavigationRequest: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let fileURL: URL
    public let fragment: String?
    public init(fileURL: URL, fragment: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.fileURL = fileURL.standardizedFileURL
        self.fragment = fragment
    }
}

public enum MarkdownNavigationError: LocalizedError {
    case sectionNotFound(String)
    public var errorDescription: String? {
        switch self { case let .sectionNotFound(fragment): return "The section ‘\(fragment)’ could not be found in this document." }
    }
}

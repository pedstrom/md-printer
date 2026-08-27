#if canImport(UIKit)
import Foundation

public struct MarkdownSearchOptions: Equatable, Sendable {
    public var query: String
    public var matchCase: Bool
    public var wholeWord: Bool

    public init(query: String = "", matchCase: Bool = false, wholeWord: Bool = false) {
        self.query = query
        self.matchCase = matchCase
        self.wholeWord = wholeWord
    }
}

public struct MarkdownSearchEntry: Equatable, Sendable {
    public let blockID: String
    public let text: String

    public init(blockID: String, text: String) {
        self.blockID = blockID
        self.text = text
    }
}

public struct MarkdownSearchMatch: Identifiable, Equatable, Sendable {
    public let id: String
    public let blockID: String
    public let range: NSRange
    public let preview: String

    public init(id: String, blockID: String, range: NSRange, preview: String) {
        self.id = id
        self.blockID = blockID
        self.range = range
        self.preview = preview
    }
}

public struct MarkdownSearchIndex: Equatable, Sendable {
    public let entries: [MarkdownSearchEntry]

    public init(entries: [MarkdownSearchEntry]) {
        self.entries = entries
    }

    public func matches(for options: MarkdownSearchOptions) -> [MarkdownSearchMatch] {
        guard !options.query.isEmpty else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: options.query)
        let pattern = options.wholeWord
            ? "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
            : escaped
        let expressionOptions: NSRegularExpression.Options = options.matchCase ? [] : [.caseInsensitive]
        guard let expression = try? NSRegularExpression(pattern: pattern, options: expressionOptions) else {
            return []
        }

        var result: [MarkdownSearchMatch] = []
        for entry in entries {
            let fullRange = NSRange(location: 0, length: (entry.text as NSString).length)
            for match in expression.matches(in: entry.text, range: fullRange) {
                let preview = Self.preview(in: entry.text, around: match.range)
                result.append(
                    MarkdownSearchMatch(
                        id: "\(entry.blockID)-\(match.range.location)-\(match.range.length)",
                        blockID: entry.blockID,
                        range: match.range,
                        preview: preview
                    )
                )
            }
        }
        return result
    }

    private static func preview(in text: String, around range: NSRange) -> String {
        let string = text as NSString
        let padding = 28
        let location = max(0, range.location - padding)
        let end = min(string.length, NSMaxRange(range) + padding)
        var preview = string.substring(with: NSRange(location: location, length: end - location))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if location > 0 { preview = "…" + preview }
        if end < string.length { preview += "…" }
        return preview
    }
}
#endif

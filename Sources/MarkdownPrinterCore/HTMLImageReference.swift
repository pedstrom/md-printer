import Foundation

/// A deliberately narrow HTML extension for image tags.
///
/// Markdown Printer keeps arbitrary HTML inert, but routes a standalone `<img>`
/// tag through the same image pipeline as Markdown image syntax. Remote sources
/// remain inert unless a full-app session explicitly offers a user action.
public struct HTMLImageReference: Equatable, Sendable {
    public let source: String
    public let alternativeText: String
    public let title: String?
    public let requestedWidth: Double?

    public init?(html: String) {
        var parser = HTMLImageTagParser(source: html)
        guard let attributes = parser.parse(),
              let rawSource = attributes["src"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawSource.isEmpty else {
            return nil
        }

        source = CommonMarkEntityDecoder.decode(rawSource)
        alternativeText = CommonMarkEntityDecoder.decode(attributes["alt"] ?? "")
        title = attributes["title"].map(CommonMarkEntityDecoder.decode)
        requestedWidth = Self.width(from: attributes["width"])
    }

    private static func width(from source: String?) -> Double? {
        guard var source else { return nil }
        source = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if source.hasSuffix("px") {
            source.removeLast(2)
            source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let width = Double(source), width.isFinite, width > 0 else { return nil }
        return width
    }
}

private struct HTMLImageTagParser {
    let source: String
    private var index: String.Index

    init(source: String) {
        self.source = source
        self.index = source.startIndex
    }

    mutating func parse() -> [String: String]? {
        skipWhitespace()
        guard consume("<") else { return nil }
        let tagName = parseName()
        guard tagName.caseInsensitiveCompare("img") == .orderedSame else { return nil }

        var attributes: [String: String] = [:]
        while true {
            let hadWhitespace = skipWhitespace()
            if consume("/>") || consume(">") {
                skipWhitespace()
                return index == source.endIndex ? attributes : nil
            }
            guard hadWhitespace, let name = parseAttributeName() else { return nil }
            let afterName = index
            skipWhitespace()
            let value: String
            if consume("=") {
                skipWhitespace()
                guard let parsedValue = parseAttributeValue() else { return nil }
                value = parsedValue
            } else {
                index = afterName
                value = ""
            }
            let normalizedName = name.lowercased()
            if attributes[normalizedName] == nil {
                attributes[normalizedName] = value
            }
        }
    }

    @discardableResult
    private mutating func skipWhitespace() -> Bool {
        let start = index
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        return start != index
    }

    private mutating func consume(_ value: String) -> Bool {
        guard source[index...].hasPrefix(value) else { return false }
        index = source.index(index, offsetBy: value.count)
        return true
    }

    private mutating func parseName() -> String {
        let start = index
        while index < source.endIndex,
              source[index].isLetter || source[index].isNumber || source[index] == "-" {
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    private mutating func parseAttributeName() -> String? {
        guard index < source.endIndex,
              source[index].isLetter || source[index] == "_" || source[index] == ":" else {
            return nil
        }
        let start = index
        index = source.index(after: index)
        while index < source.endIndex,
              source[index].isLetter || source[index].isNumber || "_.:-".contains(source[index]) {
            index = source.index(after: index)
        }
        return String(source[start..<index])
    }

    private mutating func parseAttributeValue() -> String? {
        guard index < source.endIndex else { return nil }
        if source[index] == "\"" || source[index] == "'" {
            let quote = source[index]
            index = source.index(after: index)
            let start = index
            guard let closing = source[index...].firstIndex(of: quote) else { return nil }
            let value = String(source[start..<closing])
            index = source.index(after: closing)
            return value
        }

        let start = index
        while index < source.endIndex,
              !source[index].isWhitespace,
              !"\"'=<>`".contains(source[index]) {
            index = source.index(after: index)
        }
        guard start != index else { return nil }
        return String(source[start..<index])
    }
}

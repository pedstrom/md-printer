import Foundation

public struct InlineParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> [InlineNode] {
        var nodes: [InlineNode] = []
        var text = ""
        var index = source.startIndex

        func flushText() {
            guard !text.isEmpty else { return }
            nodes.append(.text(text))
            text = ""
        }

        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex {
                    text.append(source[next])
                    index = source.index(after: next)
                    continue
                }
            }

            if source[index] == "\n" {
                flushText()
                nodes.append(.lineBreak)
                index = source.index(after: index)
                continue
            }

            if let parsed = parseImage(in: source, at: index) {
                flushText()
                nodes.append(.image(alt: parsed.label, source: parsed.destination))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseLink(in: source, at: index) {
                flushText()
                nodes.append(.link(children: parse(parsed.label), destination: parsed.destination))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("***", in: source, at: index) {
                flushText()
                nodes.append(.strong([.emphasis(parse(parsed.content))]))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("___", in: source, at: index) {
                flushText()
                nodes.append(.strong([.emphasis(parse(parsed.content))]))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("**", in: source, at: index) {
                flushText()
                nodes.append(.strong(parse(parsed.content)))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("__", in: source, at: index) {
                flushText()
                nodes.append(.strong(parse(parsed.content)))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("~~", in: source, at: index) {
                flushText()
                nodes.append(.strikethrough(parse(parsed.content)))
                index = parsed.endIndex
                continue
            }

            if source[index...].hasPrefix("<u>"),
               let closing = source.range(of: "</u>", range: source.index(index, offsetBy: 3)..<source.endIndex) {
                flushText()
                let contentStart = source.index(index, offsetBy: 3)
                nodes.append(.underline(parse(String(source[contentStart..<closing.lowerBound]))))
                index = closing.upperBound
                continue
            }

            if source[index...].hasPrefix("<br>" ) {
                flushText()
                nodes.append(.lineBreak)
                index = source.index(index, offsetBy: 4)
                continue
            }

            if source[index...].hasPrefix("<br/>" ) {
                flushText()
                nodes.append(.lineBreak)
                index = source.index(index, offsetBy: 5)
                continue
            }

            if source[index] == "`", let closing = source[source.index(after: index)...].firstIndex(of: "`") {
                flushText()
                let start = source.index(after: index)
                nodes.append(.code(String(source[start..<closing])))
                index = source.index(after: closing)
                continue
            }

            if let parsed = parseDelimited("*", in: source, at: index), !parsed.content.isEmpty {
                flushText()
                nodes.append(.emphasis(parse(parsed.content)))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("_", in: source, at: index), !parsed.content.isEmpty {
                flushText()
                nodes.append(.emphasis(parse(parsed.content)))
                index = parsed.endIndex
                continue
            }

            text.append(source[index])
            index = source.index(after: index)
        }

        flushText()
        return nodes
    }

    private func parseDelimited(
        _ delimiter: String,
        in source: String,
        at index: String.Index
    ) -> (content: String, endIndex: String.Index)? {
        guard source[index...].hasPrefix(delimiter) else { return nil }
        let contentStart = source.index(index, offsetBy: delimiter.count)
        guard contentStart < source.endIndex,
              let closing = source.range(of: delimiter, range: contentStart..<source.endIndex),
              closing.lowerBound > contentStart else {
            return nil
        }
        return (String(source[contentStart..<closing.lowerBound]), closing.upperBound)
    }

    private func parseImage(
        in source: String,
        at index: String.Index
    ) -> (label: String, destination: String, endIndex: String.Index)? {
        guard source[index...].hasPrefix("![") else { return nil }
        return parseLabelAndDestination(in: source, at: source.index(after: index))
    }

    private func parseLink(
        in source: String,
        at index: String.Index
    ) -> (label: String, destination: String, endIndex: String.Index)? {
        guard source[index] == "[" else { return nil }
        return parseLabelAndDestination(in: source, at: index)
    }

    private func parseLabelAndDestination(
        in source: String,
        at bracketIndex: String.Index
    ) -> (label: String, destination: String, endIndex: String.Index)? {
        guard source[bracketIndex] == "[",
              let labelEnd = source[bracketIndex...].firstIndex(of: "]") else { return nil }
        let openParenthesis = source.index(after: labelEnd)
        guard openParenthesis < source.endIndex,
              source[openParenthesis] == "(",
              let destinationEnd = source[openParenthesis...].firstIndex(of: ")") else { return nil }

        let labelStart = source.index(after: bracketIndex)
        let destinationStart = source.index(after: openParenthesis)
        let rawDestination = String(source[destinationStart..<destinationEnd])
        return (
            String(source[labelStart..<labelEnd]),
            cleanDestination(rawDestination),
            source.index(after: destinationEnd)
        )
    }

    private func cleanDestination(_ raw: String) -> String {
        var destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if destination.hasPrefix("<"), destination.hasSuffix(">") {
            destination.removeFirst()
            destination.removeLast()
        }
        if let quote = destination.range(of: " \"") {
            destination = String(destination[..<quote.lowerBound])
        }
        return destination
    }
}

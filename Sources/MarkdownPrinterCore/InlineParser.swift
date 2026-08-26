import Foundation

struct LinkReferenceDefinition: Equatable, Sendable {
    let destination: String
    let title: String?
}

public struct InlineParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> [InlineNode] {
        parse(source, references: [:])
    }

    func parse(
        _ source: String,
        references: [String: LinkReferenceDefinition]
    ) -> [InlineNode] {
        var nodes: [InlineNode] = []
        var text = ""
        var index = source.startIndex

        func flushText() {
            guard !text.isEmpty else { return }
            nodes.append(.text(CommonMarkEntityDecoder.decode(text)))
            text = ""
        }

        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex, Self.isEscapable(source[next]) {
                    flushText()
                    nodes.append(.text(String(source[next])))
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

            if let parsed = parseFootnoteReference(in: source, at: index) {
                flushText()
                nodes.append(.footnoteReference(label: parsed.label))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseLinkOrImage(
                in: source,
                at: index,
                references: references
            ) {
                flushText()
                if parsed.isImage {
                    nodes.append(.image(
                        alt: plainText(parse(parsed.label, references: references)),
                        source: parsed.destination,
                        title: parsed.title
                    ))
                } else {
                    nodes.append(.link(
                        children: parse(parsed.label, references: references),
                        destination: parsed.destination,
                        title: parsed.title
                    ))
                }
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("***", in: source, at: index) {
                flushText()
                nodes.append(.strong([.emphasis(parse(parsed.content, references: references))]))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("___", in: source, at: index) {
                flushText()
                nodes.append(.strong([.emphasis(parse(parsed.content, references: references))]))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("**", in: source, at: index) {
                flushText()
                nodes.append(.strong(parse(parsed.content, references: references)))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("__", in: source, at: index) {
                flushText()
                nodes.append(.strong(parse(parsed.content, references: references)))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("~~", in: source, at: index) {
                flushText()
                nodes.append(.strikethrough(parse(parsed.content, references: references)))
                index = parsed.endIndex
                continue
            }

            if source[index...].hasPrefix("<u>"),
               let closing = source.range(
                   of: "</u>",
                   range: source.index(index, offsetBy: 3)..<source.endIndex
               ) {
                flushText()
                let contentStart = source.index(index, offsetBy: 3)
                nodes.append(.underline(parse(
                    String(source[contentStart..<closing.lowerBound]),
                    references: references
                )))
                index = closing.upperBound
                continue
            }

            if source[index...].hasPrefix("<br>") {
                flushText()
                nodes.append(.lineBreak)
                index = source.index(index, offsetBy: 4)
                continue
            }

            if source[index...].hasPrefix("<br/>") {
                flushText()
                nodes.append(.lineBreak)
                index = source.index(index, offsetBy: 5)
                continue
            }

            if source[index...].hasPrefix("<br />") {
                flushText()
                nodes.append(.lineBreak)
                index = source.index(index, offsetBy: 6)
                continue
            }

            if source[index] == "`", let parsed = parseCodeSpan(in: source, at: index) {
                flushText()
                nodes.append(.code(parsed.content))
                index = parsed.endIndex
                continue
            }

            if source[index] == "<", let parsed = parseAutolink(in: source, at: index) {
                flushText()
                nodes.append(.link(
                    children: [.text(parsed.label)],
                    destination: parsed.destination,
                    title: nil
                ))
                index = parsed.endIndex
                continue
            }

            if source[index] == "<", let parsed = parseRawHTML(in: source, at: index) {
                flushText()
                nodes.append(.rawHTML(parsed.source))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("*", in: source, at: index), !parsed.content.isEmpty {
                flushText()
                nodes.append(.emphasis(parse(parsed.content, references: references)))
                index = parsed.endIndex
                continue
            }

            if let parsed = parseDelimited("_", in: source, at: index), !parsed.content.isEmpty {
                flushText()
                nodes.append(.emphasis(parse(parsed.content, references: references)))
                index = parsed.endIndex
                continue
            }

            text.append(source[index])
            index = source.index(after: index)
        }

        flushText()
        return coalescingText(nodes)
    }

    static func normalizedReferenceLabel(_ source: String) -> String? {
        let unescaped = unescape(CommonMarkEntityDecoder.decode(source))
        let words = unescaped.split(whereSeparator: { $0.isWhitespace })
        let normalized = words.joined(separator: " ").folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        guard !normalized.isEmpty, normalized.count <= 999 else { return nil }
        return normalized
    }

    static func unescape(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex, isEscapable(source[next]) {
                    result.append(source[next])
                    index = source.index(after: next)
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
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

    private func parseCodeSpan(
        in source: String,
        at index: String.Index
    ) -> (content: String, endIndex: String.Index)? {
        let markerLength = source[index...].prefix(while: { $0 == "`" }).count
        let marker = String(repeating: "`", count: markerLength)
        let contentStart = source.index(index, offsetBy: markerLength)
        guard let closing = source.range(of: marker, range: contentStart..<source.endIndex) else {
            return nil
        }
        var content = String(source[contentStart..<closing.lowerBound])
            .replacingOccurrences(of: "\n", with: " ")
        if content.count >= 2,
           content.first == " ", content.last == " ",
           content.contains(where: { !$0.isWhitespace }) {
            content.removeFirst()
            content.removeLast()
        }
        return (content, closing.upperBound)
    }

    private func parseFootnoteReference(
        in source: String,
        at index: String.Index
    ) -> (label: String, endIndex: String.Index)? {
        guard source[index...].hasPrefix("[^") else { return nil }
        let labelStart = source.index(index, offsetBy: 2)
        guard labelStart < source.endIndex,
              let labelEnd = closingBracket(in: source, after: labelStart) else { return nil }
        let label = source[labelStart..<labelEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return (label, source.index(after: labelEnd))
    }

    private func parseLinkOrImage(
        in source: String,
        at index: String.Index,
        references: [String: LinkReferenceDefinition]
    ) -> (
        isImage: Bool,
        label: String,
        destination: String,
        title: String?,
        endIndex: String.Index
    )? {
        let isImage = source[index...].hasPrefix("![")
        let bracketIndex: String.Index
        if isImage {
            bracketIndex = source.index(after: index)
        } else {
            guard source[index] == "[" else { return nil }
            bracketIndex = index
        }

        let labelStart = source.index(after: bracketIndex)
        guard let labelEnd = closingBracket(in: source, after: labelStart) else { return nil }
        let label = String(source[labelStart..<labelEnd])
        let suffix = source.index(after: labelEnd)

        if suffix < source.endIndex, source[suffix] == "(",
           let inline = parseInlineDestination(in: source, at: suffix) {
            return (
                isImage,
                label,
                cleanDestination(inline.destination),
                inline.title.map(cleanTitle),
                inline.endIndex
            )
        }

        var referenceLabel = label
        var endIndex = suffix
        if suffix < source.endIndex, source[suffix] == "[" {
            let referenceStart = source.index(after: suffix)
            guard let referenceEnd = closingBracket(in: source, after: referenceStart) else {
                return nil
            }
            referenceLabel = String(source[referenceStart..<referenceEnd])
            if referenceLabel.isEmpty { referenceLabel = label }
            endIndex = source.index(after: referenceEnd)
        }

        guard let normalized = Self.normalizedReferenceLabel(referenceLabel),
              let definition = references[normalized] else { return nil }
        return (isImage, label, definition.destination, definition.title, endIndex)
    }

    private func closingBracket(
        in source: String,
        after start: String.Index
    ) -> String.Index? {
        var index = start
        var depth = 0
        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                index = next < source.endIndex ? source.index(after: next) : next
                continue
            }
            if source[index] == "[" { depth += 1 }
            if source[index] == "]" {
                if depth == 0 { return index }
                depth -= 1
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func parseInlineDestination(
        in source: String,
        at openParenthesis: String.Index
    ) -> (destination: String, title: String?, endIndex: String.Index)? {
        var index = source.index(after: openParenthesis)
        skipWhitespace(in: source, index: &index)

        let destination: String
        if index < source.endIndex, source[index] == "<" {
            let start = source.index(after: index)
            var cursor = start
            while cursor < source.endIndex, source[cursor] != ">" {
                if source[cursor] == "\n" || source[cursor] == "<" { return nil }
                if source[cursor] == "\\" {
                    let next = source.index(after: cursor)
                    cursor = next < source.endIndex ? source.index(after: next) : next
                } else {
                    cursor = source.index(after: cursor)
                }
            }
            guard cursor < source.endIndex else { return nil }
            destination = String(source[start..<cursor])
            index = source.index(after: cursor)
        } else {
            let start = index
            var depth = 0
            while index < source.endIndex {
                let character = source[index]
                if character == "\\" {
                    let next = source.index(after: index)
                    index = next < source.endIndex ? source.index(after: next) : next
                    continue
                }
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                } else if character.isWhitespace {
                    break
                }
                index = source.index(after: index)
            }
            guard depth == 0 else { return nil }
            destination = String(source[start..<index])
        }

        let beforeWhitespace = index
        skipWhitespace(in: source, index: &index)
        var title: String?
        if index < source.endIndex, "\"'( ".contains(source[index]), source[index] != " " {
            let opener = source[index]
            let closer: Character = opener == "(" ? ")" : opener
            let titleStart = source.index(after: index)
            var cursor = titleStart
            while cursor < source.endIndex, source[cursor] != closer {
                if source[cursor] == "\\" {
                    let next = source.index(after: cursor)
                    cursor = next < source.endIndex ? source.index(after: next) : next
                } else {
                    cursor = source.index(after: cursor)
                }
            }
            guard cursor < source.endIndex else { return nil }
            title = String(source[titleStart..<cursor])
            index = source.index(after: cursor)
            skipWhitespace(in: source, index: &index)
        } else if beforeWhitespace != index, index < source.endIndex, source[index] != ")" {
            return nil
        }

        guard index < source.endIndex, source[index] == ")" else { return nil }
        return (destination, title, source.index(after: index))
    }

    private func parseAutolink(
        in source: String,
        at index: String.Index
    ) -> (label: String, destination: String, endIndex: String.Index)? {
        let contentStart = source.index(after: index)
        guard let closing = source[contentStart...].firstIndex(of: ">") else { return nil }
        let content = String(source[contentStart..<closing])
        guard !content.isEmpty,
              !content.contains(where: {
                  $0 == "<" || $0.isWhitespace || $0.asciiValue.map { $0 < 32 } == true
              }) else {
            return nil
        }

        if let colon = content.firstIndex(of: ":") {
            let scheme = content[..<colon]
            if (2...32).contains(scheme.count),
               scheme.first?.isLetter == true,
               scheme.dropFirst().allSatisfy({
                   $0.isLetter || $0.isNumber || "+.-".contains($0)
               }) {
                return (content, content, source.index(after: closing))
            }
        }

        guard isEmailAutolink(content) else { return nil }
        return (content, "mailto:\(content)", source.index(after: closing))
    }

    private func isEmailAutolink(_ source: String) -> Bool {
        let pattern = #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    private func parseRawHTML(
        in source: String,
        at index: String.Index
    ) -> (source: String, endIndex: String.Index)? {
        guard source[index] == "<" else { return nil }

        if source[index...].hasPrefix("<!--") {
            let bodyStart = source.index(index, offsetBy: 4)
            if source[bodyStart...].hasPrefix(">") {
                let end = source.index(after: bodyStart)
                return (String(source[index..<end]), end)
            }
            if source[bodyStart...].hasPrefix("->") {
                let end = source.index(bodyStart, offsetBy: 2)
                return (String(source[index..<end]), end)
            }
            guard bodyStart < source.endIndex,
                  let closing = source.range(of: "-->", range: bodyStart..<source.endIndex) else {
                return nil
            }
            return (String(source[index..<closing.upperBound]), closing.upperBound)
        }
        if source[index...].hasPrefix("<?"),
           let closing = source.range(
               of: "?>",
               range: source.index(index, offsetBy: 2)..<source.endIndex
           ) {
            return (String(source[index..<closing.upperBound]), closing.upperBound)
        }
        if source[index...].hasPrefix("<![CDATA["),
           let closing = source.range(
               of: "]]>",
               range: source.index(index, offsetBy: 9)..<source.endIndex
           ) {
            return (String(source[index..<closing.upperBound]), closing.upperBound)
        }
        if source[index...].hasPrefix("<!") {
            let nameStart = source.index(index, offsetBy: 2)
            guard nameStart < source.endIndex, source[nameStart].isUppercase,
                  let closing = source[nameStart...].firstIndex(of: ">") else { return nil }
            let name = source[nameStart..<closing].prefix(while: { $0.isUppercase })
            guard !name.isEmpty else { return nil }
            let afterName = source.index(nameStart, offsetBy: name.count)
            guard afterName == closing || source[afterName].isWhitespace else { return nil }
            return (String(source[index...closing]), source.index(after: closing))
        }

        return parseRawTag(in: source, at: index)
    }

    private func parseRawTag(
        in source: String,
        at start: String.Index
    ) -> (source: String, endIndex: String.Index)? {
        var index = source.index(after: start)
        var closingTag = false
        if index < source.endIndex, source[index] == "/" {
            closingTag = true
            index = source.index(after: index)
        }
        guard index < source.endIndex, source[index].isLetter else { return nil }
        index = source.index(after: index)
        while index < source.endIndex,
              source[index].isLetter || source[index].isNumber || source[index] == "-" {
            index = source.index(after: index)
        }

        if closingTag {
            skipWhitespace(in: source, index: &index)
            guard index < source.endIndex, source[index] == ">" else { return nil }
            let end = source.index(after: index)
            return (String(source[start..<end]), end)
        }

        while index < source.endIndex {
            let whitespaceStart = index
            skipWhitespace(in: source, index: &index)
            if index < source.endIndex, source[index] == ">" {
                let end = source.index(after: index)
                return (String(source[start..<end]), end)
            }
            if index < source.endIndex, source[index] == "/" {
                let close = source.index(after: index)
                guard close < source.endIndex, source[close] == ">" else { return nil }
                let end = source.index(after: close)
                return (String(source[start..<end]), end)
            }
            guard whitespaceStart != index,
                  index < source.endIndex,
                  isAttributeNameStart(source[index]) else { return nil }

            index = source.index(after: index)
            while index < source.endIndex, isAttributeNameContinuation(source[index]) {
                index = source.index(after: index)
            }
            let afterName = index
            var equalsIndex = index
            skipWhitespace(in: source, index: &equalsIndex)
            guard equalsIndex < source.endIndex, source[equalsIndex] == "=" else {
                index = afterName
                continue
            }
            index = equalsIndex
            index = source.index(after: index)
            skipWhitespace(in: source, index: &index)
            guard index < source.endIndex else { return nil }

            if source[index] == "\"" || source[index] == "'" {
                let quote = source[index]
                index = source.index(after: index)
                guard let closing = source[index...].firstIndex(of: quote) else { return nil }
                index = source.index(after: closing)
            } else {
                let valueStart = index
                while index < source.endIndex,
                      !source[index].isWhitespace,
                      !"\"'=<>`".contains(source[index]) {
                    index = source.index(after: index)
                }
                guard valueStart != index else { return nil }
            }
        }
        return nil
    }

    private func cleanDestination(_ source: String) -> String {
        CommonMarkEntityDecoder.decode(Self.unescape(source))
    }

    private func cleanTitle(_ source: String) -> String {
        CommonMarkEntityDecoder.decode(Self.unescape(source))
    }

    private func plainText(_ nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case let .text(value), let .code(value), let .rawHTML(value): return value
            case let .emphasis(children), let .strong(children), let .underline(children),
                 let .strikethrough(children): return plainText(children)
            case let .link(children, _, _): return plainText(children)
            case let .footnoteReference(label): return "[^\(label)]"
            case let .image(alt, _, _): return alt
            case .lineBreak: return "\n"
            }
        }.joined()
    }

    private func coalescingText(_ nodes: [InlineNode]) -> [InlineNode] {
        var result: [InlineNode] = []
        for node in nodes {
            if case let .text(value) = node,
               case let .text(previous)? = result.last {
                result[result.count - 1] = .text(previous + value)
            } else {
                result.append(node)
            }
        }
        return result
    }

    private func skipWhitespace(in source: String, index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
    }

    private func isAttributeNameStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == ":"
    }

    private func isAttributeNameContinuation(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "_.:-".contains(character)
    }

    fileprivate static func isEscapable(_ character: Character) -> Bool {
        character.isASCII && "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(character)
    }
}

private func isEscapable(_ character: Character) -> Bool {
    InlineParser.isEscapable(character)
}

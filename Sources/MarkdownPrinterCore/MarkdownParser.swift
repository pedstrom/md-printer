import Foundation

public struct MarkdownParser: Sendable {
    private let inlineParser: InlineParser

    public init(inlineParser: InlineParser = InlineParser()) {
        self.inlineParser = inlineParser
    }

    public func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map(expandTabs)
        let references = ReferenceStore()
        var blockParser = BlockParser(lines: lines, references: references)
        let rawBlocks = blockParser.parse()
        return rawBlocks.map { materialize($0, references: references.definitions) }
    }

    private func materialize(
        _ block: RawBlock,
        references: [String: LinkReferenceDefinition]
    ) -> MarkdownBlock {
        switch block {
        case let .heading(level, source):
            return .heading(level: level, content: inlineParser.parse(source, references: references))
        case let .paragraph(source):
            return .paragraph(inlineParser.parse(source, references: references))
        case let .blockquote(children):
            return .blockquote(children.map { materialize($0, references: references) })
        case let .list(items, ordered, start):
            return .list(
                items: items.map { item in
                    MarkdownListItem(
                        blocks: item.blocks.map { materialize($0, references: references) },
                        checked: item.checked
                    )
                },
                ordered: ordered,
                start: start
            )
        case let .codeBlock(language, code):
            return .codeBlock(language: language, code: code)
        case let .rawHTML(source):
            return .rawHTML(source)
        case .thematicBreak:
            return .thematicBreak
        case let .footnoteDefinition(label, source):
            return .footnoteDefinition(
                label: label,
                content: inlineParser.parse(source, references: references)
            )
        case let .table(headers, alignments, rows):
            return .table(
                headers: headers.map { inlineParser.parse($0, references: references) },
                alignments: alignments,
                rows: rows.map { row in
                    row.map { inlineParser.parse($0, references: references) }
                }
            )
        }
    }
}

private final class ReferenceStore {
    var definitions: [String: LinkReferenceDefinition] = [:]
}

private indirect enum RawBlock {
    case heading(level: Int, source: String)
    case paragraph(String)
    case blockquote([RawBlock])
    case list(items: [RawListItem], ordered: Bool, start: Int)
    case codeBlock(language: String?, code: String)
    case rawHTML(String)
    case thematicBreak
    case footnoteDefinition(label: String, source: String)
    case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
}

private struct RawListItem {
    let blocks: [RawBlock]
    let checked: Bool?
}

private struct Fence {
    let marker: Character
    let length: Int
    let indentation: Int
    let info: String
}

private struct ListMarker {
    let ordered: Bool
    let number: Int?
    let marker: Character
    let contentIndent: Int
    let content: String
}

private enum HTMLBlockKind {
    case rawTag(name: String)
    case comment
    case processingInstruction
    case declaration
    case cdata
    case blockTag
    case completeTag
}

private struct BlockParser {
    let lines: [String]
    let references: ReferenceStore
    private var index = 0

    init(lines: [String], references: ReferenceStore) {
        self.lines = lines
        self.references = references
    }

    mutating func parse() -> [RawBlock] {
        var blocks: [RawBlock] = []

        while index < lines.count {
            if isBlank(lines[index]) {
                index += 1
                continue
            }

            if let fence = fence(in: lines[index]) {
                blocks.append(parseFencedCode(fence))
                continue
            }

            if let footnote = footnoteDefinition(in: lines[index]) {
                blocks.append(parseFootnoteDefinition(footnote))
                continue
            }

            if let definition = parseReferenceDefinition(at: index) {
                if references.definitions[definition.label] == nil {
                    references.definitions[definition.label] = definition.definition
                }
                index += definition.lineCount
                continue
            }

            if let heading = atxHeading(in: lines[index]) {
                blocks.append(.heading(level: heading.level, source: heading.source))
                index += 1
                continue
            }

            if isThematicBreak(lines[index]) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if let quoteLine = blockquoteContent(in: lines[index]) {
                blocks.append(parseBlockquote(firstLine: quoteLine))
                continue
            }

            if let marker = listMarker(in: lines[index], mayInterruptParagraph: false) {
                blocks.append(parseList(firstMarker: marker))
                continue
            }

            if indentation(of: lines[index]) >= 4 {
                blocks.append(parseIndentedCode())
                continue
            }

            if let html = htmlBlockKind(in: lines[index], mayInterruptParagraph: false) {
                blocks.append(parseHTMLBlock(html))
                continue
            }

            if index + 1 < lines.count,
               setextLevel(in: lines[index + 1]) == nil,
               isTableDelimiter(lines[index + 1]),
               lines[index].contains("|") {
                blocks.append(parseTable())
                continue
            }

            blocks.append(parseParagraphOrSetext())
        }

        return blocks
    }

    private mutating func parseFencedCode(_ opening: Fence) -> RawBlock {
        var codeLines: [String] = []
        index += 1
        while index < lines.count {
            if isClosingFence(lines[index], opening: opening) {
                index += 1
                break
            }
            codeLines.append(removeIndent(lines[index], columns: opening.indentation))
            index += 1
        }
        let language = opening.info.isEmpty
            ? nil
            : CommonMarkEntityDecoder.decode(InlineParser.unescape(opening.info))
        return .codeBlock(language: language, code: codeLines.joined(separator: "\n"))
    }

    private mutating func parseFootnoteDefinition(
        _ opening: (label: String, source: String)
    ) -> RawBlock {
        var contentLines = [opening.source]
        index += 1
        while index < lines.count {
            if indentation(of: lines[index]) >= 4 {
                contentLines.append(removeIndent(lines[index], columns: 4))
                index += 1
                continue
            }
            if isBlank(lines[index]),
               index + 1 < lines.count,
               indentation(of: lines[index + 1]) >= 4 {
                contentLines.append("")
                index += 1
                continue
            }
            break
        }
        return .footnoteDefinition(label: opening.label, source: contentLines.joined(separator: "\n"))
    }

    private mutating func parseBlockquote(firstLine: String) -> RawBlock {
        var quoteLines = [firstLine]
        var includesLazyContinuation = false
        index += 1
        while index < lines.count {
            if let content = blockquoteContent(in: lines[index]) {
                quoteLines.append(content)
                index += 1
            } else if !isBlank(lines[index]),
                      !startsBlock(lines[index], mayInterruptParagraph: true) {
                quoteLines.append(removeIndent(
                    lines[index],
                    columns: min(indentation(of: lines[index]), 4)
                ))
                includesLazyContinuation = true
                index += 1
            } else {
                break
            }
        }
        if includesLazyContinuation, !quoteLines.contains(where: isBlank) {
            return .blockquote([.paragraph(quoteLines.joined(separator: "\n"))])
        }
        var childParser = BlockParser(lines: quoteLines, references: references)
        return .blockquote(childParser.parse())
    }

    private mutating func parseList(firstMarker: ListMarker) -> RawBlock {
        var items: [RawListItem] = []
        let ordered = firstMarker.ordered
        let start = firstMarker.number ?? 1
        var marker: ListMarker? = firstMarker

        while let current = marker,
              current.ordered == ordered,
              (!ordered || current.marker == firstMarker.marker) {
            var itemLines = [current.content]
            var blankLineSeen = false
            index += 1

            while index < lines.count {
                if let next = listMarker(in: lines[index], mayInterruptParagraph: false),
                   next.ordered == ordered,
                   (!ordered || next.marker == firstMarker.marker) {
                    break
                }

                if isBlank(lines[index]) {
                    itemLines.append("")
                    blankLineSeen = true
                    index += 1
                    continue
                }

                let lineIndent = indentation(of: lines[index])
                if lineIndent >= current.contentIndent {
                    itemLines.append(removeIndent(lines[index], columns: current.contentIndent))
                    blankLineSeen = false
                    index += 1
                    continue
                }

                if blankLineSeen { break }
                if startsBlock(lines[index], mayInterruptParagraph: true) { break }
                itemLines.append(removeIndent(lines[index], columns: min(lineIndent, 3)))
                index += 1
            }

            while itemLines.last.map(isBlank) == true { itemLines.removeLast() }
            let task = taskListItem(from: itemLines)
            var childParser = BlockParser(lines: task.lines, references: references)
            items.append(RawListItem(blocks: childParser.parse(), checked: task.checked))

            marker = index < lines.count
                ? listMarker(in: lines[index], mayInterruptParagraph: false)
                : nil
        }

        return .list(items: items, ordered: ordered, start: start)
    }

    private mutating func parseIndentedCode() -> RawBlock {
        var codeLines: [String] = []

        while index < lines.count {
            if indentation(of: lines[index]) >= 4 {
                codeLines.append(removeIndent(lines[index], columns: 4))
                index += 1
                continue
            }
            if isBlank(lines[index]) {
                var lookahead = index
                while lookahead < lines.count, isBlank(lines[lookahead]) { lookahead += 1 }
                guard lookahead < lines.count, indentation(of: lines[lookahead]) >= 4 else { break }
                while index < lookahead {
                    codeLines.append("")
                    index += 1
                }
                continue
            }
            break
        }

        while codeLines.last.map(isBlank) == true { codeLines.removeLast() }
        return .codeBlock(language: nil, code: codeLines.joined(separator: "\n"))
    }

    private mutating func parseHTMLBlock(_ kind: HTMLBlockKind) -> RawBlock {
        var htmlLines: [String] = []
        let blankTerminated: Bool
        switch kind {
        case .blockTag, .completeTag: blankTerminated = true
        default: blankTerminated = false
        }

        while index < lines.count {
            if blankTerminated, isBlank(lines[index]) { break }
            let line = lines[index]
            htmlLines.append(line)
            index += 1
            if !blankTerminated, htmlBlockEnds(kind, line: line) { break }
        }
        let source = htmlLines.joined(separator: "\n")
        return .rawHTML(source.hasSuffix("\n") ? source : source + "\n")
    }

    private mutating func parseTable() -> RawBlock {
        let headers = tableCells(in: lines[index])
        let alignments = tableAlignments(in: lines[index + 1])
        var rows: [[String]] = []
        index += 2
        while index < lines.count,
              !isBlank(lines[index]),
              lines[index].contains("|") {
            rows.append(tableCells(in: lines[index]))
            index += 1
        }
        return .table(headers: headers, alignments: alignments, rows: rows)
    }

    private mutating func parseParagraphOrSetext() -> RawBlock {
        var paragraphLines: [String] = []

        while index < lines.count, !isBlank(lines[index]) {
            if !paragraphLines.isEmpty, let level = setextLevel(in: lines[index]) {
                index += 1
                let source = paragraphLines.map {
                    $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
                }.joined(separator: "\n")
                return .heading(level: level, source: source)
            }
            if !paragraphLines.isEmpty, startsBlock(lines[index], mayInterruptParagraph: true) {
                break
            }
            let removableIndent = paragraphLines.isEmpty
                ? min(indentation(of: lines[index]), 3)
                : min(indentation(of: lines[index]), 4)
            paragraphLines.append(removeIndent(lines[index], columns: removableIndent))
            index += 1
        }

        return .paragraph(paragraphLines.joined(separator: "\n"))
    }

    private func startsBlock(_ line: String, mayInterruptParagraph: Bool) -> Bool {
        fence(in: line) != nil
            || atxHeading(in: line) != nil
            || isThematicBreak(line)
            || blockquoteContent(in: line) != nil
            || listMarker(in: line, mayInterruptParagraph: mayInterruptParagraph) != nil
            || footnoteDefinition(in: line) != nil
            || htmlBlockKind(in: line, mayInterruptParagraph: mayInterruptParagraph) != nil
    }

    private func parseReferenceDefinition(
        at start: Int
    ) -> (label: String, definition: LinkReferenceDefinition, lineCount: Int)? {
        guard indentation(of: lines[start]) <= 3,
              removeIndent(lines[start], columns: min(indentation(of: lines[start]), 3)).hasPrefix("[") else {
            return nil
        }

        var end = start
        while end < lines.count, !isBlank(lines[end]), end - start < 32 { end += 1 }
        guard end > start else { return nil }

        for lineCount in stride(from: end - start, through: 1, by: -1) {
            let candidateLines = Array(lines[start..<(start + lineCount)])
            guard let parsed = ReferenceDefinitionParser.parse(candidateLines) else { continue }
            return (parsed.label, parsed.definition, lineCount)
        }
        return nil
    }
}

private enum ReferenceDefinitionParser {
    static func parse(
        _ lines: [String]
    ) -> (label: String, definition: LinkReferenceDefinition)? {
        guard !lines.isEmpty else { return nil }
        let source = lines.joined(separator: "\n")
        var index = source.startIndex
        var leadingSpaces = 0
        while index < source.endIndex, source[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = source.index(after: index)
        }
        guard leadingSpaces <= 3, index < source.endIndex, source[index] == "[" else { return nil }

        let labelStart = source.index(after: index)
        index = labelStart
        var labelEnd: String.Index?
        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                index = next < source.endIndex ? source.index(after: next) : next
                continue
            }
            if source[index] == "[" { return nil }
            if source[index] == "]" {
                labelEnd = index
                break
            }
            index = source.index(after: index)
        }
        guard let labelEnd,
              let normalizedLabel = InlineParser.normalizedReferenceLabel(String(source[labelStart..<labelEnd])) else {
            return nil
        }

        index = source.index(after: labelEnd)
        guard index < source.endIndex, source[index] == ":" else { return nil }
        index = source.index(after: index)
        skipWhitespace(in: source, index: &index)
        guard index < source.endIndex else { return nil }

        let destination: String
        if source[index] == "<" {
            let start = source.index(after: index)
            index = start
            while index < source.endIndex, source[index] != ">" {
                if source[index] == "\n" || source[index] == "<" { return nil }
                if source[index] == "\\" {
                    let next = source.index(after: index)
                    index = next < source.endIndex ? source.index(after: next) : next
                } else {
                    index = source.index(after: index)
                }
            }
            guard index < source.endIndex else { return nil }
            destination = String(source[start..<index])
            index = source.index(after: index)
        } else {
            let start = index
            var depth = 0
            while index < source.endIndex, !source[index].isWhitespace {
                if source[index] == "\\" {
                    let next = source.index(after: index)
                    index = next < source.endIndex ? source.index(after: next) : next
                    continue
                }
                if source[index] == "(" {
                    depth += 1
                    guard depth <= 32 else { return nil }
                } else if source[index] == ")" {
                    guard depth > 0 else { break }
                    depth -= 1
                }
                index = source.index(after: index)
            }
            guard start != index, depth == 0 else { return nil }
            destination = String(source[start..<index])
        }

        let whitespaceStart = index
        skipWhitespace(in: source, index: &index)
        var title: String?
        if index < source.endIndex {
            guard whitespaceStart != index, "\"'( ".contains(source[index]), source[index] != " " else {
                return nil
            }
            let opener = source[index]
            let closer: Character = opener == "(" ? ")" : opener
            let titleStart = source.index(after: index)
            index = titleStart
            while index < source.endIndex, source[index] != closer {
                if source[index] == "\\" {
                    let next = source.index(after: index)
                    index = next < source.endIndex ? source.index(after: next) : next
                } else {
                    index = source.index(after: index)
                }
            }
            guard index < source.endIndex else { return nil }
            title = String(source[titleStart..<index])
            index = source.index(after: index)
            skipWhitespace(in: source, index: &index)
        }

        guard index == source.endIndex else { return nil }
        return (
            normalizedLabel,
            LinkReferenceDefinition(
                destination: CommonMarkEntityDecoder.decode(InlineParser.unescape(destination)),
                title: title.map { CommonMarkEntityDecoder.decode(InlineParser.unescape($0)) }
            )
        )
    }
}

private func expandTabs(_ line: String) -> String {
    var result = ""
    var column = 0
    for character in line {
        if character == "\t" {
            let spaces = 4 - (column % 4)
            result += String(repeating: " ", count: spaces)
            column += spaces
        } else {
            result.append(character)
            column += 1
        }
    }
    return result
}

private func indentation(of line: String) -> Int {
    line.prefix(while: { $0 == " " }).count
}

private func removeIndent(_ line: String, columns: Int) -> String {
    String(line.dropFirst(min(columns, indentation(of: line))))
}

private func isBlank(_ line: String) -> Bool {
    line.allSatisfy { $0 == " " || $0 == "\t" }
}

private func skipWhitespace(in source: String, index: inout String.Index) {
    while index < source.endIndex, source[index].isWhitespace {
        index = source.index(after: index)
    }
}

private func fence(in line: String) -> Fence? {
    let indent = indentation(of: line)
    guard indent <= 3 else { return nil }
    let content = removeIndent(line, columns: indent)
    guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
    let length = content.prefix(while: { $0 == marker }).count
    guard length >= 3 else { return nil }
    let remainder = String(content.dropFirst(length))
    if marker == "`", remainder.contains("`") { return nil }
    return Fence(
        marker: marker,
        length: length,
        indentation: indent,
        info: remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    )
}

private func isClosingFence(_ line: String, opening: Fence) -> Bool {
    let indent = indentation(of: line)
    guard indent <= 3 else { return false }
    let content = removeIndent(line, columns: indent)
    let length = content.prefix(while: { $0 == opening.marker }).count
    guard length >= opening.length else { return false }
    return content.dropFirst(length).allSatisfy { $0.isWhitespace }
}

private func atxHeading(in line: String) -> (level: Int, source: String)? {
    let indent = indentation(of: line)
    guard indent <= 3 else { return nil }
    let content = removeIndent(line, columns: indent)
    let level = content.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level) else { return nil }
    let markerEnd = content.index(content.startIndex, offsetBy: level)
    guard markerEnd == content.endIndex || content[markerEnd].isWhitespace else { return nil }
    var source = String(content[markerEnd...]).trimmingCharacters(in: .whitespaces)
    if let range = source.range(of: #"[ \t]+#+[ \t]*$"#, options: .regularExpression) {
        source.removeSubrange(range)
    }
    return (level, source)
}

private func setextLevel(in line: String) -> Int? {
    let indent = indentation(of: line)
    guard indent <= 3 else { return nil }
    let content = removeIndent(line, columns: indent).trimmingCharacters(in: .whitespaces)
    guard let first = content.first, first == "=" || first == "-",
          content.allSatisfy({ $0 == first }) else { return nil }
    return first == "=" ? 1 : 2
}

private func isThematicBreak(_ line: String) -> Bool {
    let indent = indentation(of: line)
    guard indent <= 3 else { return false }
    let compact = removeIndent(line, columns: indent).filter { !$0.isWhitespace }
    guard compact.count >= 3, let first = compact.first, "*-_".contains(first) else { return false }
    return compact.allSatisfy { $0 == first }
}

private func blockquoteContent(in line: String) -> String? {
    let indent = indentation(of: line)
    guard indent <= 3 else { return nil }
    let content = removeIndent(line, columns: indent)
    guard content.first == ">" else { return nil }
    var result = String(content.dropFirst())
    if result.first == " " { result.removeFirst() }
    return result
}

private func listMarker(in line: String, mayInterruptParagraph: Bool) -> ListMarker? {
    let indent = indentation(of: line)
    guard indent <= 3 else { return nil }
    let content = removeIndent(line, columns: indent)
    guard !content.isEmpty else { return nil }

    let ordered: Bool
    let number: Int?
    let marker: Character
    let markerWidth: Int

    if let first = content.first, "-*+".contains(first) {
        ordered = false
        number = nil
        marker = first
        markerWidth = 1
    } else {
        let digits = content.prefix(while: { $0.isNumber })
        guard (1...9).contains(digits.count), let parsedNumber = Int(digits) else { return nil }
        let markerIndex = content.index(content.startIndex, offsetBy: digits.count)
        guard markerIndex < content.endIndex,
              content[markerIndex] == "." || content[markerIndex] == ")" else { return nil }
        ordered = true
        number = parsedNumber
        marker = content[markerIndex]
        markerWidth = digits.count + 1
    }

    let afterMarker = content.index(content.startIndex, offsetBy: markerWidth)
    if afterMarker == content.endIndex {
        return ListMarker(
            ordered: ordered,
            number: number,
            marker: marker,
            contentIndent: indent + markerWidth + 1,
            content: ""
        )
    }
    guard content[afterMarker].isWhitespace else { return nil }

    let remainder = content[afterMarker...]
    let spaces = remainder.prefix(while: { $0 == " " }).count
    let padding = (1...4).contains(spaces) ? spaces : 1
    let contentStart = content.index(afterMarker, offsetBy: min(spaces, padding))
    return ListMarker(
        ordered: ordered,
        number: number,
        marker: marker,
        contentIndent: indent + markerWidth + padding,
        content: String(content[contentStart...])
    )
}

private func taskListItem(from lines: [String]) -> (lines: [String], checked: Bool?) {
    guard var first = lines.first else { return (lines, nil) }
    let lowered = first.lowercased()
    let checked: Bool?
    if first.hasPrefix("[ ] ") {
        checked = false
    } else if lowered.hasPrefix("[x] ") {
        checked = true
    } else {
        return (lines, nil)
    }
    first.removeFirst(4)
    return ([first] + lines.dropFirst(), checked)
}

private func footnoteDefinition(in line: String) -> (label: String, source: String)? {
    let indent = indentation(of: line)
    guard indent <= 3 else { return nil }
    let content = removeIndent(line, columns: indent)
    guard content.hasPrefix("[^") else { return nil }
    let labelStart = content.index(content.startIndex, offsetBy: 2)
    guard let labelEnd = content[labelStart...].firstIndex(of: "]") else { return nil }
    let colon = content.index(after: labelEnd)
    guard colon < content.endIndex, content[colon] == ":" else { return nil }
    let label = content[labelStart..<labelEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { return nil }
    let sourceStart = content.index(after: colon)
    return (label, String(content[sourceStart...]).trimmingCharacters(in: .whitespaces))
}

private let htmlBlockTags: Set<String> = [
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption",
    "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt",
    "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2",
    "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li",
    "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p",
    "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
    "title", "tr", "track", "ul"
]

private func htmlBlockKind(in line: String, mayInterruptParagraph: Bool) -> HTMLBlockKind? {
    let indent = indentation(of: line)
    guard indent <= 3 else { return nil }
    let content = removeIndent(line, columns: indent)
    let lowered = content.lowercased()
    let extensionTag = lowered.trimmingCharacters(in: .whitespaces)
    if ["<u>", "</u>", "<br>", "<br/>", "<br />"].contains(extensionTag) {
        return nil
    }

    for name in ["pre", "script", "style", "textarea"] {
        let prefix = "<\(name)"
        if lowered.hasPrefix(prefix) {
            let end = lowered.index(lowered.startIndex, offsetBy: prefix.count)
            if end == lowered.endIndex || lowered[end].isWhitespace || lowered[end] == ">" {
                return .rawTag(name: name)
            }
        }
    }
    if content.hasPrefix("<!--") { return .comment }
    if content.hasPrefix("<?") { return .processingInstruction }
    if content.range(of: #"^<![A-Za-z]"#, options: .regularExpression) != nil {
        return .declaration
    }
    if content.hasPrefix("<![CDATA[") { return .cdata }

    if let match = content.range(
        of: #"^</?([A-Za-z][A-Za-z0-9-]*)(?:[ \t]|/?>|$)"#,
        options: [.regularExpression, .caseInsensitive]
    ) {
        let prefix = String(content[match])
        let name = prefix.drop(while: { $0 == "<" || $0 == "/" })
            .prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
            .lowercased()
        if htmlBlockTags.contains(name) { return .blockTag }
    }

    guard !mayInterruptParagraph else { return nil }
    let completeTagPattern = #"^(?:</[A-Za-z][A-Za-z0-9-]*[ \t]*>|<[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t]*=[ \t]*(?:[^ \t\"'=<>`]+|'[^']*'|\"[^\"]*\"))?)*[ \t]*/?>)[ \t]*$"#
    if content.range(of: completeTagPattern, options: .regularExpression) != nil {
        return .completeTag
    }
    return nil
}

private func htmlBlockEnds(_ kind: HTMLBlockKind, line: String) -> Bool {
    switch kind {
    case let .rawTag(name):
        return line.range(of: "</\(name)>", options: .caseInsensitive) != nil
    case .comment: return line.contains("-->")
    case .processingInstruction: return line.contains("?>")
    case .declaration: return line.contains(">")
    case .cdata: return line.contains("]]>")
    case .blockTag, .completeTag: return false
    }
}

private func tableCells(in line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { trimmed.removeFirst() }
    if trimmed.hasSuffix("|") { trimmed.removeLast() }
    return trimmed.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func isTableDelimiter(_ line: String) -> Bool {
    let cells = tableCells(in: line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
        let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return core.count >= 3 && core.allSatisfy { $0 == "-" }
    }
}

private func tableAlignments(in line: String) -> [TableAlignment] {
    tableCells(in: line).map { cell in
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") { return .center }
        if trimmed.hasSuffix(":") { return .trailing }
        return .leading
    }
}

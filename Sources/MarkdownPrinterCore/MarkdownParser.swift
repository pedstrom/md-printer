import Foundation

public struct MarkdownParser: Sendable {
    private let inlineParser: InlineParser

    public init(inlineParser: InlineParser = InlineParser()) {
        self.inlineParser = inlineParser
    }

    public func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = fenceMarker(in: line) {
                let language = String(line.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.codeBlock(
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let definition = footnoteDefinition(in: line) {
                var contentLines = [definition.text]
                index += 1
                while index < lines.count {
                    if let continuation = footnoteContinuation(in: lines[index]) {
                        contentLines.append(continuation)
                        index += 1
                        continue
                    }
                    if lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                       index + 1 < lines.count,
                       footnoteContinuation(in: lines[index + 1]) != nil {
                        contentLines.append("")
                        index += 1
                        continue
                    }
                    break
                }
                blocks.append(.footnoteDefinition(
                    label: definition.label,
                    content: inlineParser.parse(contentLines.joined(separator: "\n"))
                ))
                continue
            }

            if let heading = heading(in: line) {
                blocks.append(.heading(level: heading.level, content: inlineParser.parse(heading.text)))
                index += 1
                continue
            }

            if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix(">") else { break }
                    quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.blockquote(inlineParser.parse(quoteLines.joined(separator: "\n"))))
                continue
            }

            if let firstListItem = listItem(in: line) {
                var items: [MarkdownListItem] = []
                let ordered = firstListItem.ordered
                let start = firstListItem.number ?? 1
                while index < lines.count,
                      let item = listItem(in: lines[index]),
                      item.ordered == ordered {
                    items.append(MarkdownListItem(
                        content: inlineParser.parse(item.text),
                        checked: item.checked
                    ))
                    index += 1
                }
                blocks.append(.list(items: items, ordered: ordered, start: start))
                continue
            }

            if index + 1 < lines.count, isTableDelimiter(lines[index + 1]) {
                let headerCells = tableCells(in: line).map(inlineParser.parse)
                let alignments = tableAlignments(in: lines[index + 1])
                var rows: [[[InlineNode]]] = []
                index += 2
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                      lines[index].contains("|") {
                    rows.append(tableCells(in: lines[index]).map(inlineParser.parse))
                    index += 1
                }
                blocks.append(.table(headers: headerCells, alignments: alignments, rows: rows))
                continue
            }

            var paragraphLines = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !startsBlock(lines[index]),
                  !(index + 1 < lines.count && isTableDelimiter(lines[index + 1])) {
                paragraphLines.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.paragraph(inlineParser.parse(paragraphLines.joined(separator: "\n"))))
        }

        return blocks
    }

    private func startsBlock(_ line: String) -> Bool {
        fenceMarker(in: line) != nil
            || heading(in: line) != nil
            || isThematicBreak(line)
            || line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
            || listItem(in: line) != nil
            || footnoteDefinition(in: line) != nil
    }

    private func footnoteDefinition(in line: String) -> (label: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[^") else { return nil }
        let labelStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
        guard let labelEnd = trimmed[labelStart...].firstIndex(of: "]") else { return nil }
        let colon = trimmed.index(after: labelEnd)
        guard colon < trimmed.endIndex, trimmed[colon] == ":" else { return nil }
        let label = trimmed[labelStart..<labelEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let textStart = trimmed.index(after: colon)
        return (
            label,
            String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
        )
    }

    private func footnoteContinuation(in line: String) -> String? {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        guard line.hasPrefix("    ") else { return nil }
        return String(line.dropFirst(4))
    }

    private func fenceMarker(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private func heading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let markerEnd = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard markerEnd < trimmed.endIndex, trimmed[markerEnd].isWhitespace else { return nil }
        let text = trimmed[markerEnd...].trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private func isThematicBreak(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "*-_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private func listItem(in line: String) -> (ordered: Bool, number: Int?, checked: Bool?, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, "-*+".contains(trimmed.first!), trimmed.dropFirst().first == " " {
            return listItemDetails(ordered: false, number: nil, text: String(trimmed.dropFirst(2)))
        }

        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty,
              let number = Int(digits) else { return nil }
        let markerStart = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard markerStart < trimmed.endIndex,
              trimmed[markerStart] == "." else { return nil }
        let space = trimmed.index(after: markerStart)
        guard space < trimmed.endIndex, trimmed[space] == " " else { return nil }
        return listItemDetails(
            ordered: true,
            number: number,
            text: String(trimmed[trimmed.index(after: space)...])
        )
    }

    private func listItemDetails(
        ordered: Bool,
        number: Int?,
        text: String
    ) -> (ordered: Bool, number: Int?, checked: Bool?, text: String) {
        if text.hasPrefix("[ ] ") {
            return (ordered, number, false, String(text.dropFirst(4)))
        }
        let lowered = text.lowercased()
        if lowered.hasPrefix("[x] ") {
            return (ordered, number, true, String(text.dropFirst(4)))
        }
        return (ordered, number, nil, text)
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
}

#if canImport(AppKit)
import AppKit

/// Structural alignment precedes word comparison. UUID container markers identify
/// local boundaries only; identities used for alignment and review are content based.
enum RevisionStructure {
    typealias Unit = RevisionFormatter.Unit
    typealias Match = RevisionReviewMatch
    struct Group {
        let review: Match
        let pairs: [Match]
        var summary: RevisionDeletion.Summary? = nil
    }
    private final class Node {
        let kind: String
        let units: [Unit]
        let children: [Node]
        let section: (String, String)?
        let words: Set<String>
        let signature: String
        let listItems: Int
        var all: [Unit] { units + children.flatMap(\.all) }
        var location: Int { units.first!.range.location }
        init(_ kind: String, _ units: [Unit], children: [Node] = [], section: (String, String)? = nil, listItems: Int = 0) {
            self.kind = kind; self.units = units; self.children = children; self.section = section
            self.listItems = listItems
            words = Set((units + children.flatMap(\.all)).flatMap { $0.words })
            signature = kind == "section" ? "section|" + units[0].tokens.map { $0.key.lowercased() }.joined()
                : kind + "|" + units.map(\.signature).joined(separator: "\u{1e}")
        }
    }

    static func matches(old: [Unit], new: [Unit], original: NSAttributedString, current: NSAttributedString) -> [Group] {
        var result: [Group] = []
        align(tree(old, in: original), tree(new, in: current), section: ("document", "Document"),
              anchor: current.length, original: original, current: current, result: &result)
        return result
    }

    private static func tree(_ units: [Unit], in text: NSAttributedString) -> [Node] {
        var index = 0
        func read(until level: Int) -> [Node] {
            var nodes: [Node] = []
            while index < units.count {
                let unit = units[index]
                if unit.kind.hasPrefix("heading:"), let depth = Int(unit.kind.split(separator: ":")[1]) {
                    if depth <= level { break }
                    index += 1
                    let anchor = text.attribute(.markdownSectionAnchor, at: unit.range.location, effectiveRange: nil) as? String ?? unit.signature
                    let title = (text.string as NSString).substring(with: unit.range).trimmingCharacters(in: .whitespacesAndNewlines)
                    nodes.append(Node("section", [unit], children: read(until: depth), section: ("heading:" + anchor, title)))
                } else {
                    let container = text.attribute(.revisionContainer, at: unit.range.location, effectiveRange: nil) as? String
                    var group = [unit]; index += 1
                    if let container {
                        while index < units.count,
                              text.attribute(.revisionContainer, at: units[index].range.location, effectiveRange: nil) as? String == container {
                            group.append(units[index]); index += 1
                        }
                    }
                    let kind = unit.kind == "cell" ? "table" : unit.kind.contains(":list:") ? "list" : unit.kind.components(separatedBy: ":")[0]
                    // A list introduction belongs to the list, including when
                    // that introduction and list are rewritten as a paragraph.
                    if kind == "list", let intro = nodes.last, intro.kind == "paragraph",
                       intro.units.last!.tokens.last?.visible == ":" {
                        nodes.removeLast(); group = intro.units + group
                    }
                    let items = kind == "list" ? Set(group.compactMap {
                        text.attribute(.revisionListItem, at: $0.range.location, effectiveRange: nil) as? String
                    }).count : 0
                    nodes.append(Node(kind, group, listItems: items))
                }
            }
            return nodes
        }
        return read(until: 0)
    }

    private static func union(_ units: [Unit], kind: String) -> Unit? {
        guard let first = units.first, let last = units.last else { return nil }
        if units.count == 1 { return first }
        return Unit(kind: kind, range: NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location), tokens: units.flatMap(\.tokens))
    }
    private static func overlap(_ before: Set<String>, _ after: Set<String>) -> Double {
        guard !before.isEmpty, !after.isEmpty else { return 0 }
        return 2 * Double(before.intersection(after).count) / Double(before.count + after.count)
    }
    private static func score(_ old: Node, _ new: Node) -> Double {
        if old.signature == new.signature { return 2 }
        let shared = overlap(old.words, new.words)
        if old.kind == "section", new.kind == "section" {
            let title = overlap(old.units[0].words, new.units[0].words)
            return title >= 0.25 || shared >= 0.32 ? 0.6 + title + shared : 0
        }
        if Set([old.kind, new.kind]) == Set(["list", "paragraph"]) { return shared >= 0.25 ? 0.3 + shared : 0 }
        guard old.kind == new.kind else { return 0 }
        if old.kind == "table" { return shared >= 0.25 ? 0.6 + shared : 0 }
        let images = old.units.flatMap(\.tokens).contains(where: \.image) && new.units.flatMap(\.tokens).contains(where: \.image)
        return shared >= 0.3 || images ? 0.3 + shared : 0
    }

    /// Exact anchors bound each alignment. A small dynamic-programming gap
    /// selects a sequence of edits rather than greedily consuming a later match.
    /// Large rewritten gaps use a bounded lookahead to avoid a quadratic matrix.
    private static func aligned(_ old: [Node], _ new: [Node]) -> [(Int, Int)] {
        guard !old.isEmpty, !new.isEmpty else { return [] }
        let oldSignatures = Set(old.map(\.signature)), newSignatures = Set(new.map(\.signature))
        func value(_ a: Int, _ b: Int) -> Double {
            if old[a].signature == new[b].signature { return 2 }
            guard !newSignatures.contains(old[a].signature), !oldSignatures.contains(new[b].signature) else { return 0 }
            return score(old[a], new[b])
        }
        if old.count * new.count > 65_536 {
            var pairs: [(Int, Int)] = [], next = 0
            for a in old.indices {
                let candidates = next..<min(new.count, next + 16)
                if let b = candidates.max(by: { value(a, $0) < value(a, $1) }), value(a, b) > 0 {
                    pairs.append((a, b)); next = b + 1
                }
            }
            return pairs
        }
        let width = new.count + 1
        var matrix = Array(repeating: 0.0, count: (old.count + 1) * width)
        for a in old.indices.reversed() {
            for b in new.indices.reversed() {
                let paired = value(a, b)
                matrix[a * width + b] = max(matrix[(a + 1) * width + b], matrix[a * width + b + 1],
                                           paired > 0 ? paired + matrix[(a + 1) * width + b + 1] : 0)
            }
        }
        var a = 0, b = 0, pairs: [(Int, Int)] = []
        while a < old.count, b < new.count {
            let paired = value(a, b)
            if paired > 0, abs(matrix[a * width + b] - paired - matrix[(a + 1) * width + b + 1]) < 0.000_001 {
                pairs.append((a, b)); a += 1; b += 1
            } else if matrix[(a + 1) * width + b] > matrix[a * width + b + 1] { a += 1 }
            else { b += 1 }
        }
        return pairs
    }

    private static func align(_ old: [Node], _ new: [Node], section: (String, String), anchor: Int,
                              original: NSAttributedString, current: NSAttributedString, result: inout [Group]) {
        func promote(_ source: [Node], against target: [Node], sourceText: NSAttributedString, targetText: NSAttributedString) -> [Node] {
            source.flatMap { node -> [Node] in
                guard node.kind == "section", !target.contains(where: { $0.kind == "section" && score(node, $0) > 0 }),
                      node.children.contains(where: { child in target.contains(where: { other in
                          child.signature == other.signature || child.kind == "table" && other.kind == "table"
                              && tableIdentity(child, other, sourceText, targetText)
                      }) }) else { return [node] }
                return [Node("heading", node.units, section: node.section)] + node.children
            }
        }
        let beforePromotion = old
        let old = promote(old, against: new, sourceText: original, targetText: current), new = promote(new, against: beforePromotion, sourceText: current, targetText: original)
        let exact = RevisionFormatter.matching(old.map(\.signature), new.map(\.signature))
        var a = 0, b = 0
        for (endA, endB) in exact + [(old.count, new.count)] {
            func consolidate(_ nodes: [Node], against targets: [Node], sourceText: NSAttributedString, targetText: NSAttributedString) -> [Node] {
                let tables = nodes.filter { $0.kind == "table" }, destinations = targets.filter { $0.kind == "table" }
                guard tables.count > 1, destinations.count == 1,
                      tables.allSatisfy({ tableIdentity($0, destinations[0], sourceText, targetText) }) else { return nodes }
                var emitted = false
                return nodes.compactMap { node in
                    guard node.kind == "table" else { return node }
                    guard !emitted else { return nil }; emitted = true
                    let units = tables.enumerated().flatMap { index, table in
                        index == 0 ? table.units : table.units.filter { cell($0, in: sourceText)?.startingRow != 0 }
                    }
                    return Node("table", units)
                }
            }
            let rawBefore = Array(old[a..<endA]), rawAfter = Array(new[b..<endB])
            let before = consolidate(rawBefore, against: rawAfter, sourceText: original, targetText: current)
            let after = consolidate(rawAfter, against: rawBefore, sourceText: current, targetText: original)
            let boundary = endB < new.count ? new[endB].location : anchor
            // Align the surrounding baseline/closing passages separately from
            // a table-to-list rewrite. The table and its introduction form one
            // replacement, with both complete structures available for review.
            var conversion: (Range<Int>, Range<Int>)?
            func converted(_ tables: [Node], _ lists: [Node]) -> (Range<Int>, Range<Int>)? {
                guard !lists.contains(where: { $0.kind == "table" }),
                      let t = tables.firstIndex(where: { $0.kind == "table" }),
                      let l = lists.indices.filter({ lists[$0].kind == "list" }).max(by: { overlap(tables[t].words, lists[$0].words) < overlap(tables[t].words, lists[$1].words) }),
                      overlap(tables[t].words, lists[l].words) >= 0.2 else { return nil }
                let start = t > 0 && tables[t - 1].kind == "paragraph" ? t - 1 : t
                return (start..<(t + 1), l..<(l + 1))
            }
            if let pair = converted(before, after) { conversion = pair }
            else if let pair = converted(after, before) { conversion = (pair.1, pair.0) }
            let proseMerge = before.count != after.count && before.allSatisfy { $0.kind == "paragraph" }
                && after.allSatisfy { $0.kind == "paragraph" }
            let oldWords = Set(before.flatMap { $0.words }), newWords = Set(after.flatMap { $0.words })
            let cohesive = !before.isEmpty && !after.isEmpty && overlap(oldWords, newWords) >= 0.25
                && before.allSatisfy { overlap($0.words, newWords) >= 0.12 }
                && after.allSatisfy { overlap($0.words, oldWords) >= 0.12 }
            if let (oldRange, newRange) = conversion {
                align(Array(before[..<oldRange.lowerBound]), Array(after[..<newRange.lowerBound]), section: section,
                      anchor: after[newRange.lowerBound].location, original: original, current: current, result: &result)
                append(before[oldRange].flatMap(\.all), after[newRange].flatMap(\.all), kind: "passage", section: section,
                       anchor: after[newRange.lowerBound].location, result: &result)
                align(Array(before[oldRange.upperBound...]), Array(after[newRange.upperBound...]), section: section,
                      anchor: boundary, original: original, current: current, result: &result)
            } else if proseMerge && cohesive {
                append(before.flatMap(\.all), after.flatMap(\.all), kind: "passage", section: section, anchor: boundary, result: &result)
            } else {
                let pairs = aligned(before, after)
                var nextA = 0, nextB = 0
                for (i, j) in pairs + [(before.count, after.count)] {
                    let location = j < after.count ? after[j].location : boundary
                    for node in before[nextA..<i] { appendRemoved(node, section: section, anchor: location, result: &result) }
                    for node in after[nextB..<j] { appendAdded(node, section: section, result: &result) }
                    if i < before.count { compare(before[i], after[j], section: section, anchor: location, original: original, current: current, result: &result) }
                    nextA = i + 1; nextB = j + 1
                }
            }
            if endA < old.count { compare(old[endA], new[endB], section: section, anchor: boundary, original: original, current: current, result: &result) }
            a = endA + 1; b = endB + 1
        }
    }

    private static func compare(_ old: Node, _ new: Node, section: (String, String), anchor: Int,
                                original: NSAttributedString, current: NSAttributedString, result: inout [Group]) {
        if old.kind == "section", new.kind == "section" {
            let section = new.section!
            append(old.units, new.units, kind: old.units[0].kind, section: section, anchor: new.location, result: &result)
            align(old.children, new.children, section: section, anchor: NSMaxRange(new.all.last!.range), original: original, current: current, result: &result)
        } else if old.kind == "table" {
            table(old, new, section: section, original: original, current: current, result: &result)
        } else if old.kind == "list", new.kind == "list" {
            // Preserve precise per-item edits inside an established list. A
            // complete new/removed list is handled as one container instead.
            let oldNodes = old.units.map { Node("paragraph", [$0]) }, newNodes = new.units.map { Node("paragraph", [$0]) }
            align(oldNodes, newNodes, section: section, anchor: NSMaxRange(new.units.last!.range), original: original, current: current, result: &result)
        } else { append(old.units, new.units, kind: old.kind == new.kind ? old.units[0].kind : "passage", section: section, anchor: anchor, result: &result) }
    }

    private static func append(_ old: [Unit], _ new: [Unit], kind: String, section: (String, String), anchor: Int, result: inout [Group], pairs: [Match]? = nil, summary: RevisionDeletion.Summary? = nil) {
        let before = union(old, kind: kind), after = union(new, kind: kind)
        var review = Match(earlier: before, current: after, anchor: after?.range.location ?? anchor, section: section, parts: pairs ?? [])
        if kind == "row", let pairs, !pairs.isEmpty {
            // The source passage stays complete; cell-level metadata identifies
            // its columns without changing the rendered document text.
            review.metadata = ["Table row; cells are shown in their source column order."]
        }
        result.append(Group(review: review, pairs: pairs ?? [review], summary: summary))
    }
    private static func appendRemoved(_ node: Node, section: (String, String), anchor: Int, result: inout [Group]) {
        let summary: RevisionDeletion.Summary?
        switch node.kind {
        case "section": summary = .sections(1)
        case "table": summary = .tables(1)
        case "list": summary = .listItems(node.listItems)
        case "paragraph": summary = .paragraphs(node.units.count)
        default: summary = nil
        }
        append(node.all, [], kind: node.kind, section: node.section ?? section, anchor: anchor, result: &result, summary: summary)
    }
    private static func appendAdded(_ node: Node, section: (String, String), result: inout [Group]) {
        append([], node.all, kind: node.kind, section: node.section ?? section, anchor: node.location, result: &result)
    }

    private static func cell(_ unit: Unit, in text: NSAttributedString) -> NSTextTableBlock? {
        (text.attribute(.paragraphStyle, at: unit.range.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock
    }
    private static func tableIdentity(_ old: Node, _ new: Node, _ original: NSAttributedString, _ current: NSAttributedString) -> Bool {
        func identifiers(_ node: Node, _ text: NSAttributedString) -> Set<String> {
            Set(node.units.filter { unit in
                guard let block = cell(unit, in: text) else { return false }
                return block.startingColumn == 0 && block.startingRow > 0
            }.map(rowKey))
        }
        let before = identifiers(old, original), after = identifiers(new, current)
        guard !before.isEmpty, !after.isEmpty else { return false }
        return Double(before.intersection(after).count) / Double(min(before.count, after.count)) >= 0.5
    }

    private static func rowKey(_ unit: Unit) -> String {
        let text = unit.tokens.map(\.visible).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return first.rangeOfCharacter(from: .decimalDigits) != nil ? first : text.lowercased()
    }
    private static func columnRole(_ unit: Unit) -> String? {
        if !unit.words.isDisjoint(with: ["status", "current"]) { return "status" }
        if !unit.words.isDisjoint(with: ["required", "remaining", "proof", "progression"]) { return "proof" }
        return nil
    }

    private static func table(_ old: Node, _ new: Node, section: (String, String), original: NSAttributedString, current: NSAttributedString, result: inout [Group]) {
        func rows(_ node: Node, _ text: NSAttributedString) -> [[Unit]] {
            var rows: [[Unit]] = [], previous: Int?, previousTable: NSTextTable?
            for unit in node.units {
                let style = text.attribute(.paragraphStyle, at: unit.range.location, effectiveRange: nil) as? NSParagraphStyle
                let block = style?.textBlocks.first as? NSTextTableBlock
                let row = block?.startingRow ?? 0
                if previous == row && previousTable === block?.table { rows[rows.count - 1].append(unit) } else { rows.append([unit]); previous = row; previousTable = block?.table }
            }
            return rows
        }
        let oldRows = rows(old, original), newRows = rows(new, current)
        let headers = aligned(oldRows[0].map { Node("paragraph", [$0]) }, newRows[0].map { Node("paragraph", [$0]) })
        // Matching titles, including exact titles, identifies columns across
        // insertion/reordering. Equal-width renamed headers retain position.
        var columns = RevisionFormatter.matching(oldRows[0].map(\.signature), newRows[0].map(\.signature))
        for i in oldRows[0].indices where !columns.contains(where: { $0.0 == i }) {
            if let j = newRows[0].indices.first(where: { j in !columns.contains(where: { $0.1 == j }) && oldRows[0][i].signature == newRows[0][j].signature }) { columns.append((i, j)) }
        }
        for pair in headers where !columns.contains(where: { $0.0 == pair.0 || $0.1 == pair.1 }) { columns.append(pair) }
        for i in oldRows[0].indices where !columns.contains(where: { $0.0 == i }) {
            let role = columnRole(oldRows[0][i])
            if let role, let j = newRows[0].indices.first(where: { j in
                !columns.contains(where: { $0.1 == j }) && columnRole(newRows[0][j]) == role
            }) { columns.append((i, j)) }
        }
        if oldRows[0].count == newRows[0].count {
            for index in oldRows[0].indices where !columns.contains(where: { $0.0 == index || $0.1 == index }) { columns.append((index, index)) }
        }
        columns.sort { $0.1 < $1.1 }
        var rowPairs = [(0, 0)]
        var used = Set<Int>([0])
        for i in oldRows.indices.dropFirst() {
            let key = rowKey(oldRows[i][0])
            if let j = newRows.indices.dropFirst().first(where: { !used.contains($0) && rowKey(newRows[$0][0]) == key }) {
                rowPairs.append((i, j)); used.insert(j)
            } else if key.rangeOfCharacter(from: .decimalDigits) == nil, oldRows.count == newRows.count, !used.contains(i) { rowPairs.append((i, i)); used.insert(i) }
        }
        var changedRows: [Group] = []
        for j in newRows.indices {
            guard let i = rowPairs.first(where: { $0.1 == j })?.0 else {
                append([], newRows[j], kind: "row", section: section, anchor: newRows[j][0].range.location, result: &changedRows); continue
            }
            var pairs: [Match] = []
            for column in newRows[j].indices {
                let before = columns.first(where: { $0.1 == column }).flatMap { $0.0 < oldRows[i].count ? oldRows[i][$0.0] : nil }
                let after = newRows[j][column]
                pairs.append(Match(earlier: before, current: after, anchor: after.range.location))
            }
            for column in oldRows[i].indices where !columns.contains(where: { $0.0 == column }) {
                pairs.append(Match(earlier: oldRows[i][column], current: nil, anchor: newRows[j][0].range.location))
            }
            append(oldRows[i], newRows[j], kind: "row", section: section, anchor: newRows[j][0].range.location, result: &changedRows, pairs: pairs)
        }
        for i in oldRows.indices where !rowPairs.contains(where: { $0.0 == i }) {
            append(oldRows[i], [], kind: "row", section: section, anchor: NSMaxRange(new.units.last!.range), result: &changedRows)
        }
        // Keep table rows in current order, with old-only rows at their boundary.
        result += changedRows
    }
}
#endif

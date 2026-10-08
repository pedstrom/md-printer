#if canImport(AppKit)
import AppKit
import CryptoKit

public struct RevisionReviewItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case added = "Added", removed = "Removed", changed = "Changed" }
    public let id: String
    public let kind: Kind
    public let sectionID: String
    public let sectionTitle: String
    public let earlier: String?
    public let current: String?
    public let removedRanges: [NSRange]
    public let addedRanges: [NSRange]
    public let metadata: [String]
    public let currentRange: NSRange
    public let anchor: Int
    public let isCode: Bool
    public var structure: String = "paragraph"

    public var changeLabel: String {
        let noun = ["table": "table", "row": "table row", "cell": "table cell", "list": "list", "section": "section", "passage": "passage"][structure]
        return kind.rawValue + (noun.map { " " + $0 } ?? "")
    }

    public var excerpt: String {
        let text = (current ?? earlier ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(text.prefix(100))
    }
}

struct RevisionReviewMatch {
    let earlier: RevisionFormatter.Unit?
    let current: RevisionFormatter.Unit?
    let anchor: Int
    var section: (String, String)? = nil
    var parts: [RevisionReviewMatch] = []
    var metadata: [String] = []
}

enum RevisionReviewBuilder {
    private struct Passage {
        let text: String
        let ranges: [NSRange]
        let metadata: [String]
    }

    static func build(current: NSAttributedString, original: NSAttributedString, matches: [RevisionReviewMatch], highlights: [NSRange]) -> [RevisionReviewItem] {
        var occurrences: [String: Int] = [:]
        var result: [RevisionReviewItem] = []
        var previousSourceEnd: Int?
        let currentHeadings = headings(in: current), originalHeadings = headings(in: original)
        for match in matches {
            let old = match.earlier, new = match.current
            defer { previousSourceEnd = NSMaxRange((new ?? old)!.range) }
            let kind: RevisionReviewItem.Kind = old == nil ? .added : (new == nil ? .removed : .changed)
            let section = match.section ?? (new == nil ? originalHeadings : currentHeadings).last(where: { $0.0 <= (new ?? old)!.range.location })?.1 ?? ("document", "Document")
            var oldMatches = Set<Int>(), newMatches = Set<Int>()
            for part in match.parts.isEmpty ? [match] : match.parts {
                let pairs = RevisionFormatter.matching(part.earlier?.tokens.map(\.key) ?? [], part.current?.tokens.map(\.key) ?? [])
                oldMatches.formUnion(pairs.map { part.earlier!.tokens[$0.0].range.location })
                newMatches.formUnion(pairs.map { part.current!.tokens[$0.1].range.location })
            }
            let before = old.map { passage($0, in: original, unchanged: oldMatches) }
            let after = new.map { passage($0, in: current, unchanged: newMatches, highlights: highlights) }
            var metadata: [String] = []
            if let before, let after, before.metadata != after.metadata {
                metadata = ["Earlier details: " + (before.metadata.isEmpty ? "Regular prose" : before.metadata.joined(separator: "; ")),
                            "Current details: " + (after.metadata.isEmpty ? "Regular prose" : after.metadata.joined(separator: "; "))]
            } else if kind != .changed { metadata = (after ?? before)?.metadata ?? [] }
            metadata += match.metadata
            let code = (new ?? old)!.kind.hasPrefix("code") || (new ?? old)!.kind.hasPrefix("html")
            let range = new?.range ?? NSRange(location: match.anchor, length: 0)
            // Combine complete adjacent prose only. Cell, list and code boundaries remain independent.
            if kind != .changed, let previous = result.last, previous.kind == kind,
               previous.sectionID == section.0, !code,
               (new ?? old)!.kind.hasPrefix("paragraph"), !(new ?? old)!.kind.contains(":list:"),
               previousSourceEnd.map({ $0 + 1 >= (new ?? old)!.range.location }) == true,
               (kind == .removed ? previous.anchor == match.anchor : NSMaxRange(previous.currentRange) + 1 >= range.location),
               previous.metadata == metadata {
                result.removeLast()
                let earlier = combine(previous.earlier, before?.text), later = combine(previous.current, after?.text)
                result.append(item(kind: kind, section: section, earlier: earlier, current: later,
                                   removed: earlier.map { [NSRange(location: 0, length: ($0 as NSString).length)] } ?? [],
                                   added: later.map { [NSRange(location: 0, length: ($0 as NSString).length)] } ?? [],
                                   metadata: metadata, range: kind == .added ? NSUnionRange(previous.currentRange, range) : range,
                                   anchor: previous.anchor, code: false, structure: previous.structure, occurrences: &occurrences))
            } else {
                result.append(item(kind: kind, section: section, earlier: before?.text, current: after?.text,
                                   removed: before?.ranges ?? [], added: after?.ranges ?? [], metadata: metadata,
                                   range: range, anchor: match.anchor, code: code, structure: (new ?? old)!.kind.components(separatedBy: ":")[0], occurrences: &occurrences))
            }
        }
        // The outline and Previous/Next consume this same section order.
        var sections: [String] = []
        var groups: [String: [RevisionReviewItem]] = [:]
        for item in result {
            if groups[item.sectionID] == nil { sections.append(item.sectionID) }
            groups[item.sectionID, default: []].append(item)
        }
        return sections.flatMap { groups[$0]! }
    }

    private static func combine(_ first: String?, _ second: String?) -> String? {
        guard let first, let second else { return first ?? second }
        return first.trimmingCharacters(in: .newlines) + "\n\n" + second
    }

    private static func item(kind: RevisionReviewItem.Kind, section: (String, String), earlier: String?, current: String?,
                             removed: [NSRange], added: [NSRange], metadata: [String], range: NSRange, anchor: Int,
                             code: Bool, structure: String, occurrences: inout [String: Int]) -> RevisionReviewItem {
        let fingerprint = [kind.rawValue, section.0, earlier ?? "", current ?? "", metadata.joined(separator: "\n")].joined(separator: "\u{1f}")
        let hash = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let occurrence = occurrences[hash, default: 0]; occurrences[hash] = occurrence + 1
        return RevisionReviewItem(id: hash + ":\(occurrence)", kind: kind, sectionID: section.0, sectionTitle: section.1,
                                  earlier: earlier, current: current, removedRanges: removed, addedRanges: added,
                                  metadata: metadata, currentRange: range, anchor: anchor, isCode: code, structure: structure)
    }

    private static func headings(in text: NSAttributedString) -> [(Int, (String, String))] {
        var sections: [(Int, (String, String))] = []
        text.enumerateAttribute(.markdownSectionAnchor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let anchor = value as? String else { return }
            let title = (text.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append((range.location, ("heading:" + anchor, title)))
        }
        return sections
    }

    private static func passage(_ unit: RevisionFormatter.Unit, in text: NSAttributedString, unchanged: Set<Int>, highlights: [NSRange]? = nil) -> Passage {
        var output = "", changed: [NSRange] = [], metadata: [String] = []
        let source = text.string as NSString
        var cursor = unit.range.location
        for token in unit.tokens {
            if token.range.location > cursor { output += source.substring(with: NSRange(location: cursor, length: token.range.location - cursor)) }
            let start = (output as NSString).length
            if token.image {
                let reference = text.attribute(.revisionImage, at: token.range.location, effectiveRange: nil) as? String ?? ""
                let parts = reference.components(separatedBy: "|")
                output += "Image: " + (parts.first ?? "") + (parts.count > 1 && !parts[1].isEmpty ? " (\(parts[1]))" : "")
                if parts.count > 2, !parts[2].isEmpty, parts[2] != "nil" {
                    let value = parts[2].hasPrefix("Optional(") && parts[2].hasSuffix(")") ? String(parts[2].dropFirst(9).dropLast()) : parts[2]
                    metadata.append((parts[2].hasPrefix("Optional(") ? "Image width: " : "Image title: ") + value)
                }
            } else { output += source.substring(with: token.range) }
            let marked = highlights.map { ranges in ranges.contains { NSIntersectionRange($0, token.range).length > 0 } }
                ?? !unchanged.contains(token.range.location)
            if marked { changed.append(NSRange(location: start, length: (output as NSString).length - start)) }
            if let reference = text.attribute(.revisionReference, at: token.range.location, effectiveRange: nil) as? String {
                let parts = reference.components(separatedBy: "|")
                let label = "Link: " + parts[0] + (parts.count > 1 && !parts[1].isEmpty ? " (" + parts[1] + ")" : "")
                if !metadata.contains(label) { metadata.append(label) }
            }
            if let traits = text.attribute(.revisionTraits, at: token.range.location, effectiveRange: nil) as? [String] {
                for trait in traits where !metadata.contains(trait.capitalized) { metadata.append(trait.capitalized) }
            }
            cursor = NSMaxRange(token.range)
        }
        if cursor < NSMaxRange(unit.range) { output += source.substring(with: NSRange(location: cursor, length: NSMaxRange(unit.range) - cursor)) }
        // Include container/heading semantics even when the displayed wording is identical.
        let kind = unit.kind.components(separatedBy: ":")
        if kind[0] == "heading" { metadata.insert("Heading level " + kind[1], at: 0) }
        else if kind[0] == "code" { metadata.insert("Code block" + (kind.count > 1 && !kind[1].isEmpty ? " (" + kind[1] + ")" : ""), at: 0) }
        else if kind[0] == "cell" {
            metadata.insert("Table cell", at: 0)
            if let style = text.attribute(.paragraphStyle, at: unit.range.location, effectiveRange: nil) as? NSParagraphStyle {
                let alignment: String
                switch style.alignment {
                case .left: alignment = "Left"
                case .right: alignment = "Right"
                case .center: alignment = "Center"
                case .justified: alignment = "Justified"
                default: alignment = "Automatic"
                }
                metadata.append("Alignment: " + alignment)
            }
        }
        else if kind[0] == "html" { metadata.insert("HTML source", at: 0) }
        if kind.contains("quote") { metadata.append("Quotation depth: \(kind.filter { $0 == "quote" }.count)") }
        if let list = kind.firstIndex(of: "list"), kind.count > list + 3 {
            metadata.append(kind[list + 1] == "true" ? "Numbered list starting at " + kind[list + 2] : "Bulleted list")
            if kind[list + 3].contains("true") { metadata.append("Completed task") }
            else if kind[list + 3].contains("false") { metadata.append("Incomplete task") }
        }
        if ["table", "row", "list", "section", "passage"].contains(kind[0]) { metadata.insert(kind[0] == "row" ? "Table row" : kind[0].capitalized, at: 0) }
        var ranges: [NSRange] = []
        for range in changed {
            if let last = ranges.last, NSMaxRange(last) == range.location { ranges[ranges.count - 1] = NSUnionRange(last, range) }
            else { ranges.append(range) }
        }
        return Passage(text: output, ranges: ranges, metadata: metadata)
    }
}
#endif

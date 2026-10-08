#if canImport(AppKit)
import AppKit
import NaturalLanguage

extension NSAttributedString.Key {
    static let revisionBlock = Self("MarkdownPrinter.revisionBlock")
    static let revisionKind = Self("MarkdownPrinter.revisionKind")
    static let revisionContainer = Self("MarkdownPrinter.revisionContainer")
    static let revisionListItem = Self("MarkdownPrinter.revisionListItem")
    static let revisionReference = Self("MarkdownPrinter.revisionReference")
    static let revisionImage = Self("MarkdownPrinter.revisionImage")
    static let revisionLiteral = Self("MarkdownPrinter.revisionLiteral")
    static let revisionTraits = Self("MarkdownPrinter.revisionTraits")
    static let revisionHardBreak = Self("MarkdownPrinter.revisionHardBreak")
    static let revisionHighlight = Self("MarkdownPrinter.revisionHighlight")
    static let revisionImageChanged = Self("MarkdownPrinter.revisionImageChanged")
}

public struct RevisionDeletion: Equatable, Sendable {
    public enum Summary: Equatable, Sendable {
        case paragraphs(Int), sentences(Int), words(Int), tables(Int), listItems(Int), sections(Int)

        var wording: String {
            let count: Int, noun: String
            switch self {
            case let .paragraphs(value): count = value; noun = "paragraph"
            case let .sentences(value): count = value; noun = "sentence"
            case let .words(value): count = value; noun = "word"
            case let .tables(value): count = value; noun = "table"
            case let .listItems(value): count = value; noun = "list item"
            case let .sections(value): count = value; noun = "section"
            }
            return "removed \(count) \(noun)\(count == 1 ? "" : "s")"
        }

        func combined(with other: Summary) -> Summary? {
            switch (self, other) {
            case let (.paragraphs(a), .paragraphs(b)): return .paragraphs(a + b)
            case let (.sentences(a), .sentences(b)): return .sentences(a + b)
            case let (.words(a), .words(b)): return .words(a + b)
            case let (.tables(a), .tables(b)): return .tables(a + b)
            case let (.listItems(a), .listItems(b)): return .listItems(a + b)
            case let (.sections(a), .sections(b)): return .sections(a + b)
            default: return nil
            }
        }
    }

    public let location: Int
    public let text: String
    public let isImage: Bool
    public let summary: Summary?

    public init(location: Int, text: String, isImage: Bool = false, summary: Summary? = nil) {
        self.location = location
        self.text = text
        self.isImage = isImage
        self.summary = summary
    }

    public var label: String { isImage ? "^ removed image" : "^ \(summary?.wording ?? text)" }
    public var strikesWording: Bool { !isImage && summary == nil }
}

public struct RevisionDecorations: Equatable, Sendable {
    public var highlights: [NSRange] = []
    public var images: [NSRange] = []
    public var deletions: [RevisionDeletion] = []
    public init() {}
}

public struct RevisionRenderedText {
    public let text: NSAttributedString
    public let decorations: RevisionDecorations
    public var reviewItems: [RevisionReviewItem] = []
}

/// Compares semantic rendering units, before pagination. The original renderer
/// substitutes image references without opening any historical image files.
public enum RevisionFormatter {
    public static let highlightColor = NSColor(calibratedRed: 1, green: 0.94, blue: 0.48, alpha: 1)
    public static let imageBorderColor = NSColor(calibratedRed: 0.92, green: 0.73, blue: 0, alpha: 1)
    public static let deletionColor = NSColor(calibratedRed: 0.78, green: 0.06, blue: 0.08, alpha: 1)

    public static func format(current: NSAttributedString, original: NSAttributedString) -> RevisionRenderedText {
        let old = units(in: original), new = units(in: current)
        var changes = RevisionDecorations()
        var reviewMatches: [RevisionReviewMatch] = []
        for group in RevisionStructure.matches(old: old, new: new, original: original, current: current) {
            let start = reviewMatches.count
            for pair in group.pairs {
                if let before = pair.earlier, let after = pair.current {
                    compare(before, after, changes: &changes, reviews: &reviewMatches)
                } else if let after = pair.current {
                    add(after, changes: &changes, reviews: &reviewMatches)
                } else if let before = pair.earlier {
                    remove(before.tokens, at: pair.anchor, summary: group.summary ?? removalSummary(in: before, ranges: [before.tokens.indices]), changes: &changes)
                    reviewMatches.append(pair)
                }
            }
            if reviewMatches.count > start {
                reviewMatches.removeSubrange(start...)
                reviewMatches.append(group.review)
            }
        }
        changes.highlights = joinPhraseHighlights(merge(changes.highlights), in: current)
        // Adjacent attachments still need separate borders inside each image.
        changes.images = changes.images.sorted { $0.location < $1.location }
        changes.deletions = coalesce(changes.deletions)
        let result = NSMutableAttributedString(attributedString: current)
        for range in changes.highlights { result.addAttribute(.revisionHighlight, value: true, range: range) }
        for range in changes.images { result.addAttribute(.revisionImageChanged, value: true, range: range) }
        return RevisionRenderedText(text: result, decorations: changes, reviewItems: RevisionReviewBuilder.build(current: current, original: original, matches: reviewMatches, highlights: changes.highlights))
    }

    struct Token {
        let key: String
        let visible: String
        let range: NSRange
        let style: String
        let image: Bool
        let literal: Bool
        var whitespace: Bool { !image && visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var word: Bool { !image && key.rangeOfCharacter(from: .alphanumerics) != nil }
    }
    struct Unit {
        let kind: String
        let range: NSRange
        let tokens: [Token]
        let signature: String
        let words: Set<String>
        init(kind: String, range: NSRange, tokens: [Token]) {
            self.kind = kind; self.range = range; self.tokens = tokens
            signature = kind.components(separatedBy: ":").first! + "|" + tokens.map(\.key).joined(separator: "\u{1f}")
            words = Set(tokens.filter { !$0.image && $0.key.rangeOfCharacter(from: .alphanumerics) != nil }.map { $0.key.lowercased() })
        }
    }

    private static func units(in text: NSAttributedString) -> [Unit] {
        var result: [Unit] = []
        text.enumerateAttribute(.revisionBlock, in: NSRange(location: 0, length: text.length)) { marker, range, _ in
            guard marker != nil else { return }
            let kind = text.attribute(.revisionKind, at: range.location, effectiveRange: nil) as? String ?? "paragraph"
            result.append(Unit(kind: kind, range: range, tokens: tokens(in: text, range: range)))
        }
        return result
    }

    static func tokens(in text: NSAttributedString, range: NSRange) -> [Token] {
        var result: [Token] = []
        let string = text.string as NSString
        let regex = try! NSRegularExpression(pattern: #"\p{N}+(?:[,.]\p{N}+)+|[\p{L}\p{M}\p{N}_]+|[^\s]|\s+"#)
        var consumedThrough = range.location
        for match in regex.matches(in: text.string, range: range) {
            guard match.range.location >= consumedThrough else { continue }
            var semanticRange = NSRange()
            let image = text.attribute(.revisionImage, at: match.range.location, effectiveRange: &semanticRange) as? String
            let footnote = text.attribute(.markdownFootnoteReference, at: match.range.location, effectiveRange: nil) as? String
                ?? text.attribute(.markdownFootnoteDefinition, at: match.range.location, effectiveRange: nil) as? String
            var tokenRange = match.range
            if image != nil { tokenRange = NSIntersectionRange(range, semanticRange) }
            else if footnote != nil {
                let key: NSAttributedString.Key = text.attribute(.markdownFootnoteReference, at: match.range.location, effectiveRange: nil) != nil
                    ? .markdownFootnoteReference : .markdownFootnoteDefinition
                _ = text.attribute(key, at: match.range.location, effectiveRange: &semanticRange)
                tokenRange = NSIntersectionRange(range, semanticRange)
            }
            let attributes = text.attributes(at: tokenRange.location, effectiveRange: nil)
            var styles: [String] = []
            text.enumerateAttributes(in: tokenRange) { attributes, _, _ in
                let style = styleSignature(attributes)
                if styles.last != style { styles.append(style) }
            }
            let value = string.substring(with: tokenRange)
            let whitespace = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let literal = attributes[.revisionLiteral] as? Bool == true
            let hardBreak = attributes[.revisionHardBreak] as? Bool == true
            let key = image.map { "image:" + $0 } ?? footnote.map { "footnote:" + $0 }
                ?? (whitespace && !literal ? (hardBreak ? "\nhard" : " ") : value)
            let visible = image != nil ? "" : (whitespace && !literal ? " " : value)
            let style = styles.joined(separator: ";")
            if key == " ", let last = result.last, last.key == " " {
                result[result.count - 1] = Token(key: key, visible: " ", range: NSUnionRange(last.range, tokenRange), style: style, image: false, literal: false)
            } else {
                result.append(Token(key: key, visible: visible, range: tokenRange, style: style, image: image != nil, literal: literal))
            }
            consumedThrough = NSMaxRange(tokenRange)
        }
        while result.first?.key == " " { result.removeFirst() }
        while result.last?.key == " " { result.removeLast() }
        return result
    }

    private static func styleSignature(_ attributes: [NSAttributedString.Key: Any]) -> String {
        if attributes[.revisionImage] != nil {
            return attributes[.revisionReference] as? String ?? ""
        }
        let font = attributes[.font] as? NSFont
        let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
        let blocks = paragraph?.textBlocks.map { $0 is NSTextTableBlock ? "table" : "block" }.joined(separator: ",") ?? ""
        var parts = [font?.fontName ?? "", String(describing: font?.pointSize ?? 0)]
        parts.append(String(describing: attributes[.underlineStyle] ?? ""))
        parts.append(String(describing: attributes[.strikethroughStyle] ?? ""))
        parts.append(attributes[.revisionReference] as? String ?? "")
        parts.append((attributes[.revisionTraits] as? [String] ?? []).joined(separator: ","))
        parts.append(String(attributes[.revisionLiteral] as? Bool == true))
        parts.append(String(paragraph?.alignment.rawValue ?? 0))
        parts.append(blocks)
        return parts.joined(separator: "|")
    }

    /// CollectionDifference uses a sequence diff and avoids a quadratic matrix.
    static func matching(_ old: [String], _ new: [String]) -> [(Int, Int)] {
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        return Array(zip(old.indices.filter { !removed.contains($0) }, new.indices.filter { !inserted.contains($0) }))
    }

    private static func compare(_ old: Unit, _ new: Unit, changes: inout RevisionDecorations, reviews: inout [RevisionReviewMatch]) {
        let before = (changes.highlights.count, changes.images.count, changes.deletions.count)
        defer {
            if before != (changes.highlights.count, changes.images.count, changes.deletions.count) {
                reviews.append(RevisionReviewMatch(earlier: old, current: new, anchor: new.range.location))
            }
        }
        let exactMatches = matching(old.tokens.map(\.key), new.tokens.map(\.key))
        let matches = phraseMatches(old, new, exactMatches: exactMatches)
        var newStart = 0
        for (oldEnd, newEnd) in matches + [(old.tokens.count, new.tokens.count)] {
            for index in newStart..<newEnd {
                mark(new.tokens[index], changes: &changes)
                if new.tokens[index].key == "\nhard" || new.tokens[index].visible.contains("\n") {
                    markBreakNeighbor(in: new.tokens, at: index, changes: &changes)
                }
            }
            if oldEnd < old.tokens.count {
                let before = old.tokens[oldEnd], after = new.tokens[newEnd]
                if before.style != after.style || (!after.image && old.kind != new.kind) { mark(after, changes: &changes) }
            }
            newStart = newEnd + 1
        }
        // Broad rewrite highlights are a reading aid, not evidence that every
        // word in the highlighted passage was removed from the old version.
        // Use exact matches for deletions and their positions independently.
        var oldStart = 0
        newStart = 0
        var removals: [(range: Range<Int>, location: Int)] = []
        for (oldEnd, newEnd) in exactMatches + [(old.tokens.count, new.tokens.count)] {
            let removed = Array(old.tokens[oldStart..<oldEnd]).filter { token in
                !token.image || !new.tokens[newStart..<newEnd].contains(where: \.image)
            }
            let location = deletionBoundary(in: new, startingAt: newStart)
            if removed.contains(where: { $0.key == "\nhard" }) {
                markBreakNeighbor(in: new.tokens, at: min(newStart, max(0, new.tokens.count - 1)), changes: &changes)
            }
            if removed.contains(where: \.image) { remove(removed.filter(\.image), at: location, changes: &changes) }
            if meaningful(removed.filter { !$0.image }),
               !initialCapitalizationOnly(removed, Array(new.tokens[newStart..<newEnd])) {
                removals.append((oldStart..<oldEnd, location))
            }
            oldStart = oldEnd + 1; newStart = newEnd + 1
        }
        // Spaces and punctuation are useful for highlighting, but poor anchors
        // for deletion labels. Join adjacent fragments, and use one old phrase
        // for a heavily rewritten passage rather than a pile of single words.
        // A surviving phrase is a boundary: never include it in a red excerpt.
        var phrases: [(range: Range<Int>, location: Int)] = []
        for removal in removals {
            if let last = phrases.last,
               old.tokens[last.range.upperBound..<removal.range.lowerBound].allSatisfy({
                   $0.key.rangeOfCharacter(from: .alphanumerics) == nil && !$0.literal && !$0.image
               }),
               !sentenceBreak(old.tokens, between: last.range.upperBound, and: removal.range.lowerBound) {
                phrases[phrases.count - 1] = (last.range.lowerBound..<removal.range.upperBound, last.location)
            } else { phrases.append(removal) }
        }
        var group: [(range: Range<Int>, location: Int)] = []
        func emitGroup() {
            guard let first = group.first, let last = group.last else { return }
            if group.count >= 3 && !old.tokens[first.range.lowerBound..<last.range.upperBound].contains(where: { $0.literal || $0.image }) {
                remove(Array(old.tokens[first.range.lowerBound..<last.range.upperBound]), at: first.location,
                       summary: removalSummary(in: old, ranges: group.map(\.range)), changes: &changes)
            } else {
                for phrase in group {
                    remove(Array(old.tokens[phrase.range]), at: phrase.location,
                           summary: removalSummary(in: old, ranges: [phrase.range]), changes: &changes)
                }
            }
            group.removeAll()
        }
        for phrase in phrases {
            if let last = group.last {
                let shared = old.tokens[last.range.upperBound..<phrase.range.lowerBound]
                if shared.filter(\.word).count >= 3 || shared.contains(where: { $0.literal || $0.image }) { emitGroup() }
            }
            group.append(phrase)
        }
        emitGroup()
    }

    /// Keep small edits precise. In a substantial rewrite, isolated common
    /// words are weak anchors: retain the unchanged ends and substantial runs.
    private static func phraseMatches(_ old: Unit, _ new: Unit, exactMatches matches: [(Int, Int)]) -> [(Int, Int)] {
        let words = new.tokens.indices.filter { new.tokens[$0].word }
        let matchedWords = Set(matches.map { $0.1 }).intersection(words)
        guard words.count >= 8, Double(words.count - matchedWords.count) / Double(words.count) >= 0.25,
              !["code", "html"].contains(new.kind.components(separatedBy: ":").first ?? "") else { return matches }
        var runs: [[(Int, Int)]] = []
        for match in matches {
            if let last = runs.last?.last, match.0 == last.0 + 1 && match.1 == last.1 + 1 {
                runs[runs.count - 1].append(match)
            } else { runs.append([match]) }
        }
        guard runs.count >= 3 else { return matches }
        let retained = runs.indices.filter { index in
            let run = runs[index]
            guard let first = run.first, let last = run.last else { return false }
            if first.0 == 0 && first.1 == 0 { return true }
            if last.0 == old.tokens.count - 1 && last.1 == new.tokens.count - 1 { return true }
            let count = run.filter { new.tokens[$0.1].word }.count
            let separatesSentences = run.contains { [".", "!", "?"].contains(new.tokens[$0.1].key) }
            return count >= 8 || (count >= 2 && separatesSentences)
        }
        let preserved = Set(retained)
        return runs.indices.filter { index in
            if preserved.contains(index) { return true }
            guard runs[index].filter({ new.tokens[$0.1].word }).count >= 3 else { return false }
            // A short unchanged phrase beside a substantial shared passage
            // remains meaningful when only a nearby modifier was removed.
            return [index - 1, index + 1].contains { neighbor in
                guard preserved.contains(neighbor) else { return false }
                let before = runs[min(index, neighbor)].last!, after = runs[max(index, neighbor)].first!
                return old.tokens[(before.0 + 1)..<after.0].filter(\.word).count <= 2
                    && new.tokens[(before.1 + 1)..<after.1].filter(\.word).count <= 2
            }
        }.flatMap { runs[$0] }
    }

    private static func deletionBoundary(in unit: Unit, startingAt index: Int) -> Int {
        let next = unit.tokens.indices.dropFirst(index).first { offset in
            let token = unit.tokens[offset]
            return !token.whitespace || token.literal || token.key == "\nhard"
        }
        return next.map { unit.tokens[$0].range.location }
            ?? unit.tokens.last.map { NSMaxRange($0.range) } ?? unit.range.location
    }

    private static func markBreakNeighbor(in tokens: [Token], at index: Int, changes: inout RevisionDecorations) {
        if let next = tokens.indices.dropFirst(index).first(where: { !tokens[$0].whitespace && !tokens[$0].image }) {
            mark(tokens[next], changes: &changes)
        } else if let previous = tokens.indices.prefix(index).last(where: { !tokens[$0].whitespace && !tokens[$0].image }) {
            mark(tokens[previous], changes: &changes)
        }
    }

    private static func joinPhraseHighlights(_ ranges: [NSRange], in text: NSAttributedString) -> [NSRange] {
        var result: [NSRange] = []
        let string = text.string as NSString
        for range in ranges {
            if let last = result.last {
                let gap = NSRange(location: NSMaxRange(last), length: range.location - NSMaxRange(last))
                let before = text.attribute(.revisionBlock, at: NSMaxRange(last) - 1, effectiveRange: nil) as? String
                let after = text.attribute(.revisionBlock, at: range.location, effectiveRange: nil) as? String
                let value = string.substring(with: gap)
                if before != nil, before == after,
                   value.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }) {
                    result[result.count - 1] = NSUnionRange(last, range)
                    continue
                }
            }
            result.append(range)
        }
        return result
    }

    private static func sentenceBreak(_ tokens: [Token], between start: Int, and end: Int) -> Bool {
        guard start < end else { return false }
        return (start..<end).contains { index in
            [".", "!", "?"].contains(tokens[index].key)
                && (index + 1 == tokens.count || tokens[index + 1].key == " ")
        }
    }

    private static func meaningful(_ tokens: [Token]) -> Bool {
        tokens.contains { token in
            token.literal || token.image || token.visible.rangeOfCharacter(from: .alphanumerics.union(.symbols)) != nil
                || token.visible.rangeOfCharacter(from: CharacterSet(charactersIn: "%‰‱")) != nil
        }
    }

    private static func initialCapitalizationOnly(_ old: [Token], _ new: [Token]) -> Bool {
        guard !old.contains(where: { $0.literal || $0.image }), !new.contains(where: { $0.literal || $0.image }) else { return false }
        let before = old.filter { $0.key != " " }, after = new.filter { $0.key != " " }
        guard before.count == 1,
              let replacement = after.first(where: { $0.visible.lowercased() == before[0].visible.lowercased() }) else { return false }
        let a = before[0].visible, b = replacement.visible
        func initialCapital(_ word: String) -> Bool {
            guard let first = word.first, word.count > 1 else { return false }
            let initial = String(first)
            return initial != initial.lowercased() && String(word.dropFirst()) == String(word.dropFirst()).lowercased()
        }
        // Keep acronym and code identifier changes; ordinary sentence-initial
        // capitalization already has a yellow highlight on the current word.
        return a != b && a.lowercased() == b.lowercased()
            && ((initialCapital(a) && b == b.lowercased()) || (initialCapital(b) && a == a.lowercased()))
    }

    private static func add(_ unit: Unit, changes: inout RevisionDecorations, reviews: inout [RevisionReviewMatch]) {
        guard unit.tokens.contains(where: { meaningful([$0]) }) else { return }
        for token in unit.tokens { mark(token, includeSpacing: true, changes: &changes) }
        reviews.append(RevisionReviewMatch(earlier: nil, current: unit, anchor: unit.range.location))
    }
    private static func mark(_ token: Token, includeSpacing: Bool = false, changes: inout RevisionDecorations) {
        if token.image { changes.images.append(token.range) }
        else if includeSpacing || (token.literal && !token.visible.contains("\n")) || (!token.whitespace && meaningful([token])) {
            changes.highlights.append(token.range)
        }
    }
    /// Classify against the original unit, before whitespace and block boundaries
    /// are flattened. Broad rewrite excerpts may contain surviving words, so
    /// counts use only exact deletion ranges, independently of their excerpt.
    private static func removalSummary(in unit: Unit, ranges: [Range<Int>]) -> RevisionDeletion.Summary? {
        let deleted = Set(ranges.flatMap { $0 }.filter { meaningful([unit.tokens[$0]]) && !unit.tokens[$0].image })
        guard !deleted.isEmpty, !deleted.contains(where: { unit.tokens[$0].literal }) else { return nil }
        let wordCount = deleted.filter { unit.tokens[$0].word }.count
        let words: RevisionDeletion.Summary? = wordCount > 12 ? .words(wordCount) : nil
        guard ["paragraph", "cell"].contains(unit.kind.components(separatedBy: ":").first ?? "") else { return words }

        var offset = 0
        let tokenRanges = unit.tokens.map { token -> NSRange in
            defer { offset += token.visible.utf16.count }
            return NSRange(location: offset, length: token.visible.utf16.count)
        }
        let text = unit.tokens.map(\.visible).joined()
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var covered = Set<Int>(), sentenceCount = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentenceRange = NSRange(range, in: text)
            let indices = Set(unit.tokens.indices.filter {
                NSIntersectionRange(tokenRanges[$0], sentenceRange).length > 0 && meaningful([unit.tokens[$0]]) && !unit.tokens[$0].image
            })
            // Terminal punctuation distinguishes a complete sentence from a
            // trailing fragment. Native sentence boundaries handle abbreviations.
            let ending = text[range].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'’”»)]}」』")))
            if !indices.isEmpty, indices.isSubset(of: deleted),
               ending.last.map({ ".!?。！？".contains($0) }) == true {
                covered.formUnion(indices)
                sentenceCount += 1
            }
            return true
        }
        return sentenceCount > 0 && covered == deleted ? .sentences(sentenceCount) : words
    }

    private static func remove(_ tokens: [Token], at location: Int, summary: RevisionDeletion.Summary? = nil,
                               changes: inout RevisionDecorations) {
        let words = tokens.filter { !$0.image }.map(\.visible).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !words.isEmpty && meaningful(tokens.filter { !$0.image }) {
            changes.deletions.append(RevisionDeletion(location: location, text: words, summary: summary))
        }
        if tokens.contains(where: \.image) { changes.deletions.append(RevisionDeletion(location: location, text: "", isImage: true)) }
    }
    private static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location { result[result.count - 1] = NSUnionRange(last, range) }
            else { result.append(range) }
        }
        return result
    }
    private static func coalesce(_ notes: [RevisionDeletion]) -> [RevisionDeletion] {
        var result: [RevisionDeletion] = []
        for note in notes.sorted(by: { $0.location < $1.location }) {
            if let summary = note.summary, let index = result.lastIndex(where: {
                $0.location == note.location && $0.isImage == note.isImage && $0.summary?.combined(with: summary) != nil
            }), let combined = result[index].summary?.combined(with: summary) {
                let previous = result[index]
                result[index] = RevisionDeletion(location: note.location, text: previous.text + " " + note.text,
                                                 isImage: note.isImage, summary: combined)
                continue
            }
            if let last = result.last, last.location == note.location, last.isImage == note.isImage,
               last.summary == nil && note.summary == nil {
                result[result.count - 1] = RevisionDeletion(location: note.location,
                    text: last.isImage ? "" : last.text + " " + note.text, isImage: note.isImage)
            } else { result.append(note) }
        }
        return result
    }
}
#endif

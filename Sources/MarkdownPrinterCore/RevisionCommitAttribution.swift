#if canImport(AppKit)
import AppKit

/// Follows semantic passages through successive versions, including deleted
/// passages. Indices refer to the transition into documents[index + 1].
/// Historical images are represented by references; they are never opened.
public enum RevisionCommitAttribution {
    private struct Track {
        let range: NSRange
        var origins: Set<Int>
        var commits: Set<Int>
    }

    public static func contributions(in documents: [MarkdownDocument]) throws -> [String: Set<Int>] {
        guard let first = documents.first, documents.count > 1 else { return [:] }
        let renderer = MarkdownRenderer(tracksRevisions: true, imageReferencesOnly: true)
        let baseline = renderer.render(document: first)
        let originalUnits = RevisionFormatter.units(in: baseline)
        var previous = baseline
        var tracks = originalUnits.enumerated().map { Track(range: $0.element.range, origins: [$0.offset], commits: []) }
        var deleted: [Int: Set<Int>] = [:]
        for (index, document) in documents.dropFirst().enumerated() {
            try Task.checkCancellation()
            let current = renderer.render(document: document)
            let currentUnits = RevisionFormatter.units(in: current)
            let changed = RevisionFormatter.format(current: current, original: previous).reviewItems
            var next: [Track] = []
            let groups = RevisionStructure.matches(old: RevisionFormatter.units(in: previous), new: currentUnits, original: previous, current: current)
            for group in groups {
                let oldRange = group.review.earlier?.range, newRange = group.review.current?.range
                let inherited = tracks.filter { track in oldRange.map { overlaps($0, track.range) } ?? false }
                let origins = Set(inherited.flatMap(\.origins))
                var commits = Set(inherited.flatMap(\.commits))
                let edited = changed.contains { item in
                    newRange.map { overlaps($0, item.currentRange) } == true
                        || oldRange.flatMap { old in item.earlierRange.map { overlaps(old, $0) } } == true
                }
                if edited { commits.insert(index) }
                if let newRange {
                    // Split a row/structure into its native units so subsequent
                    // unrelated insertions cannot expand its tracked boundary.
                    for unit in currentUnits where overlaps(newRange, unit.range) {
                        next.append(Track(range: unit.range, origins: origins, commits: commits))
                    }
                } else {
                    for origin in origins { deleted[origin, default: []].formUnion(commits) }
                }
            }
            tracks = next
            previous = current
        }
        let finalItems = RevisionFormatter.format(current: previous, original: baseline).reviewItems
        return Dictionary(uniqueKeysWithValues: finalItems.map { item in
            var commits = Set(tracks.filter { overlaps($0.range, item.currentRange) }.flatMap(\.commits))
            if let earlier = item.earlierRange {
                for (origin, unit) in originalUnits.enumerated() where overlaps(earlier, unit.range) {
                    commits.formUnion(deleted[origin] ?? [])
                }
            }
            return (item.id, commits)
        })
    }

    private static func overlaps(_ first: NSRange, _ second: NSRange) -> Bool {
        first.length > 0 && second.length > 0 && NSIntersectionRange(first, second).length > 0
    }
}
#endif

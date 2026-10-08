import AppKit
import MarkdownPrinterCore

package enum DocumentSidebarMode: String { case pages, changes }

package struct PersistedDocumentSidebar: Equatable {
    var mode: DocumentSidebarMode = .pages
    var isVisible = false
    var pagesWidth: Double = 168
    var changesWidth: Double = 340
    var listProportion: Double = 0.55
    var collapsedGroups: Set<String> = []
    var selectedID: String?
    var listOffset: Double = 0
    var detailOffset: Double = 0

    var propertyList: [String: Any] {
        var value: [String: Any] = ["mode": mode.rawValue, "isVisible": isVisible,
            "pagesWidth": pagesWidth, "changesWidth": changesWidth, "listProportion": listProportion,
            "collapsedGroups": collapsedGroups.sorted(), "listOffset": listOffset, "detailOffset": detailOffset]
        if let selectedID { value["selectedID"] = selectedID }
        return value
    }

    init() {}
    init?(propertyList: [String: Any]) {
        guard let mode = (propertyList["mode"] as? String).flatMap(DocumentSidebarMode.init(rawValue:)),
              let visible = propertyList["isVisible"] as? Bool,
              let pages = propertyList["pagesWidth"] as? Double, pages.isFinite,
              let changes = propertyList["changesWidth"] as? Double, changes.isFinite,
              let proportion = propertyList["listProportion"] as? Double, proportion.isFinite,
              let list = propertyList["listOffset"] as? Double, list.isFinite,
              let detail = propertyList["detailOffset"] as? Double, detail.isFinite else { return nil }
        self.mode = mode; isVisible = visible
        pagesWidth = min(260, max(120, pages)); changesWidth = min(520, max(240, changes))
        listProportion = min(0.9, max(0.1, proportion))
        listOffset = max(0, list); detailOffset = max(0, detail)
        collapsedGroups = Set(propertyList["collapsedGroups"] as? [String] ?? [])
        selectedID = propertyList["selectedID"] as? String
    }
}

@MainActor
package final class RevisionReviewController {
    private(set) var items: [RevisionReviewItem] = []
    private(set) var destinations: [String: PDFReviewDestination] = [:]
    private(set) var baseline: OriginalDocumentSnapshot?
    private(set) var revision: UInt64 = 0
    var state = PersistedDocumentSidebar()
    private(set) var restorationPending = false
    var navigate: (String, UInt64, PDFReviewDestination) -> Void = { _, _, _ in }
    var selectionDidChange: () -> Void = {}

    var selectedIndex: Int? { items.firstIndex { $0.id == state.selectedID } }
    var selectedItem: RevisionReviewItem? { selectedIndex.map { items[$0] } }
    var canPrevious: Bool { (selectedIndex ?? 0) > 0 }
    var canNext: Bool { selectedIndex.map { $0 + 1 < items.count } ?? false }
    var selectionLabel: String { selectedIndex.map { "Change \($0 + 1) of \(items.count)" } ?? "No meaningful document changes" }
    var baselineLabel: String {
        guard let baseline else { return "" }
        let identity = baseline.gitRevision.map { String($0.prefix(8)) } ?? baseline.sourceURL?.lastPathComponent ?? baseline.title
        guard let date = baseline.sourceModificationDate else { return identity }
        return identity + " · " + DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    func restore(_ state: PersistedDocumentSidebar) {
        self.state = state
        restorationPending = true
    }

    func update(_ snapshot: RenderedDocumentSnapshot) {
        let previousBaseline = baseline?.id
        let previousItem = selectedItem
        items = snapshot.reviewItems; destinations = snapshot.reviewDestinations
        baseline = snapshot.baseline; revision = snapshot.revision
        if baseline == nil { state.mode = .pages }
        else if !restorationPending, baseline?.id != previousBaseline {
            state.mode = .changes; state.isVisible = true
            state.selectedID = items.first?.id; state.listOffset = 0; state.detailOffset = 0
            state.collapsedGroups = []
        }
        if !items.contains(where: { $0.id == state.selectedID }) {
            let anchor = previousItem?.anchor ?? 0
            state.selectedID = items.min { abs($0.anchor - anchor) < abs($1.anchor - anchor) }?.id
        }
        if previousItem?.id != state.selectedID, !restorationPending { state.detailOffset = 0 }
        state.collapsedGroups.formIntersection(Set(items.map(\.sectionID)))
        restorationPending = false
    }

    func select(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        state.selectedID = id; state.detailOffset = 0
        state.collapsedGroups.remove(item.sectionID)
        selectionDidChange()
        if let destination = destinations[id] { navigate(id, revision, destination) }
    }

    func previous() { if let index = selectedIndex, index > 0 { select(items[index - 1].id) } }
    func next() { if let index = selectedIndex, index + 1 < items.count { select(items[index + 1].id) } }
}

package enum RevisionReviewDetail {
    static func text(for item: RevisionReviewItem) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let prose = NSFont(name: "AvenirNext-Regular", size: 13) ?? .systemFont(ofSize: 13)
        let bold = NSFont(name: "AvenirNext-DemiBold", size: 13) ?? .boldSystemFont(ofSize: 13)
        let body = item.isCode ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : prose
        let style = NSMutableParagraphStyle(); style.paragraphSpacing = 10
        for (title, passage, ranges, earlier) in [("Earlier", item.earlier, item.removedRanges, true), ("Current", item.current, item.addedRanges, false)] {
            result.append(NSAttributedString(string: title + "\n", attributes: [.font: bold, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
            var text = passage ?? (earlier ? "No earlier passage—added here." : "This passage was removed.")
            if !item.isCode { while text.hasSuffix("\n") { text.removeLast() } }
            let start = result.length
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
            if item.kind == .removed, earlier {
                result.addAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.09), range: NSRange(location: start, length: (text as NSString).length))
            } else {
                for originalRange in ranges {
                    let range = NSIntersectionRange(originalRange, NSRange(location: 0, length: (text as NSString).length))
                    guard range.length > 0 else { continue }
                    let target = NSRange(location: start + range.location, length: range.length)
                    if earlier { result.addAttributes([.foregroundColor: NSColor.systemRed, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: target) }
                    else { result.addAttributes([.backgroundColor: RevisionFormatter.highlightColor, .foregroundColor: NSColor.black], range: target) }
                }
            }
        }
        for entry in item.metadata { result.append(NSAttributedString(string: entry + "\n", attributes: [.font: prose, .foregroundColor: NSColor.secondaryLabelColor])) }
        return result
    }
}

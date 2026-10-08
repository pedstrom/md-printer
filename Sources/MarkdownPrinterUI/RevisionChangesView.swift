import AppKit
import MarkdownPrinterCore

final class ReviewSplitView: NSSplitView { override var isFlipped: Bool { true } }
private final class ReviewPane: NSView { override var isFlipped: Bool { true } }

@MainActor
final class RevisionChangesView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate {
    final class Group: NSObject {
        let id: String, title: String
        var items: [Entry] = []
        init(_ item: RevisionReviewItem) { id = item.sectionID; title = item.sectionTitle }
    }
    final class Entry: NSObject {
        let value: RevisionReviewItem
        init(_ value: RevisionReviewItem) { self.value = value }
    }

    let controller: RevisionReviewController
    let outline = ReviewOutlineView()
    let listScroll = NSScrollView()
    let detailScroll = NSScrollView()
    let detailText = ReviewDetailTextView()
    let split = ReviewSplitView()
    private let detailPane = ReviewPane()
    private let baselineLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let previousButton = ReviewNavigationButton()
    private let nextButton = ReviewNavigationButton()
    private var groups: [Group] = []
    private var entries: [String: Entry] = [:]
    private var updating = false
    private var displayedID: String?
    private var selectionFocusPending = false

    override var isFlipped: Bool { true }
    init(controller: RevisionReviewController) {
        self.controller = controller
        super.init(frame: .zero)
        outline.navigateArrow = { [weak self] in self?.navigateArrow($0) ?? false }
        detailText.navigateArrow = { [weak self] in self?.navigateArrow($0) ?? false }
        previousButton.navigateArrow = { [weak self] in self?.navigateArrow($0) ?? false }
        nextButton.navigateArrow = { [weak self] in self?.navigateArrow($0) ?? false }
        baselineLabel.font = .systemFont(ofSize: 11); baselineLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        selectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        contextLabel.font = .systemFont(ofSize: 11); contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle
        for view in [baselineLabel, countLabel, split] as [NSView] { addSubview(view) }
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("change")))
        outline.outlineTableColumn = outline.tableColumns.first
        outline.headerView = nil; outline.dataSource = self; outline.delegate = self
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 12; outline.allowsEmptySelection = true
        outline.setAccessibilityLabel("Document changes")
        listScroll.documentView = outline; listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        detailScroll.documentView = detailText; detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailText.isEditable = false; detailText.isSelectable = true; detailText.drawsBackground = false
        detailText.isVerticallyResizable = true; detailText.isHorizontallyResizable = false
        detailText.autoresizingMask = [.width]; detailText.textContainerInset = NSSize(width: 10, height: 8)
        detailText.textContainer?.widthTracksTextView = true
        detailText.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        detailText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detailText.setAccessibilityLabel("Earlier and current passages")
        for view in [selectionLabel, contextLabel, previousButton, nextButton, detailScroll] as [NSView] { detailPane.addSubview(view) }
        for (button, symbol, label, action) in [(previousButton, "chevron.left", "Previous change", #selector(previous)),
                                               (nextButton, "chevron.right", "Next change", #selector(next))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .rounded; button.setAccessibilityLabel(label)
            button.target = self; button.action = action
        }
        split.isVertical = false; split.dividerStyle = .thin; split.delegate = self
        split.addArrangedSubview(listScroll); split.addArrangedSubview(detailPane)
    }
    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndSheetNotification, object: nil)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowReadyForSelectionFocus), name: name, object: window)
            }
        }
        applySelectionFocus()
    }

    func requestSelectionFocus() {
        guard controller.selectedItem != nil else { selectionFocusPending = false; return }
        selectionFocusPending = true
        applySelectionFocus()
        DispatchQueue.main.async { [weak self] in self?.applySelectionFocus() }
    }

    func cancelSelectionFocus() { selectionFocusPending = false }

    @objc private func windowReadyForSelectionFocus(_ notification: Notification) {
        applySelectionFocus()
        // A completed comparison sheet can notify before its window has fully detached.
        DispatchQueue.main.async { [weak self] in self?.applySelectionFocus() }
    }

    private func applySelectionFocus() {
        guard selectionFocusPending, !isHiddenOrHasHiddenAncestor,
              let window, window.attachedSheet == nil,
              let item = controller.selectedItem, let entry = entries[item.id] else { return }
        selectionFocusPending = false
        updating = true
        if let group = groups.first(where: { $0.id == item.sectionID }) {
            outline.expandItem(group)
            controller.state.collapsedGroups.remove(group.id)
        }
        let row = outline.row(forItem: entry)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        updating = false
        if row < 0 || !window.makeFirstResponder(outline) { selectionFocusPending = true }
    }

    override func layout() {
        updating = true
        super.layout()
        baselineLabel.frame = NSRect(x: 10, y: 5, width: max(0, bounds.width - 20), height: 38)
        countLabel.frame = NSRect(x: 10, y: 47, width: max(0, bounds.width - 20), height: 18)
        split.frame = NSRect(x: 0, y: 72, width: bounds.width, height: max(0, bounds.height - 72))
        split.setPosition(listHeight, ofDividerAt: 0)
        updating = false
        outline.setFrameSize(NSSize(width: listScroll.contentSize.width, height: outline.frame.height))
        outline.tableColumns.first?.width = max(20, listScroll.contentSize.width - 20)
        layoutDetail()
        applySelectionFocus()
    }

    var listHeight: CGFloat { min(max(120, split.bounds.height * controller.state.listProportion), max(120, split.bounds.height - 180)) }

    private func layoutDetail() {
        let width = detailPane.bounds.width
        selectionLabel.frame = NSRect(x: 10, y: 8, width: max(0, width - 84), height: 18)
        contextLabel.frame = NSRect(x: 10, y: 31, width: max(0, width - 20), height: 18)
        previousButton.frame = NSRect(x: max(0, width - 74), y: 5, width: 30, height: 28)
        nextButton.frame = NSRect(x: max(0, width - 40), y: 5, width: 30, height: 28)
        detailScroll.frame = NSRect(x: 0, y: 58, width: width, height: max(0, detailPane.bounds.height - 58))
        detailText.setFrameSize(NSSize(width: detailScroll.contentSize.width, height: max(detailScroll.contentSize.height, detailText.frame.height)))
        if let container = detailText.textContainer, let layout = detailText.layoutManager {
            layout.ensureLayout(for: container)
            detailText.setFrameSize(NSSize(width: detailScroll.contentSize.width, height: max(detailScroll.contentSize.height, layout.usedRect(for: container).height + 20)))
        }
    }

    func captureScrollPositions() {
        controller.state.listOffset = Double(max(0, listScroll.contentView.bounds.minY))
        controller.state.detailOffset = Double(max(0, detailScroll.contentView.bounds.minY))
    }

    func refresh() {
        updating = true
        groups = []; entries = [:]
        var byID: [String: Group] = [:]
        for value in controller.items {
            let group: Group
            if let existing = byID[value.sectionID] { group = existing }
            else { group = Group(value); groups.append(group); byID[value.sectionID] = group }
            let entry = Entry(value); group.items.append(entry); entries[value.id] = entry
        }
        outline.reloadData()
        for group in groups where !controller.state.collapsedGroups.contains(group.id) { outline.expandItem(group) }
        if let id = controller.state.selectedID, let entry = entries[id] {
            let row = outline.row(forItem: entry)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        }
        baselineLabel.stringValue = "Compared with\n" + controller.baselineLabel
        countLabel.stringValue = "\(controller.items.count) change\(controller.items.count == 1 ? "" : "s")"
        updating = false
        showDetail()
        needsLayout = true; layoutSubtreeIfNeeded()
        restoreScroll(listScroll, offset: controller.state.listOffset)
        restoreScroll(detailScroll, offset: controller.state.detailOffset)
    }

    private func restoreScroll(_ scroll: NSScrollView, offset: Double) {
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(offset), maximum)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func showDetail(force: Bool = false) {
        selectionLabel.stringValue = controller.selectionLabel
        contextLabel.stringValue = controller.selectedItem.map { item in
            item.sectionTitle + (controller.destinations[item.id].map { " · " + $0.pageLabel } ?? "")
        } ?? ""
        previousButton.isEnabled = controller.canPrevious; nextButton.isEnabled = controller.canNext
        if force || displayedID != controller.selectedItem?.id || detailText.string.isEmpty {
            displayedID = controller.selectedItem?.id
            detailText.textStorage?.setAttributedString(controller.selectedItem.map(RevisionReviewDetail.text(for:))
                ?? NSAttributedString(string: "No meaningful document changes.", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
            layoutDetail()
        }
    }

    private func showSelection() {
        updating = true
        if let item = controller.selectedItem, let group = groups.first(where: { $0.id == item.sectionID }), let entry = entries[item.id] {
            outline.expandItem(group)
            let row = outline.row(forItem: entry)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) }
        }
        updating = false
        showDetail(force: true); restoreScroll(detailScroll, offset: 0)
    }
    @objc private func previous() { guard controller.canPrevious else { return }; controller.previous(); showSelection() }
    @objc private func next() { guard controller.canNext else { return }; controller.next(); showSelection() }

    private func navigateArrow(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 123, 126: previous()
        case 124, 125: next()
        default: return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !navigateArrow(event) { super.keyDown(with: event) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Group)?.items.count ?? groups.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let group = item as? Group { return group.items[index] }; return groups[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Group }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is Entry }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is Group ? 30 : 50 }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        if let group = item as? Group { label.stringValue = "\(group.title)  (\(group.items.count))"; label.font = .systemFont(ofSize: 12, weight: .semibold) }
        else if let entry = item as? Entry {
            label.stringValue = entry.value.kind.rawValue + (controller.destinations[entry.value.id].map { " · " + $0.pageLabel } ?? "") + "\n" + entry.value.excerpt
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label); cell.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating, let entry = outline.item(atRow: outline.selectedRow) as? Entry else { return }
        controller.select(entry.value.id); showDetail(force: true); restoreScroll(detailScroll, offset: 0)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !updating, let group = notification.userInfo?["NSObject"] as? Group { controller.state.collapsedGroups.insert(group.id) }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if !updating, let group = notification.userInfo?["NSObject"] as? Group { controller.state.collapsedGroups.remove(group.id) }
    }
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(max(120, proposedPosition), max(120, splitView.bounds.height - 180))
    }
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.insetBy(dx: 0, dy: -6)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !updating, NSApp.currentEvent?.type == .leftMouseDragged, split.bounds.height > 0 { controller.state.listProportion = Double(listScroll.frame.height / split.bounds.height) }
        layoutDetail()
    }
}

@MainActor
final class ReviewOutlineView: NSOutlineView {
    var navigateArrow: (NSEvent) -> Bool = { _ in false }
    override func keyDown(with event: NSEvent) {
        if !navigateArrow(event) { super.keyDown(with: event) }
    }
}

@MainActor
final class ReviewDetailTextView: NSTextView {
    var navigateArrow: (NSEvent) -> Bool = { _ in false }
    override func keyDown(with event: NSEvent) {
        if !navigateArrow(event) { super.keyDown(with: event) }
    }
}

@MainActor
final class ReviewNavigationButton: NSButton {
    var navigateArrow: (NSEvent) -> Bool = { _ in false }
    override func keyDown(with event: NSEvent) {
        if !navigateArrow(event) { super.keyDown(with: event) }
    }
}

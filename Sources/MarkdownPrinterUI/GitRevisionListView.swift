import AppKit
import SwiftUI

/// AppKit owns both selection and double-click dispatch, with no competing row gestures.
struct GitRevisionListView: NSViewRepresentable {
    @ObservedObject var controller: GitRevisionPickerController

    func makeNSView(context: Context) -> GitRevisionList { GitRevisionList(controller: controller) }
    func updateNSView(_ view: GitRevisionList, context: Context) { view.updateSelection() }
}

@MainActor
final class GitRevisionList: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let controller: GitRevisionPickerController
    private var updating = false

    init(controller: GitRevisionPickerController) {
        self.controller = controller
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("revision")))
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        table.rowHeight = 60
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(compareClickedRevision)
        table.setAccessibilityIdentifier("git-revision-list")
        table.setAccessibilityLabel("Git document versions")
        documentView = table
        updating = true
        table.reloadData()
        updateSelection()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The list arrives after asynchronous history loading. Focus it after
        // SwiftUI finishes attaching the sheet's native views.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.table)
        }
    }

    func updateSelection() {
        updating = true
        defer { updating = false }
        table.isEnabled = !controller.isComparing
        let row = controller.revisions.firstIndex { $0.id == controller.selectedRevisionID }
        if let row, row != table.selectedRow {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { controller.revisions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let revision = controller.revisions[row]
        let date = revision.committerDate.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        return GitRevisionCell(date: date, commitID: revision.abbreviatedID, subject: revision.subject)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !controller.isComparing }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, !controller.isComparing,
              controller.revisions.indices.contains(table.selectedRow) else { return }
        controller.selectedRevisionID = controller.revisions[table.selectedRow].id
    }

    @objc private func compareClickedRevision() {
        guard controller.revisions.indices.contains(table.clickedRow) else { return }
        controller.compare(revisionID: controller.revisions[table.clickedRow].id)
    }
}

@MainActor
final class GitRevisionCell: NSTableCellView {
    let dateLabel: NSTextField
    let commitLabel: NSTextField
    let subjectLabel: NSTextField

    init(date: String, commitID: String, subject: String) {
        dateLabel = NSTextField(labelWithString: date)
        commitLabel = NSTextField(labelWithString: commitID)
        subjectLabel = NSTextField(wrappingLabelWithString: subject)
        super.init(frame: .zero)
        commitLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        subjectLabel.maximumNumberOfLines = 2
        subjectLabel.lineBreakMode = .byTruncatingTail
        textField = subjectLabel
        for label in [dateLabel, commitLabel, subjectLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            dateLabel.trailingAnchor.constraint(lessThanOrEqualTo: commitLabel.leadingAnchor, constant: -8),
            commitLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            commitLabel.firstBaselineAnchor.constraint(equalTo: dateLabel.firstBaselineAnchor),
            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            subjectLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 4)
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        dateLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        subjectLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        commitLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

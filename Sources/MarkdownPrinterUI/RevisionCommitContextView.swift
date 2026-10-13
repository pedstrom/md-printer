import AppKit

@MainActor
final class RevisionCommitContextView: NSView {
    private let heading = NSTextField(wrappingLabelWithString: "")
    private var rows: [CommitRow] = []
    private var expanded = Set<String>()
    private var seen = Set<String>()
    var sizeDidChange: () -> Void = {}
    var navigateArrow: (NSEvent) -> Bool = { _ in false }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 8
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(heading)
        setAccessibilityLabel("Contributing commit descriptions")
    }
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }

    func configure(status: RevisionReviewController.CommitContextStatus, commits: [GitCommitDescription], uncommitted: Bool) {
        for row in rows { row.removeFromSuperview() }
        rows = []
        isHidden = status == .hidden
        guard !isHidden else { return }
        let message: String?
        switch status {
        case .hidden: return
        case .loading: heading.stringValue = "Commit descriptions"; message = "Loading commit descriptions…"
        case .unavailable: heading.stringValue = "Commit descriptions"; message = "Local commit descriptions are unavailable."
        case .ready:
            heading.stringValue = commits.isEmpty ? "Commit description" : (commits.count == 1 ? "Contributing commit" : "Contributing commits (\(commits.count))")
            message = commits.isEmpty ? (uncommitted ? "Uncommitted changes" : "No contributing commits found.") : nil
        }
        for (index, commit) in commits.enumerated() {
            if index == 0, !seen.contains(commit.id), !commit.body.isEmpty { expanded.insert(commit.id) }
            seen.insert(commit.id)
            let row = CommitRow(commit: commit, expanded: expanded.contains(commit.id))
            row.disclosure.navigateArrow = navigateArrow
            row.toggle = { [weak self, weak row] in
                guard let self, let row else { return }
                if self.expanded.contains(commit.id) { self.expanded.remove(commit.id) }
                else { self.expanded.insert(commit.id) }
                row.isExpanded = self.expanded.contains(commit.id)
                self.sizeDidChange()
            }
            rows.append(row); addSubview(row)
        }
        if let message {
            let row = CommitRow(message: message); rows.append(row); addSubview(row)
        } else if uncommitted {
            let row = CommitRow(message: "Includes uncommitted edits."); rows.append(row); addSubview(row)
        }
    }

    func contentHeight(width: CGFloat) -> CGFloat {
        guard !isHidden else { return 0 }
        let available = max(20, width - 20)
        let titleHeight = Self.height(heading, width: available)
        heading.frame = NSRect(x: 10, y: 10, width: available, height: titleHeight)
        var y = 10 + titleHeight
        for row in rows {
            y += 8
            let height = row.contentHeight(width: available)
            row.frame = NSRect(x: 10, y: y, width: available, height: height)
            y += height
        }
        return y + 10
    }

    fileprivate static func height(_ label: NSTextField, width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 16)
    }

    private final class CommitRow: NSView {
        let title = NSTextField(wrappingLabelWithString: "")
        let body = NSTextField(wrappingLabelWithString: "")
        let disclosure = ReviewNavigationButton()
        var toggle: () -> Void = {}
        var isExpanded = false
        override var isFlipped: Bool { true }

        init(commit: GitCommitDescription, expanded: Bool) {
            super.init(frame: .zero)
            isExpanded = expanded
            let subject = commit.subject.isEmpty ? "Untitled commit" : commit.subject
            let date = DateFormatter.localizedString(from: commit.date, dateStyle: .medium, timeStyle: .none)
            let text = NSMutableAttributedString(string: subject + " — " + date,
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
            text.addAttributes([.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor],
                range: NSRange(location: (subject as NSString).length, length: (" — " + date as NSString).length))
            title.attributedStringValue = text
            body.stringValue = commit.body; body.font = .systemFont(ofSize: 12)
            disclosure.bezelStyle = .disclosure; disclosure.setButtonType(.pushOnPushOff)
            disclosure.title = ""; disclosure.target = self; disclosure.action = #selector(toggled)
            disclosure.isHidden = commit.body.isEmpty
            disclosure.setAccessibilityLabel("Expand or collapse \(subject)")
            for view in [title, body, disclosure] as [NSView] { addSubview(view) }
        }

        init(message: String) {
            super.init(frame: .zero)
            title.stringValue = message; title.font = .systemFont(ofSize: 12); title.textColor = .secondaryLabelColor
            disclosure.isHidden = true
            for view in [title, body, disclosure] as [NSView] { addSubview(view) }
        }
        required init?(coder: NSCoder) { nil }
        @objc private func toggled() { toggle() }

        func contentHeight(width: CGFloat) -> CGFloat {
            let indent: CGFloat = disclosure.isHidden ? 0 : 15
            let titleHeight = RevisionCommitContextView.height(title, width: max(20, width - indent))
            title.frame = NSRect(x: indent, y: 0, width: max(20, width - indent), height: titleHeight)
            disclosure.frame = NSRect(x: 0, y: 0, width: 12, height: 16)
            disclosure.state = isExpanded ? .on : .off
            body.isHidden = !isExpanded || body.stringValue.isEmpty
            guard !body.isHidden else { return titleHeight }
            let bodyHeight = RevisionCommitContextView.height(body, width: width)
            body.frame = NSRect(x: 0, y: titleHeight + 6, width: width, height: bodyHeight)
            return titleHeight + 6 + bodyHeight
        }
    }
}

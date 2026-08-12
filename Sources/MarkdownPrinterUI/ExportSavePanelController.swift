import AppKit
import MarkdownPrinterCore

struct ExportSaveSelection: Equatable {
    let url: URL
    let format: ExportFormat
}

@MainActor
final class ExportSavePanelController: NSObject {
    private(set) var selectedFormat: ExportFormat
    let panel: NSSavePanel

    private let formatPicker = NSPopUpButton(frame: .zero, pullsDown: false)

    init(
        defaultFormat: ExportFormat,
        suggestedFileName: String,
        panel: NSSavePanel? = nil
    ) {
        selectedFormat = defaultFormat
        self.panel = panel ?? NSSavePanel()
        super.init()

        self.panel.title = "Save Document"
        self.panel.prompt = "Save"
        self.panel.isExtensionHidden = false
        self.panel.canSelectHiddenExtension = true
        self.panel.nameFieldStringValue = suggestedFileName

        formatPicker.addItems(withTitles: ExportFormat.allCases.map(\.displayName))
        formatPicker.selectItem(at: Self.index(of: defaultFormat))
        formatPicker.target = self
        formatPicker.action = #selector(formatChanged(_:))
        self.panel.accessoryView = makeAccessoryView()

        apply(defaultFormat, updatePicker: false)
    }

    func runModal() -> ExportSaveSelection? {
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ExportSaveSelection(url: url, format: selectedFormat)
    }

    func select(_ format: ExportFormat) {
        apply(format, updatePicker: true)
    }

    @objc
    private func formatChanged(_ sender: NSPopUpButton) {
        let formats = ExportFormat.allCases
        guard formats.indices.contains(sender.indexOfSelectedItem) else { return }
        apply(formats[sender.indexOfSelectedItem], updatePicker: false)
    }

    private func apply(_ format: ExportFormat, updatePicker: Bool) {
        selectedFormat = format
        if updatePicker {
            formatPicker.selectItem(at: Self.index(of: format))
        }
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = Self.replacingExportExtension(
            in: panel.nameFieldStringValue,
            with: format
        )
    }

    private func makeAccessoryView() -> NSView {
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, formatPicker])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private static func replacingExportExtension(
        in fileName: String,
        with format: ExportFormat
    ) -> String {
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonemptyName = trimmedName.isEmpty ? "Untitled" : trimmedName
        let lowercasedName = nonemptyName.lowercased()
        let existingFormat = ExportFormat.allCases.first {
            lowercasedName.hasSuffix(".\($0.pathExtension)")
        }
        let baseName = existingFormat == nil
            ? nonemptyName
            : (nonemptyName as NSString).deletingPathExtension
        return "\(baseName).\(format.pathExtension)"
    }

    private static func index(of format: ExportFormat) -> Int {
        ExportFormat.allCases.firstIndex(of: format) ?? 0
    }
}

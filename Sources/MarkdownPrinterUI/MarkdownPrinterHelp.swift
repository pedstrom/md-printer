import Combine

package enum MarkdownPrinterHelpDestination: String, CaseIterable, Equatable {
    case overview
    case shortcuts

    package var sectionID: MarkdownPrinterHelpSection.ID {
        switch self {
        case .overview: .overview
        case .shortcuts: .keyboardShortcuts
        }
    }
}

package struct MarkdownPrinterHelpSection: Identifiable, Equatable {
    package enum ID: String, CaseIterable {
        case overview
        case openingFiles
        case exporting
        case preview
        case search
        case thumbnails
        case windowsAndTabs
        case pageSetupAndPrinting
        case finderAndQuickLook
        case imagesAndPrivacy
        case keyboardShortcuts
    }

    package let id: ID
    package let title: String
    package let paragraphs: [String]
}

package struct MarkdownPrinterHelpShortcut: Identifiable, Equatable {
    package let action: String
    package let keys: String
    package let spokenKeys: String

    package var id: String { action }
    package var accessibilityLabel: String { "\(action): \(spokenKeys)" }
}

package enum MarkdownPrinterHelpContent {
    package static let sections: [MarkdownPrinterHelpSection] = [
        section(
            .overview,
            "Overview",
            "Markdown Printer turns Markdown files into polished PDF or editable Microsoft Word documents. The preview is read-only and uses the same generated PDF as saving and printing.",
            "Document content stays on this Mac. Markdown Printer does not upload documents, require an account, or use analytics. Remote images are fetched only after you choose to download them."
        ),
        section(
            .openingFiles,
            "Open Markdown Files",
            "Choose File → Open, drag Markdown files onto the welcome window, or open a supported file from Finder. Each file opens in its own document window or tab.",
            "When another app saves the source file, Markdown Printer refreshes the preview and keeps the current viewport whenever possible."
        ),
        section(
            .exporting,
            "Save, Share, and Drag Exports",
            "The preferred export format in Settings controls Save, Share, and dragging a document from the preview. PDF and Microsoft Word exports use the same page setup and footer choices.",
            "Use the Save toolbar button or File → Save As to choose a destination. Use the Share toolbar button or File → Share PDF/Share Microsoft Word to open the macOS Share sheet. Drag from the preview to place an exported file in Finder or another accepting app.",
            "Hold Option when dragging from the preview or clicking Share to use the other format for that action: PDF becomes Microsoft Word, and Microsoft Word becomes PDF. Your default format in Settings stays unchanged."
        ),
        section(
            .preview,
            "Navigate and Zoom the Preview",
            "Use View → Previous Page and Next Page, Option-arrow keys, or Space and Shift-Space to move one page at a time. Page commands disable automatically at the beginning and end of the document.",
            "Use Actual Size, Zoom to Fit, Zoom In, and Zoom Out from the View menu. Zoom commands disable at PDFKit’s minimum and maximum scale."
        ),
        section(
            .search,
            "Search",
            "Choose Edit → Find → Find to search selectable PDF text. Find Next and Find Previous wrap through the results. Press Escape to close the search panel while keeping the current result selected."
        ),
        section(
            .thumbnails,
            "Thumbnails",
            "Choose View → Show Thumbnails or use the sidebar button beside the window title. Click a thumbnail to visit that page, resize the sidebar to change thumbnail size, or drag the divider fully left to hide it."
        ),
        section(
            .windowsAndTabs,
            "Windows, Tabs, and Reopening",
            "Open a new window or tab from the File menu. Native window tabs preserve their order and selected tab during workspace restoration.",
            "After a normal quit, choose File → Reopen Windows from Last Session to restore saved local documents and their window layout. Relaunches after an app update restore the same workspace automatically."
        ),
        section(
            .pageSetupAndPrinting,
            "Page Setup, Footers, and Printing",
            "Settings → Page defines the default paper, orientation, scale, and optional left and right footers. File → Page Setup changes only the focused document.",
            "When a document has its own setup, Use Default Page Setup in the native sheet immediately returns it to the current app default. Printing uses the generated PDF at 100 percent so page scaling is not applied twice."
        ),
        section(
            .finderAndQuickLook,
            "Finder and Quick Look",
            "Choose File → Show in Finder to reveal the Markdown source. Command-click the document title to browse its folder path.",
            "Select a Markdown file in Finder and press Space for the bundled Quick Look preview. If Quick Look is disabled, Settings → General links to the relevant macOS System Settings pane."
        ),
        section(
            .imagesAndPrivacy,
            "Images and Privacy",
            "Relative image paths resolve from the Markdown file’s folder. Missing, unreadable, and absolute images appear as readable placeholders. Click a remote-image placeholder to download it, or right-click the placeholder and choose Download All Images.",
            "Downloaded remote images stay in Markdown Printer’s disposable cache and are never written beside the Markdown file. Finder Quick Look stays offline. All parsing, preview generation, export, and printing happen locally."
        ),
        section(
            .keyboardShortcuts,
            "Keyboard Shortcuts",
            "These shortcuts are available when their corresponding document action is valid."
        )
    ]

    package static let shortcuts: [MarkdownPrinterHelpShortcut] = [
        shortcut("New Window", "⌘N", "Command-N"),
        shortcut("New Tab", "⌘T", "Command-T"),
        shortcut("Open", "⌘O", "Command-O"),
        shortcut("Save Export", "⌘S", "Command-S"),
        shortcut("Save As", "⇧⌘S", "Shift-Command-S"),
        shortcut("Close Window or Tab", "⌘W", "Command-W"),
        shortcut("Show or Hide Tab Bar", "⇧⌘T", "Shift-Command-T"),
        shortcut("Page Setup", "⇧⌘P", "Shift-Command-P"),
        shortcut("Print", "⌘P", "Command-P"),
        shortcut("Find", "⌘F", "Command-F"),
        shortcut("Find Next", "⌘G", "Command-G"),
        shortcut("Find Previous", "⇧⌘G", "Shift-Command-G"),
        shortcut("Close Search", "Esc", "Escape"),
        shortcut("Actual Size", "⌘0", "Command-0"),
        shortcut("Zoom to Fit", "⌘9", "Command-9"),
        shortcut("Zoom In", "⌘+ or ⌘=", "Command-Plus or Command-Equals"),
        shortcut("Zoom Out", "⌘−", "Command-Minus"),
        shortcut("Previous Page", "⌥↑ or ⇧Space", "Option-Up Arrow or Shift-Space"),
        shortcut("Next Page", "⌥↓ or Space", "Option-Down Arrow or Space"),
        shortcut("Settings", "⌘,", "Command-Comma"),
        shortcut("Quit", "⌘Q", "Command-Q")
    ]

    package static var searchableText: String {
        let sectionText = sections.flatMap { [$0.title] + $0.paragraphs }
        let shortcutText = shortcuts.flatMap { [$0.action, $0.keys, $0.spokenKeys] }
        return (sectionText + shortcutText).joined(separator: "\n")
    }

    private static func section(
        _ id: MarkdownPrinterHelpSection.ID,
        _ title: String,
        _ paragraphs: String...
    ) -> MarkdownPrinterHelpSection {
        MarkdownPrinterHelpSection(id: id, title: title, paragraphs: paragraphs)
    }

    private static func shortcut(
        _ action: String,
        _ keys: String,
        _ spokenKeys: String
    ) -> MarkdownPrinterHelpShortcut {
        MarkdownPrinterHelpShortcut(action: action, keys: keys, spokenKeys: spokenKeys)
    }
}

@MainActor
package final class MarkdownPrinterHelpNavigator: ObservableObject {
    @Published package private(set) var destination: MarkdownPrinterHelpDestination
    @Published package private(set) var requestRevision: UInt64 = 0

    package init(destination: MarkdownPrinterHelpDestination = .overview) {
        self.destination = destination
    }

    package func show(_ destination: MarkdownPrinterHelpDestination) {
        self.destination = destination
        requestRevision &+= 1
    }
}

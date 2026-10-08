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
        case previousVersions
        case codexComparisons
        case exporting
        case markdownFormatting
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
    package let copyablePrompt: MarkdownPrinterHelpCopyablePrompt?

    package init(
        id: ID,
        title: String,
        paragraphs: [String],
        copyablePrompt: MarkdownPrinterHelpCopyablePrompt? = nil
    ) {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
        self.copyablePrompt = copyablePrompt
    }
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
            "When another app saves the source file, Markdown Printer refreshes the preview and keeps the current viewport whenever possible.",
            "If the source temporarily disappears or cannot be read, the last successful preview stays visible. After about two seconds, a compact banner says: Source file unavailable. Showing the last rendered version. Recovery is automatic and the banner disappears after a successful read, even when the content is unchanged.",
            "Detected renames and moves are followed automatically. The source filename, folder for relative images and links, and window restoration location update together. If the source remains unavailable, close the window and open another file when ready."
        ),
        section(
            .previousVersions,
            "Compare with a Previous Version",
            "Choose File → Compare with Older Version… to select an older Markdown file. Changes are highlighted in the preview and PDF or Word exports. The older version stays fixed while the current file refreshes. Choose File → Clear Change Highlighting (Control-Command-H) to return to the ordinary preview.",
            "Choose File → Compare with Git Version… (Control-Command-G) to browse commits that changed this document, including history across detected renames. Use the Up and Down arrow keys to select a commit and Return to compare. You can also double-click a commit to compare immediately, or select it and click Compare. The list shows its date and time, message, and commit ID. Git must already be installed; only locally available history is read, and the repository is never changed.",
            "Short removed words and phrases appear in red with strikethrough beside a caret (^). Complete prose removals use plain red summaries such as ^ removed 3 sentences or ^ removed 2 paragraphs. Whole-paragraph counts take priority over sentence counts. Partial prose fragments longer than 12 words use a summary such as ^ removed 18 words. Counts use the exact removed content; a rewrite does not count surviving words as deleted. Removed images keep the plain red ^ removed image label. PDF and Word exports include the same markings without moving the current text.",
            "If Settings → Page includes a date footer, differing dates appear with the current modification date above the original date. The current date has a yellow background; the original date is red with strikethrough. Git comparisons use the selected commit’s timestamp, while ordinary file comparisons capture the older file’s modification date. Dates follow the selected date, time, and time-zone format and appear in PDF and Word exports."
        ),
        codexComparisonSkillSection,
        section(
            .exporting,
            "Save, Share, and Drag Exports",
            "The preferred export format in Settings controls Save, Share, and dragging a document from the preview. PDF and Microsoft Word exports use the same page setup and footer choices.",
            "Use the Save toolbar button or File → Save As to choose a destination. Use the Share toolbar button or File → Share PDF/Share Microsoft Word to open the macOS Share sheet. Drag from the preview to place an exported file in Finder or another accepting app.",
            "Hold Option when dragging from the preview or clicking Share to use the other format for that action: PDF becomes Microsoft Word, and Microsoft Word becomes PDF. Your default format in Settings stays unchanged."
        ),
        section(
            .markdownFormatting,
            "Links, Sections, and Task Lists",
            "Bare HTTP/HTTPS URLs, www. addresses, email addresses, mailto: links, and xmpp: links become clickable automatically. Code, image descriptions, raw HTML, and existing link labels keep their original formatting.",
            "Use - [ ] for an unchecked task and - [x] or - [X] for a checked task. Add whitespace after the marker. Nested and mixed lists are supported; checkboxes are read-only.",
            "Link to a heading with [Packing](#packing-list), or to a sibling document with [Packing](other.md#packing-list). Relative paths start in the source file’s folder. Heading anchors use lowercase content, remove formatting and punctuation, replace spaces with hyphens, preserve Unicode letters and underscores, and append -1, -2, and so on to resolve collisions. Custom HTML anchors are not supported.",
            "Section links jump within the Mac preview, Finder Quick Look, and the iPhone/iPad reader. Quick Look asks its host to open cross-file sections in the Mac app. If the host declines, use the toolbar to open the source file in Markdown Printer and follow the link there. PDF exports use native destinations; Word exports use heading bookmarks. Both retain cross-file links as standard file URLs with fragments; navigation in other viewers depends on the viewer and associated app. Missing sections do not open an external app, and a successfully opened target document remains available."
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
            "Sidebar",
            "Choose View → Show Sidebar or use the sidebar button beside the window title. Pages shows the existing thumbnails: click one to visit that page, resize the sidebar to change thumbnail size, or drag the divider fully left to hide it.",
            "After a successful comparison, Changes opens automatically. The upper list groups changes under document headings; the lower area shows complete Earlier and Current passages. Both areas scroll independently. Drag their divider to give either area more room, or widen the sidebar for longer passages.",
            "Click a change or use Previous and Next to visit its PDF location. With the Changes list or details focused, Down or Right Arrow visits the next change; Up or Left Arrow visits the previous change. Both arrow pairs and the buttons include changes in collapsed groups and stop at the first and last entries. Scrolling preserves the selected change. Word edits within a paragraph stay together; removed passages remain complete even when their printed annotations are shortened or summarized.",
            "A pale yellow band with an amber outline and circular change number identifies the selected passage. It includes related red margin notes and continues separately across pages. Navigation leaves context above the passage, with less space above tall passages; comfortably visible passages stay in place. The first comparison selection does not scroll. Hiding the sidebar removes the band; reopening Changes restores it without navigating. Selection bands appear only in the preview, not in saved PDFs or Word exports.",
            "The sidebar remembers its mode, widths, divider, groups, selection, and reading positions when reopening a workspace. Ordinary source refreshes preserve your sidebar choices. Clearing comparison markings returns to Pages. A comparison without meaningful document changes says No meaningful document changes."
        ),
        section(
            .windowsAndTabs,
            "Windows, Tabs, and Reopening",
            "Open a new window or tab from the File menu. Native window tabs preserve their order and selected tab during workspace restoration.",
            "After a normal quit, choose File → Reopen Windows from Last Session to restore saved local documents, window positions and sizes, preview zoom, and scroll positions. Relaunches after an app update restore the same workspace automatically. If a display is disconnected, windows move onto an available screen."
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
        shortcut("Compare with Git Version", "⌃⌘G", "Control-Command-G"),
        shortcut("Clear Change Highlighting", "⌃⌘H", "Control-Command-H"),
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
        let sectionText = sections.flatMap {
            [$0.title] + $0.paragraphs + ($0.copyablePrompt?.searchableTexts ?? [])
        }
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

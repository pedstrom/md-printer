import AppKit
import Foundation

public enum FinderQuickLookSettingsCopy {
    public static let usage = "Select a Markdown file in Finder and press Space or ⌘Y."
    public static let bundled = "Quick Look is included with Markdown Printer. Deleting the app removes it."
    public static let troubleshooting = "If Quick Look is disabled, open System Settings → General → Login Items & Extensions → Quick Look ⓘ, then turn on Markdown Printer."
    public static let associationNote = "macOS associates default apps by content type, so this covers the normal Markdown types used by .md, .markdown, .mdown, and .mkd files."
}

@MainActor
package protocol WorkspaceOpening: AnyObject {
    @discardableResult
    func open(_ url: URL) -> Bool
}

@MainActor
private final class SystemWorkspaceOpener: WorkspaceOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
public final class FinderQuickLookSettingsNavigator {
    public static let systemSettingsURL = URL(
        fileURLWithPath: "/System/Applications/System Settings.app",
        isDirectory: true
    )

    private let opener: any WorkspaceOpening

    public convenience init() {
        self.init(opener: SystemWorkspaceOpener())
    }

    package init(opener: any WorkspaceOpening) {
        self.opener = opener
    }

    public func openSystemSettings() {
        opener.open(Self.systemSettingsURL)
    }
}

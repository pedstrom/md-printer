import AppKit

@MainActor
public enum AboutPanel {
    public static let releaseNotesURL = URL(
        string: "https://github.com/pedstrom/md-printer/releases"
    )!
    public static let releaseNotesLinkText = "Release Notes"
    public static let licenseURL = URL(
        string: "https://github.com/pedstrom/md-printer/blob/main/LICENSE"
    )!
    public static let licenseLinkText = "MIT License on GitHub"

    public static var options: [NSApplication.AboutPanelOptionKey: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSMutableAttributedString(
            string: "\(releaseNotesLinkText)\n\(licenseLinkText)",
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraphStyle,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        let text = credits.string as NSString
        credits.addAttribute(
            .link,
            value: releaseNotesURL,
            range: text.range(of: releaseNotesLinkText)
        )
        credits.addAttribute(
            .link,
            value: licenseURL,
            range: text.range(of: licenseLinkText)
        )
        return [.credits: credits]
    }

    public static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    public static func show(
        presenter: ([NSApplication.AboutPanelOptionKey: Any]) -> Void
    ) {
        presenter(options)
    }
}

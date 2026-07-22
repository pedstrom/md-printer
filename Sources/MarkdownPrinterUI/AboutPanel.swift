import AppKit

@MainActor
public enum AboutPanel {
    public static let licenseURL = URL(
        string: "https://github.com/pedstrom/md-printer/blob/main/LICENSE"
    )!
    public static let licenseLinkText = "MIT License on GitHub"

    public static var options: [NSApplication.AboutPanelOptionKey: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let credits = NSAttributedString(
            string: licenseLinkText,
            attributes: [
                .link: licenseURL,
                .foregroundColor: NSColor.linkColor,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraphStyle,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
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

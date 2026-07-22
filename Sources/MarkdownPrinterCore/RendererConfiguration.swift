import AppKit

public struct RendererConfiguration: Equatable {
    public var fontFamily: String
    public var bodyFontSize: CGFloat
    public var headingFontSizes: [CGFloat]
    public var pageSize: CGSize
    public var pageMargins: NSEdgeInsets
    public var textColor: NSColor
    public var secondaryTextColor: NSColor
    public var accentColor: NSColor
    public var codeBackgroundColor: NSColor
    public var tableBorderColor: NSColor
    public var maximumImageWidth: CGFloat
    public var codeBlockPadding: CGFloat

    public init(
        fontFamily: String = "Avenir Next",
        bodyFontSize: CGFloat = 10,
        headingFontSizes: [CGFloat] = [24, 20, 17, 14, 12, 10],
        pageSize: CGSize = CGSize(width: 612, height: 792),
        pageMargins: NSEdgeInsets = NSEdgeInsets(top: 54, left: 54, bottom: 54, right: 54),
        textColor: NSColor = .textColor,
        secondaryTextColor: NSColor = .secondaryLabelColor,
        accentColor: NSColor = .systemBlue,
        codeBackgroundColor: NSColor = NSColor(calibratedWhite: 0.94, alpha: 1),
        tableBorderColor: NSColor = NSColor(calibratedWhite: 0.72, alpha: 1),
        maximumImageWidth: CGFloat = 504,
        codeBlockPadding: CGFloat = 8
    ) {
        self.fontFamily = fontFamily
        self.bodyFontSize = bodyFontSize
        self.headingFontSizes = headingFontSizes
        self.pageSize = pageSize
        self.pageMargins = pageMargins
        self.textColor = textColor
        self.secondaryTextColor = secondaryTextColor
        self.accentColor = accentColor
        self.codeBackgroundColor = codeBackgroundColor
        self.tableBorderColor = tableBorderColor
        self.maximumImageWidth = maximumImageWidth
        self.codeBlockPadding = codeBlockPadding
    }

    public var contentWidth: CGFloat {
        max(1, pageSize.width - pageMargins.left - pageMargins.right)
    }

    public func headingSize(for level: Int) -> CGFloat {
        let index = min(max(level - 1, 0), headingFontSizes.count - 1)
        return headingFontSizes[index]
    }

    public static func == (lhs: RendererConfiguration, rhs: RendererConfiguration) -> Bool {
        lhs.fontFamily == rhs.fontFamily
            && lhs.bodyFontSize == rhs.bodyFontSize
            && lhs.headingFontSizes == rhs.headingFontSizes
            && lhs.pageSize == rhs.pageSize
            && lhs.pageMargins.top == rhs.pageMargins.top
            && lhs.pageMargins.left == rhs.pageMargins.left
            && lhs.pageMargins.bottom == rhs.pageMargins.bottom
            && lhs.pageMargins.right == rhs.pageMargins.right
            && lhs.textColor == rhs.textColor
            && lhs.secondaryTextColor == rhs.secondaryTextColor
            && lhs.accentColor == rhs.accentColor
            && lhs.codeBackgroundColor == rhs.codeBackgroundColor
            && lhs.tableBorderColor == rhs.tableBorderColor
            && lhs.maximumImageWidth == rhs.maximumImageWidth
            && lhs.codeBlockPadding == rhs.codeBlockPadding
    }
}

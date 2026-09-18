#if canImport(UIKit)
import MarkdownPrinterCore
import UIKit

public enum MobileHeadingTypography {
    public static func font(level: Int, size: CGFloat, family: String = "AvenirNext") -> UIFont {
        let style = HeadingTypography(level: level)
        let suffix = style.usesBold ? "Bold" : (style.usesItalic ? "DemiBoldItalic" : "DemiBold")
        if let font = UIFont(name: "\(family)-\(suffix)", size: size) { return font }
        let fallback = UIFont.systemFont(ofSize: size, weight: style.usesBold ? .bold : .semibold)
        return applyingTraits(to: fallback, italic: style.usesItalic)
    }

    public static func readerFont(level: Int, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        // Use the same Dynamic Type curve as body copy to retain the hierarchy at every size.
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: font(level: level, size: HeadingTypography(level: level).readerSize),
            compatibleWith: traits
        )
    }

    public static func applyingTraits(to font: UIFont, bold: Bool = false, italic: Bool = false) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    public static func spacingBefore(level: Int, after previous: MarkdownBlock?) -> CGFloat {
        HeadingTypography(level: level).additionalSpacingBefore(
            after: previous.map(trailingSpacing), scale: 1.7
        )
    }

    private static func trailingSpacing(_ block: MarkdownBlock) -> CGFloat {
        switch block {
        case let .heading(level, _): return HeadingTypography(level: level).spacingAfter * 1.7
        case .paragraph, .list: return 11
        case .blockquote: return 13 // Includes the block's six-point vertical inset.
        case .codeBlock, .thematicBreak: return 14
        case .rawHTML: return 10
        case .table: return 17 // Includes the table's seven-point vertical inset.
        case .footnoteDefinition: return 0
        }
    }
}
#endif

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One hierarchy for print and screen; point sizes remain appropriate to each surface.
public struct HeadingTypography {
    public static let printSizes: [CGFloat] = [26, 20, 16, 13, 11, 10]
    public static let quickLookSizes: [CGFloat] = [34, 26, 21, 17, 14, 13]
    public static let readerSizes: [CGFloat] = [40, 32, 26, 22, 19, 17]

    public let level: Int

    public init(level: Int) {
        self.level = min(max(level, 1), 6)
    }

    public var printSize: CGFloat { Self.printSizes[level - 1] }
    public var readerSize: CGFloat { Self.readerSizes[level - 1] }
    public var usesBold: Bool { level <= 2 }
    public var usesItalic: Bool { level == 6 }
    public var spacingBefore: CGFloat { [24, 18, 14, 11, 9, 8][level - 1] }
    public var spacingAfter: CGFloat { [8, 6, 5, 4, 3, 3][level - 1] }

    /// The preceding block already contributes its trailing space to the total gap.
    public func additionalSpacingBefore(after previousSpacing: CGFloat?, scale: CGFloat = 1) -> CGFloat {
        guard let previousSpacing else { return 0 }
        return max(0, spacingBefore * scale - previousSpacing)
    }

    public func additionalSpacingBefore(in text: NSAttributedString, scale: CGFloat = 1) -> CGFloat {
        let string = text.string as NSString
        var index = text.length - 1
        while index >= 0, [10, 13].contains(string.character(at: index)) {
            index -= 1
        }
        guard index >= 0 else { return 0 }
        let previous = text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        return additionalSpacingBefore(after: previous?.paragraphSpacing ?? 0, scale: scale)
    }
}

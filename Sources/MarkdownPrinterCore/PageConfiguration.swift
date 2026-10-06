#if canImport(AppKit)
import AppKit
import Foundation

public enum DocumentPageOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
}

public struct DocumentPageSetup: Codable, Equatable, Sendable {
    public static let fixedMargins = NSEdgeInsets(top: 54, left: 54, bottom: 54, right: 54)
    public static let letter = DocumentPageSetup(
        paperName: "na-letter",
        paperSize: CGSize(width: 612, height: 792),
        orientation: .portrait,
        scale: 1
    )

    public let paperName: String
    public let paperWidth: Double
    public let paperHeight: Double
    public let orientation: DocumentPageOrientation
    /// A multiplier where `1` is 100 percent.
    public let scale: Double

    public init(
        paperName: String,
        paperSize: CGSize,
        orientation: DocumentPageOrientation,
        scale: Double
    ) {
        guard !paperName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              paperSize.width.isFinite,
              paperSize.height.isFinite,
              (72...2_000).contains(paperSize.width),
              (72...2_000).contains(paperSize.height),
              scale.isFinite,
              (0.1...4).contains(scale)
        else {
            self = .fallback
            return
        }
        self.paperName = paperName
        paperWidth = Double(min(paperSize.width, paperSize.height))
        paperHeight = Double(max(paperSize.width, paperSize.height))
        self.orientation = orientation
        self.scale = scale
    }

    public var pageSize: CGSize {
        switch orientation {
        case .portrait:
            return CGSize(width: paperWidth, height: paperHeight)
        case .landscape:
            return CGSize(width: paperHeight, height: paperWidth)
        }
    }

    public var scalePercentage: Int {
        Int((scale * 100).rounded())
    }

    private static var fallback: DocumentPageSetup {
        DocumentPageSetup(
            uncheckedPaperName: "na-letter",
            paperWidth: 612,
            paperHeight: 792,
            orientation: .portrait,
            scale: 1
        )
    }

    private init(
        uncheckedPaperName: String,
        paperWidth: Double,
        paperHeight: Double,
        orientation: DocumentPageOrientation,
        scale: Double
    ) {
        paperName = uncheckedPaperName
        self.paperWidth = paperWidth
        self.paperHeight = paperHeight
        self.orientation = orientation
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey {
        case paperName
        case paperWidth
        case paperHeight
        case orientation
        case scale
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            paperName: try values.decode(String.self, forKey: .paperName),
            paperSize: CGSize(
                width: try values.decode(Double.self, forKey: .paperWidth),
                height: try values.decode(Double.self, forKey: .paperHeight)
            ),
            orientation: try values.decode(DocumentPageOrientation.self, forKey: .orientation),
            scale: try values.decode(Double.self, forKey: .scale)
        )
    }
}

public enum FooterValue: Codable, Equatable, Sendable {
    case none
    case date
    case dateTime
    case dateTimeWithTimeZone
    case documentTitle
    case filename
    case custom(String)

    public static let menuValues: [FooterValue] = [
        .none, .date, .dateTime, .dateTimeWithTimeZone, .documentTitle, .filename, .custom("")
    ]

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .date: return "Date"
        case .dateTime: return "Date & Time"
        case .dateTimeWithTimeZone: return "Date & Time with Time Zone"
        case .documentTitle: return "Document Title"
        case .filename: return "Filename"
        case .custom: return "Custom…"
        }
    }

    public var normalized: FooterValue {
        guard case let .custom(text) = self else { return self }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return .custom(normalized)
    }

    public func resolved(
        for document: MarkdownDocument,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        switch normalized {
        case .none:
            return ""
        case .date:
            return Self.dateFormatter(
                dateStyle: .medium,
                timeStyle: .none,
                locale: locale,
                timeZone: timeZone
            ).string(from: document.sourceModificationDate ?? .distantPast)
                .blankWhenMissing(document.sourceModificationDate)
        case .dateTime, .dateTimeWithTimeZone:
            guard let date = document.sourceModificationDate else { return "" }
            let formatter = Self.dateFormatter(
                dateStyle: .medium,
                timeStyle: .short,
                locale: locale,
                timeZone: timeZone
            )
            let dateTime = formatter.string(from: date)
            guard self == .dateTimeWithTimeZone else { return dateTime }
            formatter.dateFormat = "zzz"
            return "\(dateTime) \(formatter.string(from: date))"
        case .documentTitle:
            return document.title
        case .filename:
            return document.sourceURL?.lastPathComponent ?? ""
        case let .custom(text):
            return text
        }
    }

    /// The comparison's captured timestamp stays fixed while the live document's
    /// modification timestamp follows source refreshes. Only date preferences
    /// acquire revision styling; other footer choices retain their ordinary form.
    public func resolvedLines(
        for document: MarkdownDocument,
        original: MarkdownDocument?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [ResolvedFooterLine] {
        let currentText = resolved(for: document, locale: locale, timeZone: timeZone)
        let ordinary = currentText.isEmpty ? [] : [ResolvedFooterLine(text: currentText)]
        switch self {
        case .date, .dateTime, .dateTimeWithTimeZone:
            guard document.sourceModificationDate != nil,
                  let original, original.sourceModificationDate != nil else { return ordinary }
            let originalText = resolved(for: original, locale: locale, timeZone: timeZone)
            guard currentText != originalText else { return ordinary }
            return [
                ResolvedFooterLine(text: currentText, style: .current),
                ResolvedFooterLine(text: originalText, style: .original)
            ]
        default:
            return ordinary
        }
    }

    private static func dateFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
}

private extension String {
    func blankWhenMissing(_ date: Date?) -> String {
        date == nil ? "" : self
    }
}

public enum FooterRevisionStyle: Equatable, Sendable {
    case ordinary
    case current
    case original
}

public struct ResolvedFooterLine: Equatable, Sendable {
    public var text: String
    public var style: FooterRevisionStyle

    public init(text: String, style: FooterRevisionStyle = .ordinary) {
        self.text = text
        self.style = style
    }
}

public struct ResolvedFooterConfiguration: Equatable, Sendable {
    public var leftLines: [ResolvedFooterLine]
    public var rightLines: [ResolvedFooterLine]

    /// Plain-string access remains available for existing exporter clients.
    public var left: String {
        get { leftLines.map(\.text).joined(separator: "\n") }
        set { leftLines = newValue.isEmpty ? [] : [ResolvedFooterLine(text: newValue)] }
    }

    public var right: String {
        get { rightLines.map(\.text).joined(separator: "\n") }
        set { rightLines = newValue.isEmpty ? [] : [ResolvedFooterLine(text: newValue)] }
    }

    public init(left: String = "", right: String = "") {
        leftLines = left.isEmpty ? [] : [ResolvedFooterLine(text: left)]
        rightLines = right.isEmpty ? [] : [ResolvedFooterLine(text: right)]
    }

    public init(leftLines: [ResolvedFooterLine], rightLines: [ResolvedFooterLine]) {
        self.leftLines = leftLines
        self.rightLines = rightLines
    }
}

public extension RendererConfiguration {
    func applying(_ pageSetup: DocumentPageSetup) -> RendererConfiguration {
        var result = self
        result.pageSize = pageSetup.pageSize
        result.pageMargins = DocumentPageSetup.fixedMargins
        result.bodyFontSize *= pageSetup.scale
        result.headingFontSizes = result.headingFontSizes.map { $0 * pageSetup.scale }
        result.codeBlockPadding *= pageSetup.scale
        result.maximumImageWidth = result.contentWidth
        return result
    }
}
#endif

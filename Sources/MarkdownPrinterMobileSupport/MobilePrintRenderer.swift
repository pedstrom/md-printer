#if canImport(UIKit)
import Foundation
import MarkdownPrinterCore
import UIKit

extension NSAttributedString.Key {
    static let mobileTableColumnCount = NSAttributedString.Key("MarkdownPrinterMobileTableColumnCount")
    static let mobileTableHeader = NSAttributedString.Key("MarkdownPrinterMobileTableHeader")
    static let mobileQuote = NSAttributedString.Key("MarkdownPrinterMobileQuote")
    static let mobileThematicBreak = NSAttributedString.Key("MarkdownPrinterMobileThematicBreak")
    static let mobileFootnoteReference = NSAttributedString.Key("MarkdownPrinterMobileFootnoteReference")
    static let mobileFootnoteDefinition = NSAttributedString.Key("MarkdownPrinterMobileFootnoteDefinition")
}

final class MobilePrintRenderer {
    let configuration: MobilePDFConfiguration
    private let presenter = MobileMarkdownPresenter()
    private let imageResolver = MobileImageResolver()

    init(configuration: MobilePDFConfiguration) {
        self.configuration = configuration
    }

    func render(document: MarkdownDocument) throws -> NSAttributedString {
        let presentation = presenter.prepare(document: document)
        let result = NSMutableAttributedString(string: "")
        for (index, block) in presentation.blocks.enumerated() {
            try Task.checkCancellation()
            append(
                block.block,
                to: result,
                baseURL: document.baseURL,
                footnoteNumbers: presentation.footnoteNumbers
            )
            if index < presentation.blocks.count - 1,
               !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        if !presentation.footnotes.isEmpty {
            if !result.string.hasSuffix("\n\n") {
                result.append(NSAttributedString(string: result.string.hasSuffix("\n") ? "\n" : "\n\n"))
            }
            let heading = NSAttributedString(
                string: "Notes\n",
                attributes: attributes(font: font(.demiBold, size: 13), paragraph: paragraph(spacingAfter: 5))
            )
            result.append(heading)
            for footnote in presentation.footnotes {
                try Task.checkCancellation()
                let line = NSMutableAttributedString(
                    string: "\(footnote.number). ",
                    attributes: attributes(font: font(.regular, size: 8), paragraph: footnoteParagraph())
                )
                line.append(
                    inline(
                        footnote.content,
                        font: font(.regular, size: 8),
                        baseURL: document.baseURL,
                        footnoteNumbers: presentation.footnoteNumbers
                    )
                )
                line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: footnoteParagraph()]))
                line.addAttribute(
                    .mobileFootnoteDefinition,
                    value: footnote.label,
                    range: NSRange(location: 0, length: max(1, line.length - 1))
                )
                result.append(line)
            }
        }
        return result
    }

    private func append(
        _ block: MarkdownBlock,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        footnoteNumbers: [String: Int]
    ) {
        switch block {
        case let .heading(level, content):
            let sizes: [CGFloat] = [24, 20, 17, 14, 12, 10]
            let size = sizes[min(max(level - 1, 0), sizes.count - 1)]
            let line = inline(
                content,
                font: font(.demiBold, size: size),
                baseURL: baseURL,
                footnoteNumbers: footnoteNumbers
            )
            line.addAttribute(
                .paragraphStyle,
                value: paragraph(spacingBefore: level <= 2 ? 6 : 3, spacingAfter: level <= 2 ? 8 : 5),
                range: line.fullRange
            )
            result.append(line)
            result.append(NSAttributedString(string: "\n"))
        case let .paragraph(content):
            let line = inline(
                content,
                font: font(.regular, size: configuration.bodyFontSize),
                baseURL: baseURL,
                footnoteNumbers: footnoteNumbers
            )
            line.addAttribute(.paragraphStyle, value: paragraph(), range: line.fullRange)
            result.append(line)
            result.append(NSAttributedString(string: "\n"))
        case let .blockquote(children):
            let start = result.length
            for child in children {
                append(
                    child,
                    to: result,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers
                )
            }
            let range = NSRange(location: start, length: result.length - start)
            let style = paragraph(leftIndent: 18, firstLineIndent: 18, spacingAfter: 6)
            result.addAttribute(.paragraphStyle, value: style, range: range)
            result.addAttribute(.mobileQuote, value: true, range: range)
        case let .list(items, ordered, start, tight):
            appendList(
                items: items,
                ordered: ordered,
                start: start,
                tight: tight,
                depth: 0,
                to: result,
                baseURL: baseURL,
                footnoteNumbers: footnoteNumbers
            )
        case let .codeBlock(_, code), let .rawHTML(code):
            let style = paragraph(
                leftIndent: configuration.codeBlockPadding,
                firstLineIndent: configuration.codeBlockPadding,
                rightIndent: configuration.codeBlockPadding,
                spacingBefore: 3,
                spacingAfter: 8,
                lineSpacing: 1
            )
            result.append(
                NSAttributedString(
                    string: code + (code.hasSuffix("\n") ? "" : "\n"),
                    attributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 8.5, weight: .regular),
                        .foregroundColor: UIColor.black,
                        .backgroundColor: UIColor(white: 0.94, alpha: 1),
                        .paragraphStyle: style
                    ]
                )
            )
        case .thematicBreak:
            let style = paragraph(spacingBefore: 7, spacingAfter: 9)
            result.append(
                NSAttributedString(
                    string: "\u{200B}\n",
                    attributes: [
                        .font: font(.regular, size: 1),
                        .foregroundColor: UIColor.clear,
                        .paragraphStyle: style,
                        .mobileThematicBreak: true
                    ]
                )
            )
        case .footnoteDefinition:
            break
        case let .table(headers, alignments, rows):
            appendTable(
                headers: headers,
                alignments: alignments,
                rows: rows,
                to: result,
                baseURL: baseURL,
                footnoteNumbers: footnoteNumbers
            )
        }
    }

    private func inlineBlock(
        _ block: MarkdownBlock,
        baseURL: URL?,
        footnoteNumbers: [String: Int]
    ) -> NSAttributedString {
        switch block {
        case let .heading(_, content), let .paragraph(content), let .footnoteDefinition(_, content):
            return inline(
                content,
                font: font(.regular, size: configuration.bodyFontSize),
                baseURL: baseURL,
                footnoteNumbers: footnoteNumbers
            )
        default:
            return NSAttributedString(
                string: presenter.plainText(from: block, footnoteNumbers: footnoteNumbers),
                attributes: attributes(font: font(.regular, size: configuration.bodyFontSize))
            )
        }
    }

    private func appendList(
        items: [MarkdownListItem],
        ordered: Bool,
        start: Int,
        tight: Bool,
        depth: Int,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        footnoteNumbers: [String: Int]
    ) {
        let markerIndent = CGFloat(depth) * 18
        let contentIndent = markerIndent + 24
        let style = paragraph(
            leftIndent: contentIndent,
            firstLineIndent: markerIndent,
            spacingAfter: tight ? 2 : 7,
            tabStops: [NSTextTab(textAlignment: .left, location: contentIndent)]
        )

        for (index, item) in items.enumerated() {
            let marker = ordered ? "\(start + index)." : "•"
            let task = item.checked.map { $0 ? "☑" : "☐" }
            let prefix = task.map { "\(marker) \($0)\t" } ?? "\(marker)\t"
            let line = NSMutableAttributedString(
                string: prefix,
                attributes: attributes(font: font(.regular, size: configuration.bodyFontSize))
            )
            let contentBlocks = item.blocks.filter {
                if case .list = $0 { return false }
                return true
            }
            for (blockIndex, child) in contentBlocks.enumerated() {
                if blockIndex > 0 { line.append(NSAttributedString(string: "\n")) }
                line.append(inlineBlock(child, baseURL: baseURL, footnoteNumbers: footnoteNumbers))
            }
            line.addAttribute(.paragraphStyle, value: style, range: line.fullRange)
            line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            result.append(line)

            for child in item.blocks {
                guard case let .list(children, childOrdered, childStart, childTight) = child else {
                    continue
                }
                appendList(
                    items: children,
                    ordered: childOrdered,
                    start: childStart,
                    tight: childTight,
                    depth: depth + 1,
                    to: result,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers
                )
            }
        }
    }

    private func appendTable(
        headers: [[InlineNode]],
        alignments: [TableAlignment],
        rows: [[[InlineNode]]],
        to result: NSMutableAttributedString,
        baseURL: URL?,
        footnoteNumbers: [String: Int]
    ) {
        let allRows = [headers] + rows
        let columnCount = max(1, allRows.map(\.count).max() ?? 1)
        let columnWidth = configuration.contentWidth / CGFloat(columnCount)
        let tabs = (0..<columnCount).map { index in
            let alignment = alignments[safe: index] ?? .leading
            let leading = CGFloat(index) * columnWidth
            let location: CGFloat
            switch alignment {
            case .leading:
                location = leading + 4
            case .center:
                location = leading + columnWidth / 2
            case .trailing:
                location = leading + columnWidth - 4
            }
            return NSTextTab(textAlignment: textAlignment(for: alignment), location: location)
        }
        for (rowIndex, row) in allRows.enumerated() {
            let line = NSMutableAttributedString(string: "")
            for column in 0..<columnCount {
                line.append(NSAttributedString(string: "\t"))
                let cell = column < row.count ? row[column] : []
                line.append(
                    inline(
                        cell,
                        font: font(rowIndex == 0 ? .demiBold : .regular, size: 8.5),
                        baseURL: baseURL,
                        footnoteNumbers: footnoteNumbers
                    )
                )
            }
            let style = paragraph(
                spacingAfter: 0,
                lineSpacing: 1,
                tabStops: tabs
            )
            line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            line.addAttributes(
                [
                    .paragraphStyle: style,
                    .mobileTableColumnCount: columnCount,
                    .mobileTableHeader: rowIndex == 0
                ],
                range: line.fullRange
            )
            if rowIndex == 0 {
                line.addAttribute(
                    .backgroundColor,
                    value: UIColor(white: 0.94, alpha: 1),
                    range: line.fullRange
                )
            }
            result.append(line)
        }
        result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph(spacingAfter: 2)]))
    }

    private func inline(
        _ nodes: [InlineNode],
        font baseFont: UIFont,
        baseURL: URL?,
        footnoteNumbers: [String: Int]
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        for node in nodes {
            switch node {
            case let .text(text):
                result.append(NSAttributedString(string: text, attributes: attributes(font: baseFont)))
            case let .emphasis(children):
                result.append(inline(children, font: variant(of: baseFont, italic: true), baseURL: baseURL, footnoteNumbers: footnoteNumbers))
            case let .strong(children):
                result.append(inline(children, font: variant(of: baseFont, bold: true), baseURL: baseURL, footnoteNumbers: footnoteNumbers))
            case let .underline(children):
                let child = inline(children, font: baseFont, baseURL: baseURL, footnoteNumbers: footnoteNumbers)
                child.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: child.fullRange)
                result.append(child)
            case let .strikethrough(children):
                let child = inline(children, font: baseFont, baseURL: baseURL, footnoteNumbers: footnoteNumbers)
                child.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: child.fullRange)
                result.append(child)
            case let .code(code):
                result.append(
                    NSAttributedString(
                        string: code,
                        attributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: max(7, baseFont.pointSize * 0.92), weight: .regular),
                            .foregroundColor: UIColor.black,
                            .backgroundColor: UIColor(white: 0.94, alpha: 1)
                        ]
                    )
                )
            case let .link(children, destination, _):
                let child = inline(children, font: baseFont, baseURL: baseURL, footnoteNumbers: footnoteNumbers)
                if let url = MarkdownLinkTarget.resolvedURL(for: destination, relativeTo: baseURL) {
                    child.addAttributes(
                        [.link: url, .foregroundColor: UIColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue],
                        range: child.fullRange
                    )
                }
                result.append(child)
            case let .footnoteReference(label):
                let number = footnoteNumbers[label]
                let reference = NSMutableAttributedString(
                    string: number.map(String.init) ?? label,
                    attributes: [
                        .font: font(.regular, size: max(6, baseFont.pointSize * 0.72)),
                        .foregroundColor: UIColor.systemBlue,
                        .baselineOffset: baseFont.pointSize * 0.35,
                        .mobileFootnoteReference: label,
                        .link: MobileFootnoteLink.url(for: .definition(label))
                    ]
                )
                result.append(reference)
            case let .image(alt, source, _):
                result.append(image(source: source, alt: alt, baseURL: baseURL, font: baseFont))
            case let .rawHTML(source):
                result.append(
                    NSAttributedString(
                        string: source,
                        attributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: max(7, baseFont.pointSize * 0.9), weight: .regular),
                            .foregroundColor: UIColor.black,
                            .backgroundColor: UIColor(white: 0.94, alpha: 1)
                        ]
                    )
                )
            case .softBreak:
                result.append(NSAttributedString(string: "\n", attributes: attributes(font: baseFont)))
            case .hardBreak:
                result.append(NSAttributedString(string: "\n", attributes: attributes(font: baseFont)))
            }
        }
        return result
    }

    private func image(source: String, alt: String, baseURL: URL?, font: UIFont) -> NSAttributedString {
        switch imageResolver.resolve(source: source, relativeTo: baseURL) {
        case let .local(url):
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                return placeholder(alt: alt, reason: .inaccessible, font: font)
            }
            let maximumWidth = configuration.contentWidth
            let scale = min(1, maximumWidth / max(1, image.size.width))
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0,
                y: -2,
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            return NSAttributedString(attachment: attachment)
        case let .placeholder(reason):
            return placeholder(alt: alt, reason: reason, font: font)
        }
    }

    private func placeholder(
        alt: String,
        reason: MobileImagePlaceholderReason,
        font: UIFont
    ) -> NSAttributedString {
        let label = alt.isEmpty ? reason.message : "\(reason.message): \(alt)"
        return NSAttributedString(
            string: "[\(label)]",
            attributes: [
                .font: variant(of: font, italic: true),
                .foregroundColor: UIColor(white: 0.45, alpha: 1),
                .backgroundColor: UIColor(white: 0.96, alpha: 1)
            ]
        )
    }

    private func paragraph(
        leftIndent: CGFloat = 0,
        firstLineIndent: CGFloat = 0,
        rightIndent: CGFloat = 0,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 8,
        lineSpacing: CGFloat = 2,
        tabStops: [NSTextTab] = []
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = leftIndent
        style.firstLineHeadIndent = firstLineIndent
        style.tailIndent = rightIndent == 0 ? 0 : -rightIndent
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineSpacing = lineSpacing
        style.tabStops = tabStops
        return style
    }

    private func footnoteParagraph() -> NSMutableParagraphStyle {
        paragraph(leftIndent: 18, firstLineIndent: 0, spacingAfter: 2, lineSpacing: 1.5)
    }

    private func attributes(
        font: UIFont,
        paragraph: NSParagraphStyle? = nil
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black
        ]
        if let paragraph { result[.paragraphStyle] = paragraph }
        return result
    }

    private enum FontVariant {
        case regular
        case demiBold
        case italic
        case demiBoldItalic
    }

    private func font(_ variant: FontVariant, size: CGFloat) -> UIFont {
        let name: String
        let fallback: UIFont.Weight
        switch variant {
        case .regular:
            name = "AvenirNext-Regular"
            fallback = .regular
        case .demiBold:
            name = "AvenirNext-DemiBold"
            fallback = .semibold
        case .italic:
            name = "AvenirNext-Italic"
            fallback = .regular
        case .demiBoldItalic:
            name = "AvenirNext-DemiBoldItalic"
            fallback = .semibold
        }
        return UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: fallback)
    }

    private func variant(of base: UIFont, bold: Bool = false, italic: Bool = false) -> UIFont {
        switch (bold, italic) {
        case (true, true): return font(.demiBoldItalic, size: base.pointSize)
        case (true, false): return font(.demiBold, size: base.pointSize)
        case (false, true): return font(.italic, size: base.pointSize)
        case (false, false): return base
        }
    }

    private func textAlignment(for alignment: TableAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

public enum MobileFootnoteTarget: Equatable, Sendable {
    case definition(String)
    case reference(String)
}

public enum MobileFootnoteLink {
    private static let scheme = "markdown-printer-footnote"

    public static func url(for target: MobileFootnoteTarget) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        switch target {
        case let .definition(label):
            components.host = "definition"
            components.queryItems = [URLQueryItem(name: "label", value: label)]
        case let .reference(label):
            components.host = "reference"
            components.queryItems = [URLQueryItem(name: "label", value: label)]
        }
        return components.url!
    }

    public static func target(from value: Any) -> MobileFootnoteTarget? {
        let url: URL?
        if let candidate = value as? URL {
            url = candidate
        } else if let candidate = value as? String {
            url = URL(string: candidate)
        } else {
            url = nil
        }
        guard let url,
              url.scheme == scheme,
              let label = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "label" })?.value else {
            return nil
        }
        switch url.host {
        case "definition": return .definition(label)
        case "reference": return .reference(label)
        default: return nil
        }
    }
}

private extension NSMutableAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif

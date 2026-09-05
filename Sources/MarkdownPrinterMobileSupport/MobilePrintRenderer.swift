#if canImport(UIKit)
import Foundation
import MarkdownPrinterCore
import UIKit

extension NSAttributedString.Key {
    static let mobileTableRow = NSAttributedString.Key("MarkdownPrinterMobileTableRow")
    static let mobileQuote = NSAttributedString.Key("MarkdownPrinterMobileQuote")
    static let mobileThematicBreak = NSAttributedString.Key("MarkdownPrinterMobileThematicBreak")
    static let mobileFootnoteReference = NSAttributedString.Key("MarkdownPrinterMobileFootnoteReference")
    static let mobileFootnoteDefinition = NSAttributedString.Key("MarkdownPrinterMobileFootnoteDefinition")
}

final class MobilePrintRenderer {
    let configuration: MobilePDFConfiguration
    private let presenter = MobileMarkdownPresenter()
    private let imageResolver: MobileImageResolver

    init(configuration: MobilePDFConfiguration, remoteImageCache: RemoteImageCache? = nil) {
        self.configuration = configuration
        self.imageResolver = MobileImageResolver(remoteImageCache: remoteImageCache)
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
        case let .codeBlock(_, code):
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
        case let .rawHTML(source):
            if let reference = HTMLImageReference(html: source) {
                let rendered = NSMutableAttributedString(attributedString: image(
                    source: reference.source,
                    alt: reference.alternativeText,
                    baseURL: baseURL,
                    font: font(.regular, size: configuration.bodyFontSize),
                    maximumWidth: reference.requestedWidth.map { CGFloat($0) }
                ))
                rendered.addAttribute(.paragraphStyle, value: paragraph(), range: rendered.fullRange)
                result.append(rendered)
                result.append(NSAttributedString(string: "\n"))
                break
            }
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
                    string: source + (source.hasSuffix("\n") ? "" : "\n"),
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
        let columnWidths = tableColumnWidths(for: allRows, columnCount: columnCount)
        let tabs = (0..<columnCount).map { index in
            let alignment = alignments[safe: index] ?? .leading
            let leading = columnWidths.prefix(index).reduce(0, +)
            let columnWidth = columnWidths[index]
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
            let cells = (0..<columnCount).map { column -> [NSAttributedString] in
                let cell = column < row.count ? row[column] : []
                let rendered = inline(
                    cell,
                    font: font(rowIndex == 0 ? .demiBold : .regular, size: 8.5),
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    maximumImageWidth: columnWidths[column] - 8
                )
                return wrappedLines(in: rendered, width: columnWidths[column] - 8)
            }
            let style = paragraph(
                spacingAfter: 0,
                lineSpacing: 1,
                tabStops: tabs
            )
            let rowStart = result.length
            let visualLineCount = max(1, cells.map(\.count).max() ?? 1)
            for visualLine in 0..<visualLineCount {
                let line = NSMutableAttributedString(string: "")
                for column in 0..<columnCount {
                    line.append(NSAttributedString(string: "\t"))
                    if visualLine < cells[column].count {
                        line.append(cells[column][visualLine])
                    }
                }
                line.append(NSAttributedString(string: "\n"))
                line.addAttribute(.paragraphStyle, value: style, range: line.fullRange)
                result.append(line)
            }
            result.addAttribute(
                .mobileTableRow,
                value: MobileTableRowDecoration(
                    columnWidths: columnWidths,
                    isHeader: rowIndex == 0
                ),
                range: NSRange(location: rowStart, length: result.length - rowStart)
            )
        }
        result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph(spacingAfter: 2)]))
    }

    private func tableColumnWidths(
        for rows: [[[InlineNode]]],
        columnCount: Int
    ) -> [CGFloat] {
        let minimumFraction = min(0.22, 0.54 / CGFloat(columnCount))
        let flexibleFraction = max(0, 1 - minimumFraction * CGFloat(columnCount))
        var demands = Array(repeating: CGFloat(1), count: columnCount)

        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<min(row.count, columnCount) {
                let cellFont = font(rowIndex == 0 ? .demiBold : .regular, size: 8.5)
                let text = plainText(from: row[column]) as NSString
                let measuredWidth = text.size(withAttributes: [.font: cellFont]).width + 8
                demands[column] = max(
                    demands[column],
                    min(measuredWidth, configuration.contentWidth * 2)
                )
            }
        }

        let totalDemand = demands.reduce(0, +)
        return demands.map { demand in
            (minimumFraction + flexibleFraction * demand / totalDemand) * configuration.contentWidth
        }
    }

    private func plainText(from nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case let .text(text), let .code(text):
                return text
            case let .rawHTML(source):
                return HTMLImageReference(html: source)?.alternativeText ?? source
            case let .emphasis(children), let .strong(children), let .underline(children),
                 let .strikethrough(children), let .link(children, _, _):
                return plainText(from: children)
            case let .footnoteReference(label):
                return label
            case let .image(alt, _, _):
                return alt
            case .softBreak, .hardBreak:
                return " "
            }
        }.joined()
    }

    private func wrappedLines(
        in attributed: NSAttributedString,
        width: CGFloat
    ) -> [NSAttributedString] {
        guard attributed.length > 0 else { return [NSAttributedString(string: "")] }
        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        let glyphs = layoutManager.glyphRange(for: container)
        var lines: [NSAttributedString] = []
        var glyphIndex = glyphs.location
        while glyphIndex < NSMaxRange(glyphs) {
            var lineGlyphs = NSRange()
            layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphs,
                withoutAdditionalLayout: true
            )
            let characters = layoutManager.characterRange(
                forGlyphRange: lineGlyphs,
                actualGlyphRange: nil
            )
            let line = NSMutableAttributedString(
                attributedString: attributed.attributedSubstring(from: characters)
            )
            while line.string.last == "\n" {
                line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1))
            }
            lines.append(line)
            glyphIndex = NSMaxRange(lineGlyphs)
        }
        return lines.isEmpty ? [attributed] : lines
    }

    private func inline(
        _ nodes: [InlineNode],
        font baseFont: UIFont,
        baseURL: URL?,
        footnoteNumbers: [String: Int],
        maximumImageWidth: CGFloat? = nil
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(string: "")
        for node in nodes {
            switch node {
            case let .text(text):
                result.append(NSAttributedString(string: text, attributes: attributes(font: baseFont)))
            case let .emphasis(children):
                result.append(inline(
                    children,
                    font: variant(of: baseFont, italic: true),
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    maximumImageWidth: maximumImageWidth
                ))
            case let .strong(children):
                result.append(inline(
                    children,
                    font: variant(of: baseFont, bold: true),
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    maximumImageWidth: maximumImageWidth
                ))
            case let .underline(children):
                let child = inline(
                    children,
                    font: baseFont,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    maximumImageWidth: maximumImageWidth
                )
                child.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: child.fullRange)
                result.append(child)
            case let .strikethrough(children):
                let child = inline(
                    children,
                    font: baseFont,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    maximumImageWidth: maximumImageWidth
                )
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
                let child = inline(
                    children,
                    font: baseFont,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    maximumImageWidth: maximumImageWidth
                )
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
                result.append(image(
                    source: source,
                    alt: alt,
                    baseURL: baseURL,
                    font: baseFont,
                    maximumWidth: maximumImageWidth
                ))
            case let .rawHTML(source):
                if let reference = HTMLImageReference(html: source) {
                    result.append(image(
                        source: reference.source,
                        alt: reference.alternativeText,
                        baseURL: baseURL,
                        font: baseFont,
                        maximumWidth: min(
                            maximumImageWidth ?? .greatestFiniteMagnitude,
                            reference.requestedWidth.map { CGFloat($0) } ?? .greatestFiniteMagnitude
                        )
                    ))
                } else {
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
                }
            case .softBreak:
                result.append(NSAttributedString(string: "\n", attributes: attributes(font: baseFont)))
            case .hardBreak:
                result.append(NSAttributedString(string: "\n", attributes: attributes(font: baseFont)))
            }
        }
        return result
    }

    private func image(
        source: String,
        alt: String,
        baseURL: URL?,
        font: UIFont,
        maximumWidth: CGFloat? = nil
    ) -> NSAttributedString {
        switch imageResolver.resolve(source: source, relativeTo: baseURL) {
        case let .local(url):
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                return placeholder(
                    alt: alt,
                    source: source,
                    reason: .inaccessible,
                    font: font
                )
            }
            let maximumWidth = min(configuration.contentWidth, maximumWidth ?? .greatestFiniteMagnitude)
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
            return placeholder(
                alt: alt,
                source: source,
                reason: reason,
                font: font
            )
        }
    }

    private func placeholder(
        alt: String,
        source: String,
        reason: MobileImagePlaceholderReason,
        font: UIFont
    ) -> NSAttributedString {
        let offersDownload = reason == .remote && imageResolver.remoteImageCache != nil
        let message = offersDownload ? "Remote image — tap to download" : reason.message
        let label = alt.isEmpty ? message : "\(message): \(alt)"
        var attributes: [NSAttributedString.Key: Any] = [
            .font: variant(of: font, italic: true),
            .foregroundColor: UIColor(white: 0.45, alpha: 1),
            .backgroundColor: UIColor(white: 0.96, alpha: 1)
        ]
        if offersDownload {
            attributes[.link] = RemoteImageActionURL.downloadURL(for: source)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(
            string: "[\(label)]",
            attributes: attributes
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

final class MobileTableRowDecoration: NSObject {
    let columnWidths: [CGFloat]
    let isHeader: Bool

    init(columnWidths: [CGFloat], isHeader: Bool) {
        self.columnWidths = columnWidths
        self.isHeader = isHeader
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

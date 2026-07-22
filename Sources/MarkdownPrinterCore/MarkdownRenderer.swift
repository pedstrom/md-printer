import AppKit

public final class MarkdownRenderer {
    public let configuration: RendererConfiguration
    private let parser: MarkdownParser
    private let fonts: FontBook

    public init(
        configuration: RendererConfiguration = RendererConfiguration(),
        parser: MarkdownParser = MarkdownParser()
    ) {
        self.configuration = configuration
        self.parser = parser
        self.fonts = FontBook(configuration: configuration)
    }

    public func render(document: MarkdownDocument) -> NSAttributedString {
        render(blocks: parser.parse(document.markdown), baseURL: document.baseURL)
    }

    public func render(markdown: String, baseURL: URL? = nil) -> NSAttributedString {
        render(blocks: parser.parse(markdown), baseURL: baseURL)
    }

    public func render(blocks: [MarkdownBlock], baseURL: URL? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0, usesBlankLine(after: blocks[index - 1], before: block) {
                result.append(NSAttributedString(string: "\n"))
            }
            append(block: block, to: result, baseURL: baseURL)
        }
        return result
    }

    private func usesBlankLine(after previous: MarkdownBlock, before current: MarkdownBlock) -> Bool {
        if case let .heading(level, _) = previous, level >= 2 {
            return false
        }
        if case .paragraph = previous, case .list = current {
            return false
        }
        return true
    }

    private func append(block: MarkdownBlock, to result: NSMutableAttributedString, baseURL: URL?) {
        switch block {
        case let .heading(level, content):
            let size = configuration.headingSize(for: level)
            let paragraph = paragraphStyle(spacingAfter: level <= 2 ? 12 : 8)
            let rendered = renderInline(content, font: fonts.bold(size: size), baseURL: baseURL)
            rendered.addAttribute(.paragraphStyle, value: paragraph, range: rendered.fullRange)
            result.append(rendered)
            result.append(NSAttributedString(string: "\n"))

        case let .paragraph(content):
            let rendered = renderInline(content, font: fonts.regular(size: configuration.bodyFontSize), baseURL: baseURL)
            rendered.addAttribute(.paragraphStyle, value: paragraphStyle(), range: rendered.fullRange)
            result.append(rendered)
            result.append(NSAttributedString(string: "\n"))

        case let .blockquote(content):
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(1.5, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(configuration.secondaryTextColor, for: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
            let paragraph = paragraphStyle()
            paragraph.textBlocks = [block]
            let quote = renderInline(content, font: fonts.italic(size: configuration.bodyFontSize), baseURL: baseURL)
            quote.addAttribute(.paragraphStyle, value: paragraph, range: quote.fullRange)
            result.append(quote)
            result.append(NSAttributedString(string: "\n"))

        case let .list(items, ordered, start):
            for (offset, item) in items.enumerated() {
                let prefix: String
                if let checked = item.checked {
                    prefix = checked ? "☑︎  " : "☐  "
                } else if ordered {
                    prefix = "\(start + offset).  "
                } else {
                    prefix = "•  "
                }
                let line = NSMutableAttributedString(
                    string: prefix,
                    attributes: bodyAttributes(font: fonts.bold(size: configuration.bodyFontSize))
                )
                line.append(renderInline(item.content, font: fonts.regular(size: configuration.bodyFontSize), baseURL: baseURL))
                let paragraph = paragraphStyle(spacingAfter: 4)
                paragraph.firstLineHeadIndent = 8
                paragraph.headIndent = 30
                line.addAttribute(.paragraphStyle, value: paragraph, range: line.fullRange)
                result.append(line)
                result.append(NSAttributedString(string: "\n"))
            }

        case let .codeBlock(_, code):
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(configuration.codeBlockPadding, type: .absoluteValueType, for: .padding)
            block.backgroundColor = configuration.codeBackgroundColor
            let paragraph = paragraphStyle(spacingAfter: 0)
            paragraph.textBlocks = [block]
            let rendered = NSMutableAttributedString(
                string: code.isEmpty ? " " : code,
                attributes: [
                    .font: fonts.monospaced(size: configuration.bodyFontSize - 1),
                    .foregroundColor: configuration.textColor,
                    .paragraphStyle: paragraph
                ]
            )
            result.append(rendered)
            result.append(NSAttributedString(
                string: "\n",
                attributes: [.paragraphStyle: paragraphStyle(spacingAfter: 10)]
            ))

        case .thematicBreak:
            let line = NSMutableAttributedString(
                string: String(repeating: "─", count: 52) + "\n",
                attributes: [
                    .font: fonts.regular(size: 8),
                    .foregroundColor: configuration.tableBorderColor,
                    .paragraphStyle: paragraphStyle(spacingAfter: 8)
                ]
            )
            result.append(line)

        case let .table(headers, alignments, rows):
            appendTable(headers: headers, alignments: alignments, rows: rows, to: result, baseURL: baseURL)
        }
    }

    private func appendTable(
        headers: [[InlineNode]],
        alignments: [TableAlignment],
        rows: [[[InlineNode]]],
        to result: NSMutableAttributedString,
        baseURL: URL?
    ) {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let allRows = [headers] + rows
        let columnWidths = tableColumnWidths(for: allRows, columnCount: columnCount)
        for (rowIndex, row) in allRows.enumerated() {
            for columnIndex in 0..<columnCount {
                let nodes = columnIndex < row.count ? row[columnIndex] : []
                let font = rowIndex == 0
                    ? fonts.bold(size: configuration.bodyFontSize - 0.5)
                    : fonts.regular(size: configuration.bodyFontSize - 0.5)
                let cell = renderInline(nodes, font: font, baseURL: baseURL)
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setContentWidth(columnWidths[columnIndex], type: .percentageValueType)
                block.setWidth(0.75, type: .absoluteValueType, for: .border)
                block.setBorderColor(configuration.tableBorderColor)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 {
                    block.backgroundColor = configuration.codeBackgroundColor
                }
                let paragraph = paragraphStyle(spacingAfter: 0)
                paragraph.textBlocks = [block]
                paragraph.alignment = textAlignment(
                    for: columnIndex < alignments.count ? alignments[columnIndex] : .leading
                )
                cell.addAttribute(.paragraphStyle, value: paragraph, range: cell.fullRange)
                result.append(cell)
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
            }
        }
    }

    private func tableColumnWidths(for rows: [[[InlineNode]]], columnCount: Int) -> [CGFloat] {
        let minimumFraction = min(0.22, 0.54 / CGFloat(columnCount))
        let flexibleFraction = max(0, 1 - minimumFraction * CGFloat(columnCount))
        var demands = Array(repeating: CGFloat(1), count: columnCount)

        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<min(row.count, columnCount) {
                let font = rowIndex == 0
                    ? fonts.bold(size: configuration.bodyFontSize - 0.5)
                    : fonts.regular(size: configuration.bodyFontSize - 0.5)
                let text = plainText(from: row[columnIndex]) as NSString
                let measuredWidth = text.size(withAttributes: [.font: font]).width + 12
                demands[columnIndex] = max(
                    demands[columnIndex],
                    min(measuredWidth, configuration.contentWidth * 2)
                )
            }
        }

        let totalDemand = demands.reduce(0, +)
        return demands.map { demand in
            (minimumFraction + flexibleFraction * demand / totalDemand) * 100
        }
    }

    private func plainText(from nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case let .text(text), let .code(text):
                return text
            case let .emphasis(children),
                 let .strong(children),
                 let .underline(children),
                 let .strikethrough(children):
                return plainText(from: children)
            case let .link(children, _):
                return plainText(from: children)
            case let .image(alt, _):
                return alt
            case .lineBreak:
                return " "
            }
        }.joined()
    }

    private func renderInline(_ nodes: [InlineNode], font: NSFont, baseURL: URL?) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for node in nodes {
            switch node {
            case let .text(text):
                result.append(NSAttributedString(string: text, attributes: bodyAttributes(font: font)))
            case let .emphasis(children):
                let child = renderInline(children, font: italicVariant(of: font), baseURL: baseURL)
                result.append(child)
            case let .strong(children):
                let child = renderInline(children, font: boldVariant(of: font), baseURL: baseURL)
                result.append(child)
            case let .underline(children):
                let child = renderInline(children, font: font, baseURL: baseURL)
                child.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: child.fullRange)
                result.append(child)
            case let .strikethrough(children):
                let child = renderInline(children, font: font, baseURL: baseURL)
                child.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: child.fullRange)
                result.append(child)
            case let .code(code):
                result.append(NSAttributedString(
                    string: code,
                    attributes: [
                        .font: fonts.monospaced(size: font.pointSize - 0.5),
                        .foregroundColor: configuration.textColor,
                        .backgroundColor: configuration.codeBackgroundColor
                    ]
                ))
            case let .link(children, destination):
                let child = renderInline(children, font: font, baseURL: baseURL)
                child.addAttributes([
                    .foregroundColor: configuration.accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: linkDestination(destination, baseURL: baseURL)
                ], range: child.fullRange)
                result.append(child)
            case let .image(alt, source):
                result.append(imageAttachment(alt: alt, source: source, baseURL: baseURL, font: font))
            case .lineBreak:
                result.append(NSAttributedString(string: "\n", attributes: bodyAttributes(font: font)))
            }
        }
        return result
    }

    private func linkDestination(_ destination: String, baseURL: URL?) -> Any {
        guard let parsedURL = URL(string: destination) else { return destination }
        guard parsedURL.scheme == nil,
              !destination.hasPrefix("#"),
              let baseURL,
              let resolvedURL = URL(string: destination, relativeTo: baseURL)?.absoluteURL else {
            return parsedURL
        }
        return resolvedURL
    }

    private func imageAttachment(alt: String, source: String, baseURL: URL?, font: NSFont) -> NSAttributedString {
        guard let url = imageURL(source: source, baseURL: baseURL),
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            return NSAttributedString(
                string: "[Image: \(alt.isEmpty ? source : alt)]",
                attributes: [
                    .font: fonts.italic(size: font.pointSize),
                    .foregroundColor: configuration.secondaryTextColor
                ]
            )
        }

        let maximumWidth = min(configuration.maximumImageWidth, configuration.contentWidth)
        let scale = min(1, maximumWidth / image.size.width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: -4,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        return NSAttributedString(attachment: attachment)
    }

    private func imageURL(source: String, baseURL: URL?) -> URL? {
        if let url = URL(string: source), url.isFileURL {
            return url
        }
        guard !source.lowercased().hasPrefix("http://"),
              !source.lowercased().hasPrefix("https://") else { return nil }
        let decoded = source.removingPercentEncoding ?? source
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        return baseURL?.appendingPathComponent(decoded)
    }

    private func paragraphStyle(spacingAfter: CGFloat = 8) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = spacingAfter
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private func bodyAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: configuration.textColor]
    }

    private func boldVariant(of font: NSFont) -> NSFont {
        if NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
            return fonts.boldItalic(size: font.pointSize)
        }
        return fonts.bold(size: font.pointSize)
    }

    private func italicVariant(of font: NSFont) -> NSFont {
        if NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
            return fonts.boldItalic(size: font.pointSize)
        }
        return fonts.italic(size: font.pointSize)
    }

    private func textAlignment(for alignment: TableAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

private extension NSMutableAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}

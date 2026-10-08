#if canImport(AppKit)
import AppKit

public final class MarkdownRenderer {
    public let configuration: RendererConfiguration
    public let remoteImageCache: RemoteImageCache?
    private let parser: MarkdownParser
    private let fonts: FontBook
    private let tracksRevisions: Bool
    private let imageReferencesOnly: Bool
    private let unavailableImageAttachment: ((String, CGFloat) -> NSTextAttachment)?

    public init(
        configuration: RendererConfiguration = RendererConfiguration(),
        parser: MarkdownParser = MarkdownParser(),
        remoteImageCache: RemoteImageCache? = nil,
        unavailableImageAttachment: ((String, CGFloat) -> NSTextAttachment)? = nil,
        tracksRevisions: Bool = false,
        imageReferencesOnly: Bool = false
    ) {
        self.tracksRevisions = tracksRevisions
        self.imageReferencesOnly = imageReferencesOnly
        self.configuration = configuration
        self.parser = parser
        self.remoteImageCache = remoteImageCache
        self.fonts = FontBook(configuration: configuration)
        self.unavailableImageAttachment = unavailableImageAttachment
    }

    public func render(document: MarkdownDocument) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: render(blocks: document.blocks, baseURL: document.baseURL))
        MarkdownSectionCatalog(blocks: document.blocks).annotate(text, sourceURL: document.sourceURL)
        return text
    }

    public func render(document: MarkdownDocument, original: MarkdownDocument?) -> RevisionRenderedText {
        guard let original else { return RevisionRenderedText(text: render(document: document), decorations: RevisionDecorations()) }
        let currentRenderer = MarkdownRenderer(configuration: configuration, remoteImageCache: remoteImageCache,
                                               unavailableImageAttachment: unavailableImageAttachment, tracksRevisions: true)
        let originalRenderer = MarkdownRenderer(configuration: configuration, tracksRevisions: true, imageReferencesOnly: true)
        return RevisionFormatter.format(current: currentRenderer.render(document: document),
                                        original: originalRenderer.render(document: original))
    }

    private func markRevisionUnit(_ text: NSMutableAttributedString, range: NSRange, kind: String) {
        guard tracksRevisions, range.length > 0 else { return }
        text.addAttributes([.revisionBlock: UUID().uuidString, .revisionKind: kind], range: range)
    }

    public func render(markdown: String, baseURL: URL? = nil) -> NSAttributedString {
        render(blocks: parser.parse(markdown), baseURL: baseURL)
    }

    public func render(blocks: [MarkdownBlock], baseURL: URL? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let footnotes = FootnoteCatalog(blocks: blocks)
        let bodyBlocks = blocks.filter { block in
            if case .footnoteDefinition = block { return false }
            return true
        }
        for (index, block) in bodyBlocks.enumerated() {
            if index > 0, usesBlankLine(after: bodyBlocks[index - 1], before: block) {
                result.append(NSAttributedString(string: "\n"))
            }
            append(block: block, to: result, baseURL: baseURL, footnotes: footnotes)
        }
        if !footnotes.entries.isEmpty {
            if !bodyBlocks.isEmpty { result.append(NSAttributedString(string: "\n")) }
            appendFootnotes(footnotes, to: result, baseURL: baseURL)
        }
        MarkdownSectionCatalog(blocks: blocks).annotate(result)
        return result
    }

    private func usesBlankLine(after previous: MarkdownBlock, before current: MarkdownBlock) -> Bool {
        if case .heading = previous { return false }
        if case .heading = current { return false }
        if case .paragraph = previous, case .list = current {
            return false
        }
        return true
    }

    private func append(
        block: MarkdownBlock,
        to result: NSMutableAttributedString,
        baseURL: URL?,
        footnotes: FootnoteCatalog,
        listDepth: Int = 0
    ) {
        let unitStart = result.length
        defer {
            if tracksRevisions {
                switch block {
                case .list, .table:
                    result.addAttribute(.revisionContainer, value: UUID().uuidString,
                                        range: NSRange(location: unitStart, length: result.length - unitStart))
                default: break
                }
            }
            let kind: String?
            switch block {
            case let .heading(level, _): kind = "heading:\(level)"
            case .paragraph: kind = "paragraph"
            case let .codeBlock(language, _): kind = "code:\(language ?? "")"
            case .rawHTML: kind = "html"
            case .thematicBreak: kind = "rule"
            default: kind = nil
            }
            if let kind {
                let range = NSRange(location: unitStart, length: result.length - unitStart)
                markRevisionUnit(result, range: range, kind: kind)
                if tracksRevisions, kind.hasPrefix("code:") || kind == "html" {
                    result.addAttribute(.revisionLiteral, value: true, range: range)
                }
            }
        }
        switch block {
        case let .heading(level, content):
            let size = configuration.headingSize(for: level)
            let style = HeadingTypography(level: level)
            let scale = configuration.bodyFontSize / 10
            let paragraph = paragraphStyle(spacingAfter: style.spacingAfter * scale)
            paragraph.paragraphSpacingBefore = style.additionalSpacingBefore(in: result, scale: scale)
            paragraph.headerLevel = level
            let rendered = renderInline(content, font: fonts.heading(level: level, size: size), baseURL: baseURL, footnotes: footnotes)
            rendered.addAttribute(.paragraphStyle, value: paragraph, range: rendered.fullRange)
            result.append(rendered)
            result.append(NSAttributedString(string: "\n"))
            result.addAttribute(.markdownSectionAnchor, value: UUID().uuidString, range: NSRange(location: result.length - rendered.length - 1, length: rendered.length + 1))

        case let .paragraph(content):
            let rendered = renderInline(content, font: fonts.regular(size: configuration.bodyFontSize), baseURL: baseURL, footnotes: footnotes)
            rendered.addAttribute(.paragraphStyle, value: paragraphStyle(), range: rendered.fullRange)
            result.append(rendered)
            result.append(NSAttributedString(string: "\n"))

        case let .blockquote(blocks):
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(1.5, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(configuration.secondaryTextColor, for: .minX)
            block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
            let quote = NSMutableAttributedString()
            for child in blocks {
                append(block: child, to: quote, baseURL: baseURL, footnotes: footnotes)
            }
            let paragraph = paragraphStyle()
            paragraph.textBlocks = [block]
            quote.addAttributes([
                .paragraphStyle: paragraph,
                .font: fonts.italic(size: configuration.bodyFontSize)
            ], range: quote.fullRange)
            if tracksRevisions {
                quote.enumerateAttribute(.revisionKind, in: quote.fullRange) { kind, range, _ in
                    guard let kind = kind as? String else { return }
                    quote.addAttribute(.revisionKind, value: kind + ":quote", range: range)
                }
            }
            result.append(quote)

        case let .list(items, ordered, start, tight):
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
                let paragraph = paragraphStyle(spacingAfter: tight ? 4 : 10)
                paragraph.firstLineHeadIndent = 8 + CGFloat(listDepth * 22)
                paragraph.headIndent = 30 + CGFloat(listDepth * 22)
                line.addAttribute(.paragraphStyle, value: paragraph, range: line.fullRange)
                for (childIndex, child) in item.blocks.enumerated() {
                    let start = line.length
                    append(
                        block: child,
                        to: line,
                        baseURL: baseURL,
                        footnotes: footnotes,
                        listDepth: child.isList ? listDepth + 1 : listDepth
                    )
                    if !child.isList {
                        let childParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle
                            ?? paragraph
                        if childIndex > 0 {
                            childParagraph.firstLineHeadIndent = childParagraph.headIndent
                        }
                        line.addAttribute(
                            .paragraphStyle,
                            value: childParagraph,
                            range: NSRange(location: start, length: line.length - start)
                        )
                    }
                }
                if tracksRevisions {
                    let itemID = UUID().uuidString
                    line.enumerateAttribute(.revisionListItem, in: line.fullRange) { marker, range, _ in
                        if marker == nil { line.addAttribute(.revisionListItem, value: itemID, range: range) }
                    }
                    line.enumerateAttribute(.revisionKind, in: line.fullRange) { kind, range, _ in
                        guard let kind = kind as? String else { return }
                        line.addAttribute(.revisionKind, value: kind + ":list:\(ordered):\(start):\(String(describing: item.checked))", range: range)
                    }
                }
                if line.string.hasSuffix("\n") {
                    line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1))
                }
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

        case let .rawHTML(source):
            if let reference = HTMLImageReference(html: source) {
                let rendered = NSMutableAttributedString(attributedString: imageAttachment(
                    alt: reference.alternativeText,
                    source: reference.source,
                    baseURL: baseURL,
                    font: fonts.regular(size: configuration.bodyFontSize),
                    requestedWidth: reference.requestedWidth.map { CGFloat($0) }
                ))
                rendered.addAttribute(
                    NSAttributedString.Key.paragraphStyle,
                    value: paragraphStyle(),
                    range: rendered.fullRange
                )
                result.append(rendered)
                result.append(NSAttributedString(string: "\n"))
                break
            }
            let block = NSTextBlock()
            block.setContentWidth(100, type: .percentageValueType)
            block.setWidth(configuration.codeBlockPadding, type: .absoluteValueType, for: .padding)
            block.backgroundColor = configuration.codeBackgroundColor
            let paragraph = paragraphStyle(spacingAfter: 0)
            paragraph.textBlocks = [block]
            let rendered = NSMutableAttributedString(
                string: source.isEmpty ? " " : source.trimmingCharacters(in: .newlines),
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

        case .footnoteDefinition:
            break

        case let .table(headers, alignments, rows):
            appendTable(
                headers: headers,
                alignments: alignments,
                rows: rows,
                to: result,
                baseURL: baseURL,
                footnotes: footnotes
            )
        }
    }

    private func appendFootnotes(
        _ footnotes: FootnoteCatalog,
        to result: NSMutableAttributedString,
        baseURL: URL?
    ) {
        let footnoteSize = max(7.5, configuration.bodyFontSize * 0.8)
        result.append(NSAttributedString(
            string: "────────────\n",
            attributes: [
                .font: fonts.regular(size: 6),
                .foregroundColor: configuration.tableBorderColor,
                .paragraphStyle: paragraphStyle(spacingAfter: 4)
            ]
        ))

        for entry in footnotes.entries {
            let line = NSMutableAttributedString(
                string: "\(entry.number).",
                attributes: [
                    .font: fonts.bold(size: footnoteSize),
                    .foregroundColor: configuration.accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .markdownFootnoteDefinition: entry.label
                ]
            )
            line.append(NSAttributedString(
                string: " ",
                attributes: bodyAttributes(font: fonts.regular(size: footnoteSize))
            ))
            line.append(renderInline(
                entry.content,
                font: fonts.regular(size: footnoteSize),
                baseURL: baseURL,
                footnotes: footnotes
            ))
            let paragraph = paragraphStyle(spacingAfter: 4)
            paragraph.lineSpacing = 1.5
            paragraph.headIndent = 18
            line.addAttribute(.paragraphStyle, value: paragraph, range: line.fullRange)
            markRevisionUnit(line, range: line.fullRange, kind: "footnote:" + entry.label)
            result.append(line)
            result.append(NSAttributedString(string: "\n"))
        }
    }

    private func appendTable(
        headers: [[InlineNode]],
        alignments: [TableAlignment],
        rows: [[[InlineNode]]],
        to result: NSMutableAttributedString,
        baseURL: URL?,
        footnotes: FootnoteCatalog
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
        let cellPadding: CGFloat = 6
        let borderWidth: CGFloat = 0.75
        for (rowIndex, row) in allRows.enumerated() {
            for columnIndex in 0..<columnCount {
                let nodes = columnIndex < row.count ? row[columnIndex] : []
                let font = rowIndex == 0
                    ? fonts.bold(size: configuration.bodyFontSize - 0.5)
                    : fonts.regular(size: configuration.bodyFontSize - 0.5)
                let cell = renderInline(nodes, font: font, baseURL: baseURL, footnotes: footnotes)
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setContentWidth(columnWidths[columnIndex], type: .percentageValueType)
                block.setWidth(borderWidth, type: .absoluteValueType, for: .border)
                block.setBorderColor(configuration.tableBorderColor)
                block.setWidth(cellPadding, type: .absoluteValueType, for: .padding)
                let imageWidth = configuration.contentWidth * columnWidths[columnIndex] / 100
                    - 2 * (cellPadding + borderWidth)
                fitTableImages(in: cell, maximumWidth: max(1, imageWidth))
                if rowIndex == 0 {
                    block.backgroundColor = configuration.codeBackgroundColor
                }
                let paragraph = paragraphStyle(spacingAfter: 0)
                paragraph.textBlocks = [block]
                paragraph.alignment = textAlignment(
                    for: columnIndex < alignments.count ? alignments[columnIndex] : .leading
                )
                cell.addAttribute(.paragraphStyle, value: paragraph, range: cell.fullRange)
                let cellStart = result.length
                result.append(cell)
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
                // Include the generated separator so an empty cell still has
                // an identity and never shifts a later cell into its column.
                markRevisionUnit(result, range: NSRange(location: cellStart, length: result.length - cellStart), kind: "cell")
            }
        }
    }

    private func fitTableImages(in cell: NSMutableAttributedString, maximumWidth: CGFloat) {
        // Fit the final attachments so nested styles, linked images, and HTML images share the same limit.
        cell.enumerateAttribute(.attachment, in: cell.fullRange) { value, _, _ in
            guard let attachment = value as? NSTextAttachment,
                  attachment.bounds.width > maximumWidth else { return }
            let scale = maximumWidth / attachment.bounds.width
            var bounds = attachment.bounds
            bounds.size.width *= scale
            bounds.size.height *= scale
            attachment.bounds = bounds
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
            case let .text(text), let .code(text), let .rawHTML(text):
                return text
            case let .emphasis(children),
                 let .strong(children),
                 let .underline(children),
                 let .strikethrough(children):
                return plainText(from: children)
            case let .link(children, _, _):
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

    private func renderInline(
        _ nodes: [InlineNode],
        font: NSFont,
        baseURL: URL?,
        footnotes: FootnoteCatalog
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for node in nodes {
            switch node {
            case let .text(text):
                result.append(NSAttributedString(string: text, attributes: bodyAttributes(font: font)))
            case let .emphasis(children):
                let child = renderInline(children, font: italicVariant(of: font), baseURL: baseURL, footnotes: footnotes)
                markRevisionTrait("emphasis", in: child)
                result.append(child)
            case let .strong(children):
                let child = renderInline(children, font: boldVariant(of: font), baseURL: baseURL, footnotes: footnotes)
                markRevisionTrait("strong", in: child)
                result.append(child)
            case let .underline(children):
                let child = renderInline(children, font: font, baseURL: baseURL, footnotes: footnotes)
                child.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: child.fullRange)
                result.append(child)
            case let .strikethrough(children):
                let child = renderInline(children, font: font, baseURL: baseURL, footnotes: footnotes)
                child.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: child.fullRange)
                result.append(child)
            case let .code(code):
                let codeStart = result.length
                result.append(NSAttributedString(
                    string: code,
                    attributes: [
                        .font: fonts.monospaced(size: font.pointSize - 0.5),
                        .foregroundColor: configuration.textColor,
                        .backgroundColor: configuration.codeBackgroundColor
                    ]
                ))
                if tracksRevisions { result.addAttribute(.revisionLiteral, value: true, range: NSRange(location: codeStart, length: result.length - codeStart)) }
            case let .link(children, destination, title):
                let child = renderInline(children, font: font, baseURL: baseURL, footnotes: footnotes)
                child.addAttributes([
                    .foregroundColor: configuration.accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: linkDestination(destination, baseURL: baseURL)
                ], range: child.fullRange)
                if tracksRevisions { child.addAttribute(.revisionReference, value: destination + "|" + (title ?? ""), range: child.fullRange) }
                result.append(child)
            case let .footnoteReference(label):
                guard let number = footnotes.number(for: label) else {
                    result.append(NSAttributedString(
                        string: "[^\(label)]",
                        attributes: bodyAttributes(font: font)
                    ))
                    continue
                }
                let referenceSize = max(7, font.pointSize * 0.72)
                result.append(NSAttributedString(
                    string: String(number),
                    attributes: [
                        .font: fonts.bold(size: referenceSize),
                        .foregroundColor: configuration.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .baselineOffset: max(2, font.pointSize * 0.32),
                        .markdownFootnoteReference: label
                    ]
                ))
            case let .image(alt, source, title):
                let image = NSMutableAttributedString(attributedString: imageAttachment(alt: alt, source: source, baseURL: baseURL, font: font))
                if tracksRevisions { image.addAttribute(.revisionImage, value: source + "|" + alt + "|" + (title ?? ""), range: image.fullRange) }
                result.append(image)
            case let .rawHTML(source):
                if let reference = HTMLImageReference(html: source) {
                    result.append(imageAttachment(
                        alt: reference.alternativeText,
                        source: reference.source,
                        baseURL: baseURL,
                        font: font,
                        requestedWidth: reference.requestedWidth.map { CGFloat($0) }
                    ))
                } else {
                    result.append(NSAttributedString(
                        string: source,
                        attributes: [
                            .font: fonts.monospaced(size: font.pointSize - 0.5),
                            .foregroundColor: configuration.textColor,
                            .backgroundColor: configuration.codeBackgroundColor
                        ]
                    ))
                }
            case .softBreak:
                result.append(NSAttributedString(string: "\n", attributes: bodyAttributes(font: font)))
            case .hardBreak:
                var attributes = bodyAttributes(font: font)
                if tracksRevisions { attributes[.revisionHardBreak] = true }
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    private func markRevisionTrait(_ trait: String, in text: NSMutableAttributedString) {
        guard tracksRevisions else { return }
        // A container can supply its own font after rendering children. Keep
        // source styles separately so comparison still sees nested emphasis.
        text.enumerateAttribute(.revisionTraits, in: text.fullRange) { value, range, _ in
            var traits = Set(value as? [String] ?? [])
            traits.insert(trait)
            text.addAttribute(.revisionTraits, value: traits.sorted(), range: range)
        }
    }

    private func linkDestination(_ destination: String, baseURL: URL?) -> Any {
        MarkdownLinkTarget.resolvedURL(for: destination, relativeTo: baseURL) as Any? ?? destination
    }

    private func imageAttachment(
        alt: String,
        source: String,
        baseURL: URL?,
        font: NSFont,
        requestedWidth: CGFloat? = nil
    ) -> NSAttributedString {
        if imageReferencesOnly {
            let text = NSMutableAttributedString(attachment: NSTextAttachment())
            text.addAttribute(.revisionImage, value: source + "|" + alt + "|" + String(describing: requestedWidth), range: text.fullRange)
            return text
        }
        let maximumWidth = min(
            min(configuration.maximumImageWidth, configuration.contentWidth),
            requestedWidth ?? .greatestFiniteMagnitude
        )
        let remoteURL = RemoteImageReference.remoteURL(from: source)
        let resolvedURL = remoteURL == nil
            ? imageURL(source: source, baseURL: baseURL)
            : remoteImageCache?.cachedFileURL(for: source)
        guard let url = resolvedURL,
              let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            if let unavailableImageAttachment {
                return NSAttributedString(attachment: unavailableImageAttachment(source, maximumWidth))
            }
            let placeholder = NSMutableAttributedString(attributedString: imagePlaceholder(
                alt: alt,
                source: source,
                font: font,
                offersDownload: remoteURL != nil && remoteImageCache != nil
            ))
            if tracksRevisions { placeholder.addAttribute(.revisionImage, value: source + "|" + alt + "|" + String(describing: requestedWidth), range: placeholder.fullRange) }
            return placeholder
        }

        let scale = min(1, maximumWidth / image.size.width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: -4,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let text = NSMutableAttributedString(attachment: attachment)
        if tracksRevisions { text.addAttribute(.revisionImage, value: source + "|" + alt + "|" + String(describing: requestedWidth), range: text.fullRange) }
        return text
    }

    private func imagePlaceholder(
        alt: String,
        source: String,
        font: NSFont,
        offersDownload: Bool
    ) -> NSAttributedString {
        let description = alt.isEmpty ? source : alt
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.italic(size: font.pointSize),
            .foregroundColor: configuration.secondaryTextColor
        ]
        let label: String
        if offersDownload {
            label = "[Remote image — click to download: \(description)]"
            attributes[.link] = RemoteImageActionURL.downloadURL(for: source)
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            label = "[Image: \(description)]"
        }
        return NSAttributedString(string: label, attributes: attributes)
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
        if NSFontManager.shared.traits(of: font).contains(.boldFontMask) { return font }
        if NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
            return fonts.boldItalic(size: font.pointSize)
        }
        return fonts.bold(size: font.pointSize)
    }

    private func italicVariant(of font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private func textAlignment(for alignment: TableAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

private struct FootnoteCatalog {
    let entries: [FootnoteEntry]
    private let numberByLabel: [String: Int]

    init(blocks: [MarkdownBlock]) {
        var definitions: [String: [InlineNode]] = [:]
        var definitionOrder: [String] = []
        for block in blocks {
            guard case let .footnoteDefinition(label, content) = block,
                  definitions[label] == nil else { continue }
            definitions[label] = content
            definitionOrder.append(label)
        }

        var orderedLabels: [String] = []
        var seenLabels: Set<String> = []
        for block in blocks where !block.isFootnoteDefinition {
            for label in block.footnoteReferenceLabels
                where definitions[label] != nil && seenLabels.insert(label).inserted {
                orderedLabels.append(label)
            }
        }
        for label in definitionOrder where seenLabels.insert(label).inserted {
            orderedLabels.append(label)
        }

        let entries = orderedLabels.enumerated().compactMap { offset, label in
            definitions[label].map {
                FootnoteEntry(label: label, number: offset + 1, content: $0)
            }
        }
        self.entries = entries
        self.numberByLabel = Dictionary(uniqueKeysWithValues: entries.map { ($0.label, $0.number) })
    }

    func number(for label: String) -> Int? {
        numberByLabel[label]
    }
}

private struct FootnoteEntry {
    let label: String
    let number: Int
    let content: [InlineNode]
}

private extension MarkdownBlock {
    var isList: Bool {
        if case .list = self { return true }
        return false
    }

    var isFootnoteDefinition: Bool {
        if case .footnoteDefinition = self { return true }
        return false
    }

    var footnoteReferenceLabels: [String] {
        switch self {
        case let .heading(_, content),
             let .paragraph(content),
             let .footnoteDefinition(_, content):
            return content.footnoteReferenceLabels
        case let .blockquote(blocks):
            return blocks.flatMap(\.footnoteReferenceLabels)
        case let .list(items, _, _, _):
            return items.flatMap { $0.blocks.flatMap(\.footnoteReferenceLabels) }
        case let .table(headers, _, rows):
            return (headers + rows.flatMap { $0 }).flatMap(\.footnoteReferenceLabels)
        case .codeBlock, .rawHTML, .thematicBreak:
            return []
        }
    }
}

private extension Array where Element == InlineNode {
    var footnoteReferenceLabels: [String] {
        flatMap { node in
            switch node {
            case let .footnoteReference(label):
                return [label]
            case let .emphasis(children),
                 let .strong(children),
                 let .underline(children),
                 let .strikethrough(children),
                 let .link(children, _, _):
                return children.footnoteReferenceLabels
            case .text, .code, .image, .rawHTML, .softBreak, .hardBreak:
                return []
            }
        }
    }
}

extension NSAttributedString.Key {
    public static let markdownFootnoteReference = NSAttributedString.Key(
        "MarkdownPrinterFootnoteReference"
    )
    public static let markdownFootnoteDefinition = NSAttributedString.Key(
        "MarkdownPrinterFootnoteDefinition"
    )
}

private extension NSMutableAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
#endif

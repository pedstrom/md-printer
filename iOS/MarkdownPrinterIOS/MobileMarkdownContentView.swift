import MarkdownPrinterCore
import MarkdownPrinterMobileSupport
import SwiftUI
import UIKit

struct MobileMarkdownContentView: View {
    let presentation: MobileMarkdownPresentation
    let selectedMatch: MarkdownSearchMatch?
    let requestedAnchor: String?
    let onOpenURL: (URL) -> Void
    let onTapBackground: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(presentation.blocks) { block in
                        MobileRenderedBlockView(
                            block: block.block,
                            blockID: block.id,
                            baseURL: presentation.sourceURL?.deletingLastPathComponent(),
                            footnoteNumbers: presentation.footnoteNumbers,
                            selectedRange: selectedMatch?.blockID == block.id ? selectedMatch?.range : nil
                        )
                        .id(block.id)
                    }

                    if !presentation.footnotes.isEmpty {
                        Text("Notes")
                            .font(.custom("Avenir Next Demi Bold", size: 19, relativeTo: .headline))
                            .padding(.top, 18)
                            .padding(.bottom, 8)
                        ForEach(presentation.footnotes) { footnote in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(footnote.number).")
                                    .font(.custom("Avenir Next", size: 14, relativeTo: .footnote))
                                    .foregroundStyle(.secondary)
                                MobileInlineText(
                                    nodes: footnote.content,
                                    baseURL: presentation.sourceURL?.deletingLastPathComponent(),
                                    footnoteNumbers: presentation.footnoteNumbers,
                                    style: .footnote,
                                    selectedRange: selectedMatch?.blockID == footnote.id
                                        ? selectedMatch?.range.shifted(by: -"\(footnote.number). ".utf16.count)
                                        : nil
                                )
                            }
                            .padding(.bottom, 6)
                            .id(footnote.id)
                        }
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .textSelection(.enabled)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(onTapBackground))
            .environment(\.openURL, OpenURLAction { url in
                onOpenURL(url)
                return .handled
            })
            .onChange(of: requestedAnchor) { _, anchor in
                guard let anchor else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(anchor, anchor: .center)
                }
            }
        }
    }
}

private struct MobileRenderedBlockView: View {
    let block: MarkdownBlock
    let blockID: String
    let baseURL: URL?
    let footnoteNumbers: [String: Int]
    let selectedRange: NSRange?

    var body: some View {
        Group {
            switch block {
            case let .heading(level, content):
                MobileInlineText(
                    nodes: content,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    style: .heading(level),
                    selectedRange: selectedRange
                )
                .padding(.top, level <= 2 ? 14 : 8)
                .padding(.bottom, level <= 2 ? 7 : 4)
            case let .paragraph(content):
                MobileParagraphView(
                    content: content,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers,
                    selectedRange: selectedRange
                )
                .padding(.bottom, 11)
            case let .blockquote(children):
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.55))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                            MobileRenderedBlockView(
                                block: child,
                                blockID: "\(blockID)-quote-\(index)",
                                baseURL: baseURL,
                                footnoteNumbers: footnoteNumbers,
                                selectedRange: nil
                            )
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.bottom, 7)
                .background(selectedBackground)
            case let .list(items, ordered, start, _):
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(listMarker(item: item, index: index, ordered: ordered, start: start))
                                .font(.custom("Avenir Next", size: 17, relativeTo: .body))
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 22, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(item.blocks.enumerated()), id: \.offset) { childIndex, child in
                                    MobileRenderedBlockView(
                                        block: child,
                                        blockID: "\(blockID)-item-\(index)-\(childIndex)",
                                        baseURL: baseURL,
                                        footnoteNumbers: footnoteNumbers,
                                        selectedRange: nil
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 11)
                .background(selectedBackground)
            case let .codeBlock(language, code):
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 5) {
                        if let language, !language.isEmpty {
                            Text(language)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        Text(highlightedVerbatim(code))
                            .font(.system(.callout, design: .monospaced))
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("markdown-code-block")
                    }
                    .padding(12)
                }
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.vertical, 4)
                .padding(.bottom, 10)
            case let .rawHTML(source):
                ScrollView(.horizontal) {
                    Text(highlightedVerbatim(source))
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 10)
            case .thematicBreak:
                Divider()
                    .padding(.vertical, 14)
            case .footnoteDefinition:
                EmptyView()
            case let .table(headers, alignments, rows):
                MobileMarkdownTableView(
                    headers: headers,
                    alignments: alignments,
                    rows: rows,
                    baseURL: baseURL,
                    footnoteNumbers: footnoteNumbers
                )
                .padding(.vertical, 7)
                .padding(.bottom, 10)
                .background(selectedBackground)
            }
        }
        .accessibilityIdentifier(blockID)
    }

    private var selectedBackground: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(selectedRange == nil ? Color.clear : Color.yellow.opacity(0.24))
    }

    private func listMarker(
        item: MarkdownListItem,
        index: Int,
        ordered: Bool,
        start: Int
    ) -> String {
        if let checked = item.checked { return checked ? "☑" : "☐" }
        return ordered ? "\(start + index)." : "•"
    }

    private func highlightedVerbatim(_ value: String) -> AttributedString {
        var attributed = AttributedString(value)
        guard let selectedRange,
              let range = Range(selectedRange, in: value),
              let lower = AttributedString.Index(range.lowerBound, within: attributed),
              let upper = AttributedString.Index(range.upperBound, within: attributed) else {
            return attributed
        }
        attributed[lower..<upper].backgroundColor = .yellow.opacity(0.55)
        return attributed
    }
}

private struct MobileParagraphView: View {
    let content: [InlineNode]
    let baseURL: URL?
    let footnoteNumbers: [String: Int]
    let selectedRange: NSRange?

    var body: some View {
        let groups = paragraphGroups
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case let .text(nodes):
                    MobileInlineText(
                        nodes: nodes,
                        baseURL: baseURL,
                        footnoteNumbers: footnoteNumbers,
                        style: .body,
                        selectedRange: selectedRange
                    )
                case let .image(alt, source):
                    MobileMarkdownImageView(alt: alt, source: source, baseURL: baseURL)
                }
            }
        }
    }

    private var paragraphGroups: [ParagraphGroup] {
        var result: [ParagraphGroup] = []
        var pending: [InlineNode] = []
        for node in content {
            if case let .image(alt, source, _) = node {
                if !pending.isEmpty {
                    result.append(.text(pending))
                    pending = []
                }
                result.append(.image(alt: alt, source: source))
            } else {
                pending.append(node)
            }
        }
        if !pending.isEmpty { result.append(.text(pending)) }
        return result.isEmpty ? [.text(content)] : result
    }

    private enum ParagraphGroup {
        case text([InlineNode])
        case image(alt: String, source: String)
    }
}

private struct MobileMarkdownImageView: View {
    let alt: String
    let source: String
    let baseURL: URL?

    var body: some View {
        switch MobileImageResolver().resolve(source: source, relativeTo: baseURL) {
        case let .local(url):
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(alt.isEmpty ? "Markdown image" : alt)
            } else {
                placeholder(.inaccessible)
            }
        case let .placeholder(reason):
            placeholder(reason)
        }
    }

    private func placeholder(_ reason: MobileImagePlaceholderReason) -> some View {
        Label {
            Text(alt.isEmpty ? reason.message : "\(reason.message): \(alt)")
        } icon: {
            Image(systemName: "photo.badge.exclamationmark")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 88)
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MobileMarkdownTableView: View {
    let headers: [[InlineNode]]
    let alignments: [TableAlignment]
    let rows: [[[InlineNode]]]
    let baseURL: URL?
    let footnoteNumbers: [String: Int]

    var body: some View {
        let allRows = [headers] + rows
        let columnCount = max(1, allRows.map(\.count).max() ?? 1)
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(allRows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            MobileInlineText(
                                nodes: column < row.count ? row[column] : [],
                                baseURL: baseURL,
                                footnoteNumbers: footnoteNumbers,
                                style: rowIndex == 0 ? .tableHeader : .tableBody,
                                selectedRange: nil
                            )
                            .frame(width: 142, alignment: alignment(at: column))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .background(rowIndex == 0 ? Color.secondary.opacity(0.13) : Color.clear)
                            .overlay {
                                Rectangle().stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
                            }
                            .accessibilityIdentifier("markdown-table-\(rowIndex)-\(column)")
                        }
                    }
                }
            }
        }
    }

    private func alignment(at index: Int) -> Alignment {
        guard index < alignments.count else { return .leading }
        switch alignments[index] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct MobileInlineText: View {
    enum Style {
        case body
        case heading(Int)
        case footnote
        case tableHeader
        case tableBody
    }

    let nodes: [InlineNode]
    let baseURL: URL?
    let footnoteNumbers: [String: Int]
    let style: Style
    let selectedRange: NSRange?

    var body: some View {
        Text(attributedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedText: AttributedString {
        let baseFont = scaledFont
        let output = NSMutableAttributedString(string: "")
        append(nodes, to: output, baseFont: baseFont)
        if let selectedRange, NSMaxRange(selectedRange) <= output.length {
            output.addAttribute(
                .backgroundColor,
                value: UIColor.systemYellow.withAlphaComponent(0.48),
                range: selectedRange
            )
        }
        return AttributedString(output)
    }

    private var scaledFont: UIFont {
        let name: String
        let size: CGFloat
        let textStyle: UIFont.TextStyle
        switch style {
        case .body:
            name = "AvenirNext-Regular"
            size = 17
            textStyle = .body
        case let .heading(level):
            name = "AvenirNext-DemiBold"
            size = [32, 27, 23, 20, 18, 17][min(max(level - 1, 0), 5)]
            textStyle = level <= 2 ? .title2 : .headline
        case .footnote:
            name = "AvenirNext-Regular"
            size = 14
            textStyle = .footnote
        case .tableHeader:
            name = "AvenirNext-DemiBold"
            size = 14
            textStyle = .subheadline
        case .tableBody:
            name = "AvenirNext-Regular"
            size = 14
            textStyle = .subheadline
        }
        let font = UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font)
    }

    private func append(_ nodes: [InlineNode], to output: NSMutableAttributedString, baseFont: UIFont) {
        for node in nodes {
            switch node {
            case let .text(text):
                output.append(NSAttributedString(string: text, attributes: baseAttributes(font: baseFont)))
            case let .emphasis(children):
                append(children, to: output, baseFont: variant(baseFont, italic: true))
            case let .strong(children):
                append(children, to: output, baseFont: variant(baseFont, bold: true))
            case let .underline(children):
                let start = output.length
                append(children, to: output, baseFont: baseFont)
                output.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: start, length: output.length - start)
                )
            case let .strikethrough(children):
                let start = output.length
                append(children, to: output, baseFont: baseFont)
                output.addAttribute(
                    .strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: NSRange(location: start, length: output.length - start)
                )
            case let .code(code):
                output.append(
                    NSAttributedString(
                        string: code,
                        attributes: [
                            .font: UIFont.monospacedSystemFont(
                                ofSize: max(12, baseFont.pointSize * 0.9),
                                weight: .regular
                            ),
                            .foregroundColor: UIColor.label,
                            .backgroundColor: UIColor.secondarySystemBackground
                        ]
                    )
                )
            case let .link(children, destination, _):
                let start = output.length
                append(children, to: output, baseFont: baseFont)
                if let url = MarkdownLinkTarget.resolvedURL(for: destination, relativeTo: baseURL) {
                    output.addAttributes(
                        [.link: url, .foregroundColor: UIColor.link],
                        range: NSRange(location: start, length: output.length - start)
                    )
                }
            case let .footnoteReference(label):
                let value = footnoteNumbers[label].map(String.init) ?? label
                output.append(
                    NSAttributedString(
                        string: value,
                        attributes: [
                            .font: UIFontMetrics(forTextStyle: .caption2).scaledFont(
                                for: UIFont(name: "AvenirNext-Regular", size: 11)
                                    ?? UIFont.systemFont(ofSize: 11)
                            ),
                            .foregroundColor: UIColor.link,
                            .baselineOffset: baseFont.pointSize * 0.28,
                            .link: MobileFootnoteLink.url(for: .definition(label))
                        ]
                    )
                )
            case let .image(alt, _, _):
                output.append(
                    NSAttributedString(
                        string: alt.isEmpty ? "[Image]" : "[Image: \(alt)]",
                        attributes: [
                            .font: variant(baseFont, italic: true),
                            .foregroundColor: UIColor.secondaryLabel
                        ]
                    )
                )
            case let .rawHTML(source):
                output.append(
                    NSAttributedString(
                        string: source,
                        attributes: [
                            .font: UIFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.9, weight: .regular),
                            .foregroundColor: UIColor.label,
                            .backgroundColor: UIColor.secondarySystemBackground
                        ]
                    )
                )
            case .softBreak:
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: baseFont)))
            case .hardBreak:
                output.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: baseFont)))
            }
        }
    }

    private func baseAttributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor.label]
    }

    private func variant(_ font: UIFont, bold: Bool = false, italic: Bool = false) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

private extension NSRange {
    func shifted(by offset: Int) -> NSRange? {
        let location = self.location + offset
        guard location >= 0 else { return nil }
        return NSRange(location: location, length: length)
    }
}

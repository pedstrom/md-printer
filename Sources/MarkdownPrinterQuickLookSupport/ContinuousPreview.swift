import AppKit
import Foundation
import MarkdownPrinterCore

public struct PreparedQuickLookDocument: Sendable {
    public let document: MarkdownDocument
    public let blocks: [MarkdownBlock]

    public init(document: MarkdownDocument, blocks: [MarkdownBlock]) {
        self.document = document
        self.blocks = blocks
    }
}

public enum ContinuousPreviewError: LocalizedError, Equatable, Sendable {
    case unreadableDocument
    case unsupportedTextEncoding

    public var errorDescription: String? {
        switch self {
        case .unreadableDocument:
            return "Markdown Printer couldn’t read this file."
        case .unsupportedTextEncoding:
            return "This Markdown file isn’t valid UTF-8 or UTF-16 text."
        }
    }
}

public struct ContinuousPreviewLoader: Sendable {
    private let parser: MarkdownParser

    public init(parser: MarkdownParser = MarkdownParser()) {
        self.parser = parser
    }

    public func load(at url: URL) async throws -> PreparedQuickLookDocument {
        let parser = parser
        let loadTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            do {
                let data = try Data(contentsOf: url)
                try Task.checkCancellation()
                let document: MarkdownDocument
                do {
                    document = try MarkdownDocument.decode(data: data, sourceURL: url)
                } catch MarkdownDocumentError.unsupportedTextEncoding {
                    throw ContinuousPreviewError.unsupportedTextEncoding
                }
                let prepared = PreparedQuickLookDocument(
                    document: document,
                    blocks: parser.parse(document.markdown)
                )
                try Task.checkCancellation()
                return prepared
            } catch let error as ContinuousPreviewError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ContinuousPreviewError.unreadableDocument
            }
        }
        return try await withTaskCancellationHandler {
            try await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }
    }
}

@MainActor
public enum ContinuousPreviewStyle {
    public static let maximumReadingWidth: CGFloat = 680
    public static let horizontalMargin: CGFloat = 24
    public static let verticalMargin: CGFloat = 28

    public static var rendererConfiguration: RendererConfiguration {
        RendererConfiguration(
            bodyFontSize: 13,
            headingFontSizes: [31, 26, 22, 18, 16, 13],
            pageSize: CGSize(width: maximumReadingWidth, height: 1_000),
            pageMargins: NSEdgeInsets(),
            textColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            accentColor: .linkColor,
            codeBackgroundColor: .controlBackgroundColor,
            tableBorderColor: .separatorColor,
            maximumImageWidth: maximumReadingWidth,
            codeBlockPadding: 10
        )
    }
}

public enum QuickLookFootnoteTarget: Equatable, Sendable {
    case definition(String)
    case reference(String)
}

public enum QuickLookFootnoteLink {
    private static let scheme = "markdown-printer-footnote"

    public static func url(for target: QuickLookFootnoteTarget) -> URL {
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

    public static func target(from value: Any) -> QuickLookFootnoteTarget? {
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

@MainActor
public final class ContinuousPreviewRenderer {
    private let renderer: MarkdownRenderer

    public init(configuration: RendererConfiguration? = nil) {
        renderer = MarkdownRenderer(
            configuration: configuration ?? ContinuousPreviewStyle.rendererConfiguration
        )
    }

    public func render(_ prepared: PreparedQuickLookDocument) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            attributedString: renderer.render(
                blocks: prepared.blocks,
                baseURL: prepared.document.baseURL
            )
        )
        addFootnoteLinks(to: attributed)
        return attributed
    }

    private func addFootnoteLinks(to attributed: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(
            .markdownFootnoteReference,
            in: range,
            options: []
        ) { value, attributeRange, _ in
            guard let label = value as? String else { return }
            attributed.addAttribute(
                .link,
                value: QuickLookFootnoteLink.url(for: .definition(label)),
                range: attributeRange
            )
        }
        attributed.enumerateAttribute(
            .markdownFootnoteDefinition,
            in: range,
            options: []
        ) { value, attributeRange, _ in
            guard let label = value as? String else { return }
            attributed.addAttribute(
                .link,
                value: QuickLookFootnoteLink.url(for: .reference(label)),
                range: attributeRange
            )
        }
    }
}

@MainActor
public final class ContinuousPreviewView: NSView, NSTextViewDelegate {
    public let scrollView: NSScrollView
    public let textView: NSTextView

    private let centeredTextView: CenteredQuickLookTextView

    public override init(frame frameRect: NSRect) {
        scrollView = NSScrollView(frame: frameRect)
        centeredTextView = CenteredQuickLookTextView(frame: frameRect)
        textView = centeredTextView
        super.init(frame: frameRect)

        autoresizingMask = [.width, .height]
        wantsLayer = true

        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        addSubview(scrollView)
    }

    public required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        centeredTextView.setFrameSize(NSSize(
            width: scrollView.contentSize.width,
            height: max(centeredTextView.frame.height, scrollView.contentSize.height)
        ))
    }

    public func display(_ attributedDocument: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributedDocument)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        resizeDocumentHeight()
        textView.scrollToBeginningOfDocument(nil)
    }

    public func display(error: ContinuousPreviewError) {
        let title = NSAttributedString(
            string: "Preview unavailable\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: centeredParagraphStyle(spacingAfter: 8)
            ]
        )
        let detail = NSAttributedString(
            string: error.localizedDescription,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centeredParagraphStyle(spacingAfter: 0)
            ]
        )
        let message = NSMutableAttributedString(attributedString: title)
        message.append(detail)
        display(message)
    }

    public func destinationRange(
        for target: QuickLookFootnoteTarget,
        in attributedDocument: NSAttributedString? = nil
    ) -> NSRange? {
        let document = attributedDocument ?? textView.attributedString()
        let key: NSAttributedString.Key
        let label: String
        switch target {
        case let .definition(value):
            key = .markdownFootnoteDefinition
            label = value
        case let .reference(value):
            key = .markdownFootnoteReference
            label = value
        }
        var destination: NSRange?
        document.enumerateAttribute(
            key,
            in: NSRange(location: 0, length: document.length),
            options: []
        ) { value, range, stop in
            guard value as? String == label else { return }
            destination = range
            stop.pointee = true
        }
        return destination
    }

    public func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let target = QuickLookFootnoteLink.target(from: link),
              let range = destinationRange(for: target) else {
            return false
        }
        textView.scrollRangeToVisible(range)
        return true
    }

    private func resizeDocumentHeight() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height)
            + ContinuousPreviewStyle.verticalMargin * 2
        textView.setFrameSize(NSSize(
            width: scrollView.contentSize.width,
            height: max(height, scrollView.contentSize.height)
        ))
    }

    private func centeredParagraphStyle(spacingAfter: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = spacingAfter
        return style
    }
}

@MainActor
private final class CenteredQuickLookTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let availableWidth = max(1, newSize.width - ContinuousPreviewStyle.horizontalMargin * 2)
        let readingWidth = min(ContinuousPreviewStyle.maximumReadingWidth, availableWidth)
        textContainerInset = NSSize(
            width: max(
                ContinuousPreviewStyle.horizontalMargin,
                (newSize.width - readingWidth) / 2
            ),
            height: ContinuousPreviewStyle.verticalMargin
        )
    }
}

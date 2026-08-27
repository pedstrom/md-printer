#if canImport(UIKit)
import Foundation
import MarkdownPrinterCore
import UIKit

public struct MobilePDFConfiguration: Equatable, Sendable {
    public static let letter = MobilePDFConfiguration()

    public var pageSize: CGSize
    public var margins: UIEdgeInsets
    public var bodyFontSize: CGFloat
    public var codeBlockPadding: CGFloat

    public init(
        pageSize: CGSize = CGSize(width: 612, height: 792),
        margins: UIEdgeInsets = UIEdgeInsets(top: 54, left: 54, bottom: 54, right: 54),
        bodyFontSize: CGFloat = 10,
        codeBlockPadding: CGFloat = 8
    ) {
        self.pageSize = pageSize
        self.margins = margins
        self.bodyFontSize = bodyFontSize
        self.codeBlockPadding = codeBlockPadding
    }

    public var contentWidth: CGFloat {
        max(1, pageSize.width - margins.left - margins.right)
    }

    public var contentHeight: CGFloat {
        max(1, pageSize.height - margins.top - margins.bottom)
    }

    public static func == (lhs: MobilePDFConfiguration, rhs: MobilePDFConfiguration) -> Bool {
        lhs.pageSize == rhs.pageSize
            && lhs.margins.top == rhs.margins.top
            && lhs.margins.left == rhs.margins.left
            && lhs.margins.bottom == rhs.margins.bottom
            && lhs.margins.right == rhs.margins.right
            && lhs.bodyFontSize == rhs.bodyFontSize
            && lhs.codeBlockPadding == rhs.codeBlockPadding
    }
}

public enum MobilePDFExporterError: LocalizedError, Equatable, Sendable {
    case renderingFailed

    public var errorDescription: String? {
        "The PDF could not be rendered."
    }
}

public struct MobilePDFExporter: Sendable {
    public let configuration: MobilePDFConfiguration

    public init(configuration: MobilePDFConfiguration = .letter) {
        self.configuration = configuration
    }

    public func pdfData(for document: MarkdownDocument) async throws -> Data {
        let configuration = configuration
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let attributed = try MobilePrintRenderer(configuration: configuration).render(
                document: document
            )
            try Task.checkCancellation()
            return try Self(configuration: configuration).render(
                attributed,
                title: document.title
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func render(_ attributed: NSAttributedString, title: String) throws -> Data {
        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        var containers: [NSTextContainer] = []
        var coveredGlyphs = 0

        repeat {
            try Task.checkCancellation()
            let container = NSTextContainer(
                size: CGSize(width: configuration.contentWidth, height: configuration.contentHeight)
            )
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            containers.append(container)
            let range = layoutManager.glyphRange(for: container)
            let nextCovered = NSMaxRange(range)
            if nextCovered <= coveredGlyphs && layoutManager.numberOfGlyphs > coveredGlyphs {
                throw MobilePDFExporterError.renderingFailed
            }
            coveredGlyphs = nextCovered
        } while coveredGlyphs < layoutManager.numberOfGlyphs

        if containers.isEmpty {
            let container = NSTextContainer(
                size: CGSize(width: configuration.contentWidth, height: configuration.contentHeight)
            )
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
        }

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Markdown Printer",
            kCGPDFContextTitle as String: title
        ]
        let bounds = CGRect(origin: .zero, size: configuration.pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        var wasCancelled = false
        let data = renderer.pdfData { context in
            for (pageIndex, container) in containers.enumerated() {
                if Task.isCancelled {
                    wasCancelled = true
                    return
                }
                context.beginPage()
                UIColor.white.setFill()
                context.fill(bounds)
                let glyphRange = layoutManager.glyphRange(for: container)
                let characterRange = layoutManager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                drawDecorations(
                    textStorage: textStorage,
                    layoutManager: layoutManager,
                    container: container,
                    characterRange: characterRange,
                    in: context
                )
                let origin = CGPoint(x: configuration.margins.left, y: configuration.margins.top)
                layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
                addDestinationsAndLinks(
                    textStorage: textStorage,
                    layoutManager: layoutManager,
                    container: container,
                    characterRange: characterRange,
                    in: context
                )
                drawPageNumber(pageIndex + 1, in: context)
            }
        }
        if wasCancelled { throw CancellationError() }
        guard !data.isEmpty else { throw MobilePDFExporterError.renderingFailed }
        return data
    }

    private func drawDecorations(
        textStorage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer,
        characterRange: NSRange,
        in context: UIGraphicsPDFRendererContext
    ) {
        textStorage.enumerateAttribute(
            .mobileQuote,
            in: characterRange,
            options: []
        ) { value, range, _ in
            guard value != nil else { return }
            let rect = decorationRect(
                forCharacterRange: range,
                layoutManager: layoutManager,
                container: container
            )
            guard !rect.isNull else { return }
            let x = configuration.margins.left + max(2, rect.minX - 12)
            let quoteRect = CGRect(
                x: x,
                y: configuration.margins.top + rect.minY,
                width: 2,
                height: rect.height
            )
            UIColor.systemGray3.setFill()
            context.fill(quoteRect)
        }

        textStorage.enumerateAttribute(
            .mobileThematicBreak,
            in: characterRange,
            options: []
        ) { value, range, _ in
            guard value != nil else { return }
            let rect = decorationRect(
                forCharacterRange: range,
                layoutManager: layoutManager,
                container: container
            )
            guard !rect.isNull else { return }
            let y = configuration.margins.top + rect.midY
            let rule = UIBezierPath()
            rule.move(to: CGPoint(x: configuration.margins.left, y: y))
            rule.addLine(
                to: CGPoint(
                    x: configuration.margins.left + configuration.contentWidth,
                    y: y
                )
            )
            UIColor(white: 0.72, alpha: 1).setStroke()
            rule.lineWidth = 0.5
            rule.stroke()
        }

        textStorage.enumerateAttribute(
            .mobileTableColumnCount,
            in: characterRange,
            options: [.longestEffectiveRangeNotRequired]
        ) { value, range, _ in
            guard let columnCount = value as? Int, columnCount > 0 else { return }
            let rect = decorationRect(
                forCharacterRange: range,
                layoutManager: layoutManager,
                container: container
            )
            guard !rect.isNull else { return }
            let rowRect = CGRect(
                x: configuration.margins.left,
                y: configuration.margins.top + rect.minY,
                width: configuration.contentWidth,
                height: max(12, rect.height)
            )
            UIColor(white: 0.72, alpha: 1).setStroke()
            let path = UIBezierPath(rect: rowRect)
            path.lineWidth = 0.5
            path.stroke()
            for column in 1..<columnCount {
                let x = rowRect.minX + rowRect.width * CGFloat(column) / CGFloat(columnCount)
                let divider = UIBezierPath()
                divider.move(to: CGPoint(x: x, y: rowRect.minY))
                divider.addLine(to: CGPoint(x: x, y: rowRect.maxY))
                divider.lineWidth = 0.5
                divider.stroke()
            }
        }
    }

    private func addDestinationsAndLinks(
        textStorage: NSTextStorage,
        layoutManager: NSLayoutManager,
        container: NSTextContainer,
        characterRange: NSRange,
        in context: UIGraphicsPDFRendererContext
    ) {
        textStorage.enumerateAttribute(
            .mobileFootnoteDefinition,
            in: characterRange,
            options: [.longestEffectiveRangeNotRequired]
        ) { value, range, _ in
            guard let label = value as? String else { return }
            let rect = annotationRect(
                forCharacterRange: range,
                layoutManager: layoutManager,
                container: container
            )
            guard !rect.isNull else { return }
            context.addDestination(
                withName: "footnote-definition-\(label)",
                at: CGPoint(x: rect.minX, y: rect.minY)
            )
        }

        textStorage.enumerateAttribute(
            .link,
            in: characterRange,
            options: [.longestEffectiveRangeNotRequired]
        ) { value, range, _ in
            let rect = annotationRect(
                forCharacterRange: range,
                layoutManager: layoutManager,
                container: container
            )
            guard !rect.isNull else { return }
            if case let .definition(label)? = MobileFootnoteLink.target(from: value as Any) {
                context.setDestinationWithName("footnote-definition-\(label)", for: rect)
            } else if let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)) {
                context.setURL(url, for: rect)
            }
        }
    }

    private func annotationRect(
        forCharacterRange range: NSRange,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) -> CGRect {
        let intersection = NSIntersectionRange(
            range,
            layoutManager.characterRange(forGlyphRange: layoutManager.glyphRange(for: container), actualGlyphRange: nil)
        )
        guard intersection.length > 0 else { return .null }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: intersection, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        return rect.offsetBy(dx: configuration.margins.left, dy: configuration.margins.top)
            .insetBy(dx: -1, dy: -1)
    }

    private func decorationRect(
        forCharacterRange range: NSRange,
        layoutManager: NSLayoutManager,
        container: NSTextContainer
    ) -> CGRect {
        let pageCharacters = layoutManager.characterRange(
            forGlyphRange: layoutManager.glyphRange(for: container),
            actualGlyphRange: nil
        )
        let intersection = NSIntersectionRange(range, pageCharacters)
        guard intersection.length > 0 else { return .null }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: intersection, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
    }

    private func drawPageNumber(_ pageNumber: Int, in context: UIGraphicsPDFRendererContext) {
        let value = "\(pageNumber)"
        let font = UIFont(name: "AvenirNext-Regular", size: 8) ?? UIFont.systemFont(ofSize: 8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(white: 0.45, alpha: 1)
        ]
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: CGPoint(
                x: (configuration.pageSize.width - size.width) / 2,
                y: configuration.pageSize.height - configuration.margins.bottom + 22
            ),
            withAttributes: attributes
        )
    }
}
#endif

import AppKit
import CoreGraphics
import PDFKit

@MainActor
public final class PDFExporter {
    public let configuration: RendererConfiguration

    public init(configuration: RendererConfiguration = RendererConfiguration()) {
        self.configuration = configuration
    }

    public func pdfData(from attributedText: NSAttributedString) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw PDFExporterError.renderingFailed
        }
        var mediaBox = CGRect(origin: .zero, size: configuration.pageSize)
        let metadata: CFDictionary = [
            kCGPDFContextCreator: "Markdown Printer",
            kCGPDFContextTitle: "Markdown Document"
        ] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw PDFExporterError.renderingFailed
        }

        let pages = makePages(for: attributedText)
        for (pageIndex, page) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: configuration.pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            let origin = CGPoint(x: configuration.pageMargins.left, y: configuration.pageMargins.top)
            page.layoutManager.drawBackground(forGlyphRange: page.glyphRange, at: origin)
            page.layoutManager.drawGlyphs(forGlyphRange: page.glyphRange, at: origin)
            drawPageNumber(pageIndex + 1)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        guard data.length > 0 else { throw PDFExporterError.renderingFailed }
        return data as Data
    }

    public func write(_ attributedText: NSAttributedString, to url: URL) throws {
        try pdfData(from: attributedText).write(to: url, options: .atomic)
    }

    public func printOperation(forPDFData data: Data) throws -> NSPrintOperation {
        guard let document = PDFDocument(data: data) else {
            throw PDFExporterError.renderingFailed
        }
        let operation = NSPrintOperation(
            view: PDFPrintView(document: document, pageSize: configuration.pageSize),
            printInfo: printInfo()
        )
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    private func makePages(for attributedText: NSAttributedString) -> [TextPage] {
        let contentSize = CGSize(
            width: configuration.contentWidth,
            height: max(1, configuration.pageSize.height - configuration.pageMargins.top - configuration.pageMargins.bottom)
        )
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        var pages: [TextPage] = []

        appendPagesUntilCovered(
            pages: &pages,
            layoutManager: layoutManager,
            contentSize: contentSize
        )
        keepHeadingsWithFollowingContent(
            pages: &pages,
            layoutManager: layoutManager,
            textStorage: textStorage,
            contentSize: contentSize
        )

        return pages
    }

    private func appendPagesUntilCovered(
        pages: inout [TextPage],
        layoutManager: NSLayoutManager,
        contentSize: CGSize
    ) {
        if pages.isEmpty {
            pages.append(makePage(layoutManager: layoutManager, contentSize: contentSize))
        }

        layoutManager.ensureLayout(for: pages[pages.count - 1].textContainer)
        var coveredGlyphs = NSMaxRange(pages[pages.count - 1].glyphRange)
        while coveredGlyphs < layoutManager.numberOfGlyphs {
            let page = makePage(layoutManager: layoutManager, contentSize: contentSize)
            pages.append(page)
            layoutManager.ensureLayout(for: page.textContainer)
            let nextCoveredGlyphs = NSMaxRange(page.glyphRange)
            if nextCoveredGlyphs <= coveredGlyphs { break }
            coveredGlyphs = nextCoveredGlyphs
        }
    }

    private func makePage(layoutManager: NSLayoutManager, contentSize: CGSize) -> TextPage {
        let textContainer = NSTextContainer(containerSize: contentSize)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(
            frame: NSRect(origin: .zero, size: contentSize),
            textContainer: textContainer
        )
        textView.textContainerInset = .zero
        textView.drawsBackground = false
        return TextPage(
            layoutManager: layoutManager,
            textContainer: textContainer,
            textView: textView
        )
    }

    private func keepHeadingsWithFollowingContent(
        pages: inout [TextPage],
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage,
        contentSize: CGSize
    ) {
        var pageIndex = 0
        while pageIndex < pages.count {
            appendPagesUntilCovered(
                pages: &pages,
                layoutManager: layoutManager,
                contentSize: contentSize
            )
            let rows = visualRows(
                pages: pages,
                layoutManager: layoutManager,
                textStorage: textStorage
            )
            guard let headingTop = orphanedHeadingTop(on: pageIndex, rows: rows) else {
                pageIndex += 1
                continue
            }

            let page = pages[pageIndex]
            let oldHeight = page.textContainer.containerSize.height
            let newHeight = max(1, headingTop - 0.5)
            guard newHeight < oldHeight - 0.5 else {
                pageIndex += 1
                continue
            }

            let oldGlyphEnd = NSMaxRange(page.glyphRange)
            page.textContainer.containerSize.height = newHeight
            layoutManager.ensureLayout(for: page.textContainer)
            guard NSMaxRange(page.glyphRange) < oldGlyphEnd else {
                page.textContainer.containerSize.height = oldHeight
                pageIndex += 1
                continue
            }
        }
    }

    private func orphanedHeadingTop(on pageIndex: Int, rows: [VisualRow]) -> CGFloat? {
        let pageRows = rows.indices.filter { rows[$0].pageIndex == pageIndex }
        guard let lastHeading = pageRows.last(where: { rows[$0].isHeading }) else { return nil }

        var headingGroupStart = lastHeading
        while headingGroupStart > 0, rows[headingGroupStart - 1].isHeading {
            headingGroupStart -= 1
        }
        guard rows[headingGroupStart].pageIndex == pageIndex,
              pageRows.contains(where: { $0 < headingGroupStart }) else {
            return nil
        }

        var headingGroupEnd = lastHeading
        while headingGroupEnd + 1 < rows.count, rows[headingGroupEnd + 1].isHeading {
            headingGroupEnd += 1
        }

        var availableFollowingRows = 0
        var rowIndex = headingGroupEnd + 1
        while rowIndex < rows.count,
              !rows[rowIndex].isHeading,
              availableFollowingRows < 2 {
            availableFollowingRows += 1
            rowIndex += 1
        }
        let requiredFollowingRows = min(2, availableFollowingRows)
        let followingRowsOnPage = pageRows.filter { $0 > lastHeading }.count
        guard followingRowsOnPage < requiredFollowingRows else { return nil }
        return rows[headingGroupStart].minY
    }

    private func visualRows(
        pages: [TextPage],
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage
    ) -> [VisualRow] {
        var result: [VisualRow] = []
        for (pageIndex, page) in pages.enumerated() {
            layoutManager.ensureLayout(for: page.textContainer)
            var fragments: [VisualRow] = []
            layoutManager.enumerateLineFragments(forGlyphRange: page.glyphRange) {
                lineFragmentRect, _, textContainer, glyphRange, _ in
                guard textContainer === page.textContainer,
                      let characterIndex = self.firstVisibleCharacterIndex(
                          in: glyphRange,
                          layoutManager: layoutManager,
                          textStorage: textStorage
                      ) else {
                    return
                }
                let paragraph = textStorage.attribute(
                    .paragraphStyle,
                    at: characterIndex,
                    effectiveRange: nil
                ) as? NSParagraphStyle
                fragments.append(VisualRow(
                    pageIndex: pageIndex,
                    minY: lineFragmentRect.minY,
                    isHeading: (paragraph?.headerLevel ?? 0) > 0
                ))
            }

            fragments.sort { lhs, rhs in lhs.minY < rhs.minY }
            for fragment in fragments {
                if let lastIndex = result.indices.last,
                   result[lastIndex].pageIndex == fragment.pageIndex,
                   abs(result[lastIndex].minY - fragment.minY) < 0.5 {
                    result[lastIndex].isHeading = result[lastIndex].isHeading || fragment.isHeading
                } else {
                    result.append(fragment)
                }
            }
        }
        return result
    }

    private func firstVisibleCharacterIndex(
        in glyphRange: NSRange,
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage
    ) -> Int? {
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let string = textStorage.string as NSString
        for characterIndex in characterRange.location..<NSMaxRange(characterRange) {
            let codeUnit = string.character(at: characterIndex)
            if let scalar = UnicodeScalar(codeUnit),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            return characterIndex
        }
        return nil
    }

    private func drawPageNumber(_ pageNumber: Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let label = NSAttributedString(
            string: String(pageNumber),
            attributes: [
                .font: FontBook(configuration: configuration).regular(size: 8),
                .foregroundColor: configuration.secondaryTextColor,
                .paragraphStyle: paragraph
            ]
        )
        let footerTop = configuration.pageSize.height - configuration.pageMargins.bottom
        label.draw(in: CGRect(x: 0, y: footerTop + 16, width: configuration.pageSize.width, height: 14))
    }

    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = configuration.pageSize
        // The generated PDF already contains the configured print-safe margins.
        // A second margin layer would shrink and offset the complete PDF page.
        info.topMargin = 0
        info.leftMargin = 0
        info.bottomMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }
}

private final class PDFPrintView: NSView {
    private let document: PDFDocument

    init(document: PDFDocument, pageSize: CGSize) {
        self.document = document
        super.init(frame: NSRect(origin: .zero, size: pageSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: document.pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let operation = NSPrintOperation.current,
              let page = document.page(at: operation.currentPage - 1),
              let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        let printInfo = operation.printInfo
        let imageableBounds = printInfo.imageablePageBounds
        context.saveGState()
        context.translateBy(
            x: -imageableBounds.minX,
            y: printInfo.paperSize.height - imageableBounds.maxY
        )
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
    }
}

private final class TextPage {
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    let textView: NSTextView

    init(layoutManager: NSLayoutManager, textContainer: NSTextContainer, textView: NSTextView) {
        self.layoutManager = layoutManager
        self.textContainer = textContainer
        self.textView = textView
    }

    var glyphRange: NSRange {
        layoutManager.glyphRange(for: textContainer)
    }
}

private struct VisualRow {
    let pageIndex: Int
    let minY: CGFloat
    var isHeading: Bool
}

public enum PDFExporterError: LocalizedError, Equatable {
    case renderingFailed

    public var errorDescription: String? {
        "The PDF could not be rendered."
    }
}

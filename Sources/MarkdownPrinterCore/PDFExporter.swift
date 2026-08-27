#if canImport(AppKit)
import AppKit
import CoreGraphics
import PDFKit

@MainActor
public final class PDFExporter {
    public let configuration: RendererConfiguration
    public let pageSetup: DocumentPageSetup?

    public init(
        configuration: RendererConfiguration = RendererConfiguration(),
        pageSetup: DocumentPageSetup? = nil
    ) {
        self.configuration = configuration
        self.pageSetup = pageSetup
    }

    public func pdfData(
        from attributedText: NSAttributedString,
        footers: ResolvedFooterConfiguration = ResolvedFooterConfiguration()
    ) throws -> Data {
        let output = try makePDFOutput()
        let pages = makePages(for: attributedText)
        for (pageIndex, page) in pages.enumerated() {
            draw(page: page, pageNumber: pageIndex + 1, footers: footers, in: output.context)
        }
        return try finishPDFOutput(output, attributedText: attributedText, pages: pages)
    }

    public func pdfDataAsync(
        from attributedText: NSAttributedString,
        footers: ResolvedFooterConfiguration = ResolvedFooterConfiguration()
    ) async throws -> Data {
        let output = try makePDFOutput()
        let pages = await makePagesAsync(for: attributedText)
        for (pageIndex, page) in pages.enumerated() {
            try Task.checkCancellation()
            draw(page: page, pageNumber: pageIndex + 1, footers: footers, in: output.context)
            await Task.yield()
        }
        return try finishPDFOutput(output, attributedText: attributedText, pages: pages)
    }

    public func write(_ attributedText: NSAttributedString, to url: URL) throws {
        try pdfData(from: attributedText).write(to: url, options: .atomic)
    }

    @MainActor
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
        if attributedText.length <= 250_000 {
            keepHeadingsWithFollowingContent(
                pages: &pages,
                layoutManager: layoutManager,
                textStorage: textStorage,
                contentSize: contentSize
            )
        }
        cacheGlyphRanges(pages: pages, layoutManager: layoutManager)

        return pages
    }

    private func makePagesAsync(for attributedText: NSAttributedString) async -> [TextPage] {
        let contentSize = CGSize(
            width: configuration.contentWidth,
            height: max(1, configuration.pageSize.height - configuration.pageMargins.top - configuration.pageMargins.bottom)
        )
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        var pages: [TextPage] = []

        await appendPagesUntilCoveredAsync(
            pages: &pages,
            layoutManager: layoutManager,
            contentSize: contentSize
        )
        if attributedText.length <= 250_000 {
            await keepHeadingsWithFollowingContentAsync(
                pages: &pages,
                layoutManager: layoutManager,
                textStorage: textStorage,
                contentSize: contentSize
            )
        }
        cacheGlyphRanges(pages: pages, layoutManager: layoutManager)
        return pages
    }

    private func makePDFOutput() throws -> PDFOutput {
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
        return PDFOutput(data: data, context: context)
    }

    private func draw(
        page: TextPage,
        pageNumber: Int,
        footers: ResolvedFooterConfiguration,
        in context: CGContext
    ) {
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
        drawFooter(pageNumber: pageNumber, footers: footers)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.endPDFPage()
    }

    private func finishPDFOutput(
        _ output: PDFOutput,
        attributedText: NSAttributedString,
        pages: [TextPage]
    ) throws -> Data {
        output.context.closePDF()
        guard output.data.length > 0 else { throw PDFExporterError.renderingFailed }
        return try addingFootnoteNavigation(
            to: output.data as Data,
            attributedText: attributedText,
            pages: pages
        )
    }

    private func appendPagesUntilCovered(
        pages: inout [TextPage],
        layoutManager: NSLayoutManager,
        contentSize: CGSize
    ) {
        if pages.isEmpty { pages.append(makePage(layoutManager: layoutManager, contentSize: contentSize)) }

        layoutManager.ensureLayout(for: pages[pages.count - 1].textContainer)
        var coveredGlyphs = NSMaxRange(pages[pages.count - 1].glyphRange)
        while coveredGlyphs < layoutManager.numberOfGlyphs {
            for _ in 0..<32 {
                pages.append(makePage(layoutManager: layoutManager, contentSize: contentSize))
            }
            let lastPage = pages[pages.count - 1]
            layoutManager.ensureLayout(for: lastPage.textContainer)
            let nextCoveredGlyphs = NSMaxRange(lastPage.glyphRange)
            if nextCoveredGlyphs <= coveredGlyphs { break }
            coveredGlyphs = nextCoveredGlyphs
        }
        while pages.count > 1, pages[pages.count - 1].glyphRange.length == 0 {
            layoutManager.removeTextContainer(at: pages.count - 1)
            pages.removeLast()
        }
    }

    private func appendPagesUntilCoveredAsync(
        pages: inout [TextPage],
        layoutManager: NSLayoutManager,
        contentSize: CGSize
    ) async {
        if pages.isEmpty { pages.append(makePage(layoutManager: layoutManager, contentSize: contentSize)) }

        layoutManager.ensureLayout(for: pages[pages.count - 1].textContainer)
        var coveredGlyphs = NSMaxRange(pages[pages.count - 1].glyphRange)
        while coveredGlyphs < layoutManager.numberOfGlyphs {
            pages.append(makePage(layoutManager: layoutManager, contentSize: contentSize))
            let lastPage = pages[pages.count - 1]
            layoutManager.ensureLayout(for: lastPage.textContainer)
            let nextCoveredGlyphs = NSMaxRange(lastPage.glyphRange)
            if nextCoveredGlyphs <= coveredGlyphs { break }
            coveredGlyphs = nextCoveredGlyphs
            await Task.yield()
        }
        while pages.count > 1, pages[pages.count - 1].glyphRange.length == 0 {
            layoutManager.removeTextContainer(at: pages.count - 1)
            pages.removeLast()
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
        while true {
            while pageIndex < pages.count {
                let rows = visualRowsForHeadingCheck(
                    startingAt: pageIndex,
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

            let previousPageCount = pages.count
            appendPagesUntilCovered(
                pages: &pages,
                layoutManager: layoutManager,
                contentSize: contentSize
            )
            if pages.count == previousPageCount {
                break
            }
        }
    }

    private func keepHeadingsWithFollowingContentAsync(
        pages: inout [TextPage],
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage,
        contentSize: CGSize
    ) async {
        var pageIndex = 0
        while true {
            while pageIndex < pages.count {
                let rows = visualRowsForHeadingCheck(
                    startingAt: pageIndex,
                    pages: pages,
                    layoutManager: layoutManager,
                    textStorage: textStorage
                )
                guard let headingTop = orphanedHeadingTop(on: pageIndex, rows: rows) else {
                    pageIndex += 1
                    if pageIndex.isMultiple(of: 8) { await Task.yield() }
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
                await Task.yield()
            }

            let previousPageCount = pages.count
            await appendPagesUntilCoveredAsync(
                pages: &pages,
                layoutManager: layoutManager,
                contentSize: contentSize
            )
            if pages.count == previousPageCount { break }
        }
    }

    private func cacheGlyphRanges(
        pages: [TextPage],
        layoutManager: NSLayoutManager
    ) {
        var glyphIndex = 0
        for page in pages where glyphIndex < layoutManager.numberOfGlyphs {
            var effectiveRange = NSRange(location: 0, length: 0)
            let container = layoutManager.textContainer(
                forGlyphAt: glyphIndex,
                effectiveRange: &effectiveRange
            )
            if container === page.textContainer, effectiveRange.length > 0 {
                page.cachedGlyphRange = effectiveRange
            } else {
                page.cachedGlyphRange = layoutManager.glyphRange(for: page.textContainer)
            }
            glyphIndex = NSMaxRange(page.cachedGlyphRange ?? effectiveRange)
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

    private func visualRowsForHeadingCheck(
        startingAt pageIndex: Int,
        pages: [TextPage],
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage
    ) -> [VisualRow] {
        var result: [VisualRow] = []
        var candidatePage = pageIndex
        while candidatePage < pages.count {
            result.append(contentsOf: visualRows(
                on: candidatePage,
                page: pages[candidatePage],
                layoutManager: layoutManager,
                textStorage: textStorage
            ))
            if headingCheckHasEnoughFollowingContext(on: pageIndex, rows: result) {
                break
            }
            candidatePage += 1
        }
        return result
    }

    private func headingCheckHasEnoughFollowingContext(
        on pageIndex: Int,
        rows: [VisualRow]
    ) -> Bool {
        guard let lastHeading = rows.indices.last(where: {
            rows[$0].pageIndex == pageIndex && rows[$0].isHeading
        }) else { return true }

        var rowIndex = lastHeading
        while rowIndex + 1 < rows.count, rows[rowIndex + 1].isHeading {
            rowIndex += 1
        }
        var followingRows = 0
        while rowIndex + 1 < rows.count {
            rowIndex += 1
            if rows[rowIndex].isHeading { return true }
            followingRows += 1
            if followingRows == 2 { return true }
        }
        return false
    }

    private func visualRows(
        on pageIndex: Int,
        page: TextPage,
        layoutManager: NSLayoutManager,
        textStorage: NSTextStorage
    ) -> [VisualRow] {
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
        var result: [VisualRow] = []
        for fragment in fragments {
            if let lastIndex = result.indices.last,
               abs(result[lastIndex].minY - fragment.minY) < 0.5 {
                result[lastIndex].isHeading = result[lastIndex].isHeading || fragment.isHeading
            } else {
                result.append(fragment)
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

    private func drawFooter(
        pageNumber: Int,
        footers: ResolvedFooterConfiguration
    ) {
        let columns = footerColumnFrames()
        let footerTop = configuration.pageSize.height - configuration.pageMargins.bottom
        let y = footerTop + 16
        drawFooterValue(footers.left, alignment: .left, in: columns.left.offsetBy(dx: 0, dy: y))
        drawFooterValue(String(pageNumber), alignment: .center, in: columns.center.offsetBy(dx: 0, dy: y))
        drawFooterValue(footers.right, alignment: .right, in: columns.right.offsetBy(dx: 0, dy: y))
    }

    private func footerColumnFrames() -> (left: CGRect, center: CGRect, right: CGRect) {
        let availableWidth = configuration.contentWidth
        let centerWidth = min(72, availableWidth * 0.2)
        let sideWidth = max(1, (availableWidth - centerWidth) / 2)
        let originX = configuration.pageMargins.left
        return (
            CGRect(x: originX, y: 0, width: sideWidth, height: 14),
            CGRect(x: originX + sideWidth, y: 0, width: centerWidth, height: 14),
            CGRect(x: originX + sideWidth + centerWidth, y: 0, width: sideWidth, height: 14)
        )
    }

    private func drawFooterValue(
        _ value: String,
        alignment: NSTextAlignment,
        in frame: CGRect
    ) {
        guard !value.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(
            string: value,
            attributes: [
                .font: FontBook(configuration: configuration).regular(size: 8),
                .foregroundColor: configuration.secondaryTextColor,
                .paragraphStyle: paragraph
            ]
        ).draw(
            with: frame,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    private func addingFootnoteNavigation(
        to data: Data,
        attributedText: NSAttributedString,
        pages: [TextPage]
    ) throws -> Data {
        guard containsAttribute(.markdownFootnoteReference, in: attributedText),
              containsAttribute(.markdownFootnoteDefinition, in: attributedText) else {
            return data
        }
        let references = footnoteLocations(
            for: .markdownFootnoteReference,
            in: attributedText,
            pages: pages
        )
        let definitions = footnoteLocations(
            for: .markdownFootnoteDefinition,
            in: attributedText,
            pages: pages
        )
        guard !references.isEmpty, !definitions.isEmpty else { return data }
        guard let document = PDFDocument(data: data) else { throw PDFExporterError.renderingFailed }

        let definitionByLabel = Dictionary(
            uniqueKeysWithValues: definitions.map { ($0.label, $0) }
        )
        let firstReferenceByLabel = Dictionary(
            references.map { ($0.label, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for reference in references {
            guard let definition = definitionByLabel[reference.label] else { continue }
            addFootnoteLink(from: reference, to: definition, in: document)
        }
        for definition in definitions {
            guard let reference = firstReferenceByLabel[definition.label] else { continue }
            addFootnoteLink(from: definition, to: reference, in: document)
        }

        guard let linkedData = document.dataRepresentation() else {
            throw PDFExporterError.renderingFailed
        }
        return linkedData
    }

    private func containsAttribute(
        _ key: NSAttributedString.Key,
        in attributedText: NSAttributedString
    ) -> Bool {
        var found = false
        attributedText.enumerateAttribute(
            key,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func footnoteLocations(
        for key: NSAttributedString.Key,
        in attributedText: NSAttributedString,
        pages: [TextPage]
    ) -> [FootnoteLocation] {
        var locations: [FootnoteLocation] = []
        for (pageIndex, page) in pages.enumerated() {
            page.layoutManager.ensureLayout(for: page.textContainer)
            let characterRange = page.layoutManager.characterRange(
                forGlyphRange: page.glyphRange,
                actualGlyphRange: nil
            )
            guard characterRange.length > 0 else { continue }
            attributedText.enumerateAttribute(key, in: characterRange) { value, range, _ in
                guard let label = value as? String else { return }
                let visibleCharacters = NSIntersectionRange(range, characterRange)
                guard visibleCharacters.length > 0 else { return }
                let glyphs = page.layoutManager.glyphRange(
                    forCharacterRange: visibleCharacters,
                    actualCharacterRange: nil
                )
                let visibleGlyphs = NSIntersectionRange(glyphs, page.glyphRange)
                guard visibleGlyphs.length > 0 else { return }
                let textBounds = page.layoutManager.boundingRect(
                    forGlyphRange: visibleGlyphs,
                    in: page.textContainer
                )
                let pdfBounds = CGRect(
                    x: configuration.pageMargins.left + textBounds.minX,
                    y: configuration.pageSize.height - configuration.pageMargins.top - textBounds.maxY,
                    width: textBounds.width,
                    height: textBounds.height
                ).insetBy(dx: -1, dy: -1)
                locations.append(FootnoteLocation(
                    label: label,
                    pageIndex: pageIndex,
                    bounds: pdfBounds
                ))
            }
        }
        return locations
    }

    private func addFootnoteLink(
        from source: FootnoteLocation,
        to target: FootnoteLocation,
        in document: PDFDocument
    ) {
        guard let sourcePage = document.page(at: source.pageIndex),
              let targetPage = document.page(at: target.pageIndex) else { return }
        let annotation = PDFAnnotation(bounds: source.bounds, forType: .link, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        annotation.action = PDFActionGoTo(destination: PDFDestination(
            page: targetPage,
            at: CGPoint(x: target.bounds.minX, y: target.bounds.maxY + 4)
        ))
        sourcePage.addAnnotation(annotation)
    }

    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        if let pageSetup {
            info.paperName = NSPrinter.PaperName(rawValue: pageSetup.paperName)
        }
        info.paperSize = configuration.pageSize
        info.orientation = (pageSetup?.orientation == .landscape
            || (pageSetup == nil && configuration.pageSize.width > configuration.pageSize.height))
            ? .landscape
            : .portrait
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
        info.scalingFactor = 1
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
    var cachedGlyphRange: NSRange?

    init(layoutManager: NSLayoutManager, textContainer: NSTextContainer, textView: NSTextView) {
        self.layoutManager = layoutManager
        self.textContainer = textContainer
        self.textView = textView
    }

    var glyphRange: NSRange {
        cachedGlyphRange ?? layoutManager.glyphRange(for: textContainer)
    }
}

private struct VisualRow {
    let pageIndex: Int
    let minY: CGFloat
    var isHeading: Bool
}

private struct FootnoteLocation {
    let label: String
    let pageIndex: Int
    let bounds: CGRect
}

private struct PDFOutput {
    let data: NSMutableData
    let context: CGContext
}

public enum PDFExporterError: LocalizedError, Equatable {
    case renderingFailed

    public var errorDescription: String? {
        "The PDF could not be rendered."
    }
}
#endif

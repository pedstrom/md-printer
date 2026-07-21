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
        for page in pages {
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
        var coveredGlyphs = 0

        repeat {
            let textContainer = NSTextContainer(containerSize: contentSize)
            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = true
            layoutManager.addTextContainer(textContainer)
            let textView = NSTextView(
                frame: NSRect(origin: .zero, size: contentSize),
                textContainer: textContainer
            )
            textView.textContainerInset = .zero
            textView.drawsBackground = false
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            pages.append(TextPage(
                layoutManager: layoutManager,
                textContainer: textContainer,
                textView: textView,
                glyphRange: glyphRange
            ))
            let nextCoveredGlyphs = NSMaxRange(glyphRange)
            if nextCoveredGlyphs <= coveredGlyphs { break }
            coveredGlyphs = nextCoveredGlyphs
        } while coveredGlyphs < layoutManager.numberOfGlyphs

        return pages
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

private struct TextPage {
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    let textView: NSTextView
    let glyphRange: NSRange
}

public enum PDFExporterError: LocalizedError, Equatable {
    case renderingFailed

    public var errorDescription: String? {
        "The PDF could not be rendered."
    }
}

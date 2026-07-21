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
        guard let document = PDFDocument(data: data),
              let operation = document.printOperation(
                for: printInfo(),
                scalingMode: .pageScaleToFit,
                autoRotate: true
              ) else {
            throw PDFExporterError.renderingFailed
        }
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
        info.topMargin = configuration.pageMargins.top
        info.leftMargin = configuration.pageMargins.left
        info.bottomMargin = configuration.pageMargins.bottom
        info.rightMargin = configuration.pageMargins.right
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
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

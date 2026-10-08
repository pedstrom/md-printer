#if canImport(AppKit)
import AppKit
import CoreGraphics
import PDFKit

public struct PDFSectionDestination: Equatable, Sendable {
    public let pageIndex: Int
    public let point: CGPoint
}

public struct PDFReviewDestination: Equatable, Sendable {
    public let destination: PDFSectionDestination
    public let lastPageIndex: Int
    public var fragments: [PDFReviewFragment] = []
    public var pageLabel: String {
        destination.pageIndex == lastPageIndex ? "p. \(lastPageIndex + 1)" : "pp. \(destination.pageIndex + 1)–\(lastPageIndex + 1)"
    }
}

/// Preview-only geometry in the PDF's bottom-left coordinate system.
public struct PDFReviewFragment: Equatable, Sendable {
    public let pageIndex: Int
    public let passageBounds: CGRect
    public let bandBounds: CGRect
    public var noteBounds: [CGRect] = []
}

enum PDFReviewFragmentLayout {
    static func fragment(pageIndex: Int, passage: CGRect, configuration: RendererConfiguration, notes: [RevisionPDFNote]) -> PDFReviewFragment {
        let margins = configuration.pageMargins, height = configuration.pageSize.height
        var band = CGRect(x: margins.left / 2, y: passage.minY - 4,
                          width: configuration.pageSize.width - (margins.left + margins.right) / 2,
                          height: passage.height + 8)
        for note in notes {
            if !note.frame.isEmpty { band = band.union(note.frame.insetBy(dx: -4, dy: -4)) }
            for point in note.leader { band = band.union(CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)) }
        }
        // Keep the page gap and footer free of selection paint.
        band = band.intersection(CGRect(x: 0, y: margins.top - 4, width: configuration.pageSize.width,
                                        height: height - margins.top - margins.bottom + 8))
        func pdfRect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        return PDFReviewFragment(pageIndex: pageIndex, passageBounds: pdfRect(passage), bandBounds: pdfRect(band),
                                 noteBounds: notes.filter { !$0.frame.isEmpty }.map { pdfRect($0.frame.insetBy(dx: -2, dy: -2)) })
    }
}

public struct PDFRenderResult: Sendable {
    public let data: Data
    public let sectionDestinations: [String: PDFSectionDestination]
    public var reviewDestinations: [String: PDFReviewDestination] = [:]
}

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
        footers: ResolvedFooterConfiguration = ResolvedFooterConfiguration(),
        decorations: RevisionDecorations = RevisionDecorations()
    ) throws -> Data {
        try render(from: attributedText, footers: footers, decorations: decorations).data
    }

    public func render(
        from attributedText: NSAttributedString,
        footers: ResolvedFooterConfiguration = ResolvedFooterConfiguration(),
        decorations: RevisionDecorations = RevisionDecorations(),
        reviewItems: [RevisionReviewItem] = []
    ) throws -> PDFRenderResult {
        let output = try makePDFOutput()
        let pages = makePages(for: attributedText)
        let revisionNotes = try revisionNotes(for: decorations, text: attributedText, pages: pages)
        let navigation = footnoteNavigation(in: attributedText, pages: pages)
        let sections = sectionDestinations(in: attributedText, pages: pages)
        let sectionLinks = sectionReferences(in: attributedText, pages: pages)
        for (pageIndex, page) in pages.enumerated() {
            draw(
                page: page, pageNumber: pageIndex + 1, footers: footers,
                navigation: navigation, sections: sections, sectionLinks: sectionLinks,
                decorations: decorations, revisionNotes: revisionNotes.filter { $0.page == pageIndex }, in: output.context
            )
        }
        return PDFRenderResult(data: try finishPDFOutput(output), sectionDestinations: sections,
                               reviewDestinations: reviewDestinations(reviewItems, text: attributedText, pages: pages, notes: revisionNotes))
    }

    public func pdfDataAsync(
        from attributedText: NSAttributedString,
        footers: ResolvedFooterConfiguration = ResolvedFooterConfiguration(),
        decorations: RevisionDecorations = RevisionDecorations()
    ) async throws -> Data {
        try await renderAsync(from: attributedText, footers: footers, decorations: decorations).data
    }

    public func renderAsync(
        from attributedText: NSAttributedString,
        footers: ResolvedFooterConfiguration = ResolvedFooterConfiguration(),
        decorations: RevisionDecorations = RevisionDecorations(),
        reviewItems: [RevisionReviewItem] = []
    ) async throws -> PDFRenderResult {
        let output = try makePDFOutput()
        let pages = await makePagesAsync(for: attributedText)
        let revisionNotes = try revisionNotes(for: decorations, text: attributedText, pages: pages)
        let navigation = footnoteNavigation(in: attributedText, pages: pages)
        let sections = sectionDestinations(in: attributedText, pages: pages)
        let sectionLinks = sectionReferences(in: attributedText, pages: pages)
        for (pageIndex, page) in pages.enumerated() {
            try Task.checkCancellation()
            draw(
                page: page, pageNumber: pageIndex + 1, footers: footers,
                navigation: navigation, sections: sections, sectionLinks: sectionLinks,
                decorations: decorations, revisionNotes: revisionNotes.filter { $0.page == pageIndex }, in: output.context
            )
            await Task.yield()
        }
        return PDFRenderResult(data: try finishPDFOutput(output), sectionDestinations: sections,
                               reviewDestinations: reviewDestinations(reviewItems, text: attributedText, pages: pages, notes: revisionNotes))
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
        navigation: [FootnoteLink],
        sections: [String: PDFSectionDestination],
        sectionLinks: [SectionPDFLink],
        decorations: RevisionDecorations,
        revisionNotes: [RevisionPDFNote],
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
        drawRevisionRanges(decorations.highlights, on: page, origin: origin, border: false)
        page.layoutManager.drawGlyphs(forGlyphRange: page.glyphRange, at: origin)
        drawRevisionRanges(decorations.images, on: page, origin: origin, border: true)
        var drawnCarets: [CGPoint] = []
        for note in revisionNotes {
            let font = FontBook(configuration: configuration).regular(size: 7)
            if note.isBoundaryOnly {
                if !drawnCarets.contains(note.anchor) {
                    RevisionAnnotationLayout.draw(label: "…", frame: RevisionAnnotationLayout.caretFrame(at: note.anchor, font: font),
                        font: font, context: context, isImage: true)
                    drawnCarets.append(note.anchor)
                }
            } else if note.isImage {
                RevisionAnnotationLayout.draw(label: note.label, frame: note.frame, font: font, context: context,
                    isImage: true, hasCaret: !note.isMargin)
            } else {
                let hasPrefix = !note.isMargin && note.label.hasPrefix("^ ")
                RevisionAnnotationLayout.draw(label: hasPrefix ? String(note.label.dropFirst(2)) : note.label,
                    frame: note.wordingFrame(font: font), font: font, context: context, hasCaret: false, strikeWording: note.strikeWording)
                if !drawnCarets.contains(note.anchor) {
                    let marker = revisionNotes.contains { $0.anchor == note.anchor && $0.isBoundaryOnly } ? "…" : "^"
                    RevisionAnnotationLayout.draw(label: marker, frame: RevisionAnnotationLayout.caretFrame(at: note.anchor, font: font),
                        font: font, context: context, isImage: true)
                    drawnCarets.append(note.anchor)
                }
            }
            if let start = note.leader.first {
                let leader = NSBezierPath()
                leader.move(to: start)
                for point in note.leader.dropFirst() { leader.line(to: point) }
                leader.lineWidth = 0.4
                leader.setLineDash([1.5, 1.5], count: 2, phase: 0)
                RevisionFormatter.deletionColor.setStroke()
                leader.stroke()
            }
        }
        drawFooter(pageNumber: pageNumber, footers: footers)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        drawFootnoteNavigation(navigation, pageIndex: pageNumber - 1, in: context)
        for (anchor, destination) in sections where destination.pageIndex == pageNumber - 1 {
            context.addDestination("section-\(anchor)" as CFString, at: destination.point)
        }
        for link in sectionLinks where link.pageIndex == pageNumber - 1 && sections[link.anchor] != nil {
            context.setDestination("section-\(link.anchor)" as CFString, for: link.bounds)
        }
        context.endPDFPage()
    }

    private func drawRevisionRanges(_ ranges: [NSRange], on page: TextPage, origin: CGPoint, border: Bool) {
        for range in ranges {
            let glyphs = NSIntersectionRange(page.glyphRange, page.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
            guard glyphs.length > 0 else { continue }
            if !border {
                drawTextHighlight(glyphs, on: page, origin: origin)
                continue
            }
            if let attachment = page.layoutManager.textStorage?.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
               !attachment.bounds.isEmpty {
                // TextKit ignores the stored image baseline offset. Its glyph
                // frame supplies the origin but can include font descenders;
                // preserve the image's own dimensions for the border.
                let glyphFrame = page.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyphs.location, length: 1),
                    in: page.textContainer
                )
                let rect = CGRect(origin: CGPoint(x: origin.x + glyphFrame.minX, y: origin.y + glyphFrame.minY),
                                  size: attachment.bounds.size)
                RevisionFormatter.imageBorderColor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.stroke()
                continue
            }
            page.layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: page.textContainer) { rect, _ in
                let rect = rect.offsetBy(dx: origin.x, dy: origin.y)
                RevisionFormatter.imageBorderColor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                path.lineWidth = 2
                path.stroke()
            }
        }
    }

    private func drawTextHighlight(_ glyphs: NSRange, on page: TextPage, origin: CGPoint) {
        guard let text = page.layoutManager.textStorage else { return }
        let string = text.string as NSString
        func blankEdge(_ glyph: Int) -> Bool {
            let character = page.layoutManager.characterIndexForGlyph(at: glyph)
            guard character < string.length else { return true }
            let value = string.substring(with: string.rangeOfComposedCharacterSequence(at: character))
            if value.contains("\n") || value.contains("\r") { return true }
            return text.attribute(.revisionLiteral, at: character, effectiveRange: nil) as? Bool != true
                && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        RevisionFormatter.highlightColor.setFill()
        page.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
            let selected = NSIntersectionRange(glyphs, lineGlyphs)
            var start = selected.location, end = NSMaxRange(selected)
            while start < end && blankEdge(start) { start += 1 }
            while end > start && blankEdge(end - 1) { end -= 1 }
            guard end > start else { return }
            let rect = page.layoutManager.boundingRect(forGlyphRange: NSRange(location: start, length: end - start), in: page.textContainer)
                .offsetBy(dx: origin.x, dy: origin.y)
            NSBezierPath(rect: rect).fill()
        }
    }

    /// Internal layout seam for checking annotation positions against body
    /// geometry without relying on PDFKit's enlarged overlay selection bounds.
    func revisionNoteLayout(from text: NSAttributedString, decorations: RevisionDecorations) throws -> [RevisionPDFNote] {
        try revisionNotes(for: decorations, text: text, pages: makePages(for: text))
    }

    private func revisionNotes(for decorations: RevisionDecorations, text: NSAttributedString, pages: [TextPage]) throws -> [RevisionPDFNote] {
        guard !decorations.deletions.isEmpty else { return [] }
        let origin = CGPoint(x: configuration.pageMargins.left, y: configuration.pageMargins.top)
        let content = CGRect(x: origin.x, y: origin.y, width: configuration.contentWidth,
                             height: configuration.pageSize.height - configuration.pageMargins.top - configuration.pageMargins.bottom)
        let pageRect = CGRect(origin: .zero, size: configuration.pageSize)
        let font = FontBook(configuration: configuration).regular(size: 7)
        var result: [RevisionPDFNote] = []
        for (index, page) in pages.enumerated() {
            var occupied: [CGRect] = []
            var placementInk: [CGRect] = []
            page.layoutManager.enumerateLineFragments(forGlyphRange: page.glyphRange) { _, used, _, glyphs, _ in
                let ink = self.revisionInkRects(glyphs: glyphs, page: page, text: text, fallback: used)
                    .map { $0.offsetBy(dx: origin.x, dy: origin.y) }
                occupied.append(contentsOf: ink)
                placementInk.append(ink.reduce(CGRect.null) { $0.union($1) })
            }
            let characters = page.layoutManager.characterRange(forGlyphRange: page.glyphRange, actualGlyphRange: nil)
            var pending: [(note: RevisionDeletion, anchor: CGPoint, line: CGRect, cell: CGRect?)] = []
            for note in decorations.deletions {
                let location = min(max(0, note.location), text.length)
                let lastPage = index == pages.count - 1
                guard (location >= characters.location && location < NSMaxRange(characters))
                    || (lastPage && location == text.length) else { continue }
                var anchor = origin
                var line = CGRect(x: origin.x, y: origin.y, width: 0, height: 0)
                if page.glyphRange.length > 0 {
                    let character = min(location, max(0, text.length - 1))
                    let glyph = page.layoutManager.glyphIndexForCharacter(at: character)
                    let fragment = page.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let glyphPosition = page.layoutManager.location(forGlyphAt: glyph)
                    var lineGlyphs = NSRange()
                    let used = page.layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
                    line = revisionInkBounds(glyphs: lineGlyphs, page: page, text: text, fallback: used)
                        .offsetBy(dx: origin.x, dy: origin.y)
                    anchor = CGPoint(x: origin.x + glyphPosition.x + fragment.minX, y: line.maxY)
                    if location == text.length {
                        anchor.x = origin.x + page.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: page.textContainer).maxX
                    }
                }
                let cellBounds = RevisionAnnotationLayout.tableCellBounds(at: location, in: text,
                    layoutManager: page.layoutManager, origin: origin)
                if let cellBounds {
                    anchor.x = min(max(anchor.x, cellBounds.minX), cellBounds.maxX)
                    anchor.y = min(max(anchor.y, cellBounds.minY), cellBounds.maxY)
                }
                pending.append((note, anchor, line, cellBounds))
            }
            let markers = pending.filter { !$0.note.isImage }.map { RevisionAnnotationLayout.caretFrame(at: $0.anchor, font: font) }
            var placedNotes: [RevisionPDFNote] = []
            for item in pending {
                let placed = RevisionAnnotationLayout.place(label: item.note.label, anchor: item.anchor, line: item.line, content: content,
                    page: pageRect, occupied: occupied, notes: placedNotes.map(\.frame), font: font,
                    cellBounds: item.cell, isImage: item.note.isImage, isSummary: item.note.summary != nil, markers: markers, lineBounds: placementInk)
                placedNotes.append(RevisionPDFNote(page: index, anchor: item.anchor, frame: placed.0, label: placed.1,
                    cellBounds: item.cell, isMargin: placed.0.minX < content.minX || placed.0.maxX > content.maxX,
                    isImage: item.note.isImage, strikeWording: item.note.strikesWording, location: item.note.location, reviewMatches: item.note.reviewMatches))
            }
            for position in placedNotes.indices {
                var blockedBands: [CGRect] = []
                let item = pending[position]
                let area = item.cell.map { $0.intersection(content) } ?? content
                let earlierPaths = placedNotes.prefix(position).map(\.leader)
                for attempt in 0..<12 {
                    do {
                        placedNotes[position].leader = try RevisionAnnotationLayout.leader(for: placedNotes[position], font: font,
                            page: pageRect, content: content, occupied: occupied, notes: placedNotes, previous: earlierPaths)
                        break
                    } catch RevisionAnnotationError.noSpace {
                        guard attempt < 11 else {
                            placedNotes[position].frame = CGRect(origin: item.anchor, size: .zero)
                            placedNotes[position].label = "…"
                            break
                        }
                        // A free text rectangle can still be unreachable when
                        // shorter neighboring notes occupy its connecting gap.
                        // Shorten the label before trying another band, without
                        // disturbing any existing path or the document body.
                        let failed = placedNotes[position]
                        let minimumWidth = ceil(("^ …" as NSString).size(withAttributes: [.font: font]).width)
                        let shorter = RevisionAnnotationLayout.truncate(failed.label,
                            width: max(minimumWidth, failed.frame.width / 2), font: font)
                        let canShorten = !failed.isMargin && item.note.summary == nil && shorter != failed.label
                        if !canShorten {
                            blockedBands.append(CGRect(x: area.minX, y: failed.frame.minY, width: area.width, height: failed.frame.height))
                            if failed.isMargin { blockedBands.append(failed.frame) }
                        }
                        let otherFrames = placedNotes.enumerated().filter { $0.offset != position }.map { $0.element.frame }
                        let placed = RevisionAnnotationLayout.place(label: canShorten ? shorter : item.note.label, anchor: item.anchor, line: item.line,
                            content: content, page: pageRect, occupied: occupied,
                            notes: otherFrames + blockedBands + RevisionAnnotationLayout.leaderObstacles(earlierPaths),
                            font: font, cellBounds: item.cell, isImage: item.note.isImage, isSummary: item.note.summary != nil, markers: markers, lineBounds: placementInk)
                        placedNotes[position] = RevisionPDFNote(page: index, anchor: item.anchor, frame: placed.0, label: placed.1,
                            cellBounds: item.cell, isMargin: placed.0.minX < content.minX || placed.0.maxX > content.maxX,
                            isImage: item.note.isImage, strikeWording: item.note.strikesWording, location: item.note.location)
                    }
                }
            }
            result.append(contentsOf: placedNotes)
        }
        return result
    }

    /// TextKit's used line rectangles include leading. Only visible glyph ink
    /// occupies the gap where an overlay can fit; attachments keep full bounds.
    private func revisionInkBounds(glyphs: NSRange, page: TextPage, text: NSAttributedString, fallback: CGRect) -> CGRect {
        revisionInkRects(glyphs: glyphs, page: page, text: text, fallback: fallback).reduce(CGRect.null) { $0.union($1) }
    }

    private func revisionInkRects(glyphs: NSRange, page: TextPage, text: NSAttributedString, fallback: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        for index in glyphs.location..<NSMaxRange(glyphs) {
            let character = page.layoutManager.characterIndexForGlyph(at: index)
            guard character < text.length else { continue }
            if text.attribute(.attachment, at: character, effectiveRange: nil) != nil { return [fallback] }
            guard let font = text.attribute(.font, at: character, effectiveRange: nil) as? NSFont else { continue }
            let string = text.string as NSString
            let visible = string.substring(with: string.rangeOfComposedCharacterSequence(at: character))
            // TextKit can substitute a different font for Unicode glyphs. Its
            // full line bounds are the conservative choice in that case.
            guard visible.unicodeScalars.allSatisfy({ font.coveredCharacterSet.contains($0) || $0.properties.isWhitespace }) else { return [fallback] }
            let bounds = font.boundingRect(forGlyph: page.layoutManager.glyph(at: index))
            guard !bounds.isEmpty else { continue }
            let position = page.layoutManager.location(forGlyphAt: index)
            let fragment = page.layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: nil)
            let ink = CGRect(x: fragment.minX + position.x + bounds.minX,
                             y: fragment.minY + position.y - bounds.maxY,
                             width: bounds.width, height: bounds.height)
            result.append(ink)
        }
        return result.isEmpty ? [fallback] : result
    }

    private func finishPDFOutput(_ output: PDFOutput) throws -> Data {
        output.context.closePDF()
        guard output.data.length > 0 else { throw PDFExporterError.renderingFailed }
        return output.data as Data
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
                // The preceding line can end exactly at this boundary. Cutting into it
                // would move body text too, cascading the break back through the page.
                let newHeight = max(1, headingTop)
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
                let newHeight = max(1, headingTop)
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
        drawFooterLines(footers.leftLines, alignment: .left, in: columns.left.offsetBy(dx: 0, dy: y))
        drawFooterValue(ResolvedFooterLine(text: String(pageNumber)), alignment: .center,
                        in: columns.center.offsetBy(dx: 0, dy: y))
        drawFooterLines(footers.rightLines, alignment: .right, in: columns.right.offsetBy(dx: 0, dy: y))
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

    private func drawFooterLines(
        _ lines: [ResolvedFooterLine],
        alignment: NSTextAlignment,
        in frame: CGRect
    ) {
        for (index, line) in lines.prefix(2).enumerated() {
            drawFooterValue(line, alignment: alignment, in: frame.offsetBy(dx: 0, dy: CGFloat(index) * 12))
        }
    }

    private func drawFooterValue(
        _ line: ResolvedFooterLine,
        alignment: NSTextAlignment,
        in frame: CGRect
    ) {
        guard !line.text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: FontBook(configuration: configuration).regular(size: 8),
            .foregroundColor: configuration.secondaryTextColor,
            .paragraphStyle: paragraph
        ]
        switch line.style {
        case .ordinary: break
        case .current: attributes[.backgroundColor] = RevisionFormatter.highlightColor
        case .original:
            attributes[.foregroundColor] = RevisionFormatter.deletionColor
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = RevisionFormatter.deletionColor
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: frame).addClip()
        NSAttributedString(
            string: line.text,
            attributes: attributes
        ).draw(
            with: frame,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        )
    }

    private func reviewDestinations(_ items: [RevisionReviewItem], text: NSAttributedString, pages: [TextPage], notes: [RevisionPDFNote]) -> [String: PDFReviewDestination] {
        func position(_ location: Int) -> PDFSectionDestination {
            guard text.length > 0 else {
                return PDFSectionDestination(pageIndex: 0, point: CGPoint(x: configuration.pageMargins.left, y: configuration.pageSize.height - configuration.pageMargins.top))
            }
            let character = min(max(0, location), text.length - 1)
            for (index, page) in pages.enumerated() {
                let glyph = page.layoutManager.glyphIndexForCharacter(at: character)
                guard NSLocationInRange(glyph, page.glyphRange) else { continue }
                let rect = page.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: page.textContainer)
                return PDFSectionDestination(pageIndex: index, point: CGPoint(x: configuration.pageMargins.left + rect.minX,
                    y: configuration.pageSize.height - configuration.pageMargins.top - rect.minY + 4))
            }
            return PDFSectionDestination(pageIndex: max(0, pages.count - 1), point: CGPoint(x: configuration.pageMargins.left, y: configuration.pageMargins.bottom))
        }
        return Dictionary(uniqueKeysWithValues: items.map { item in
            let first = position(item.anchor)
            let last = position(max(item.anchor, NSMaxRange(item.currentRange) - 1))
            let fragments = reviewFragments(item, text: text, pages: pages, notes: notes, destination: first)
            return (item.id, PDFReviewDestination(destination: first, lastPageIndex: last.pageIndex, fragments: fragments))
        })
    }

    private func reviewFragments(_ item: RevisionReviewItem, text: NSAttributedString, pages: [TextPage],
                                 notes: [RevisionPDFNote], destination: PDFSectionDestination) -> [PDFReviewFragment] {
        let margins = configuration.pageMargins
        let height = configuration.pageSize.height
        return pages.enumerated().compactMap { index, page in
            var passage = CGRect.null
            if item.currentRange.length > 0 {
                let range = NSIntersectionRange(item.currentRange, NSRange(location: 0, length: text.length))
                let glyphs = NSIntersectionRange(page.glyphRange, page.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
                if glyphs.length > 0 {
                    passage = page.layoutManager.boundingRect(forGlyphRange: glyphs, in: page.textContainer)
                        .offsetBy(dx: margins.left, dy: margins.top)
                }
            } else if index == destination.pageIndex {
                // A removal marks its boundary rather than the next complete paragraph.
                passage = CGRect(x: margins.left, y: height - destination.point.y, width: 1, height: 12)
            }
            guard !passage.isNull else { return nil }
            let related = notes.filter { note in
                let belongs = note.reviewMatches.isEmpty || item.reviewMatches.isEmpty || !note.reviewMatches.isDisjoint(with: item.reviewMatches)
                return belongs && note.page == index && note.location.map({ location in
                item.currentRange.length == 0 ? location == item.anchor
                    : NSLocationInRange(location, item.currentRange)
                        || (location == text.length && location == NSMaxRange(item.currentRange))
            }) == true }
            return PDFReviewFragmentLayout.fragment(pageIndex: index, passage: passage, configuration: configuration, notes: related)
        }
    }

    private func sectionDestinations(in text: NSAttributedString, pages: [TextPage]) -> [String: PDFSectionDestination] {
        var destinations: [String: PDFSectionDestination] = [:]
        for location in footnoteLocations(for: .markdownSectionAnchor, in: text, pages: pages) where destinations[location.label] == nil {
            destinations[location.label] = PDFSectionDestination(pageIndex: location.pageIndex, point: CGPoint(x: location.bounds.minX, y: location.bounds.maxY + 4))
        }
        return destinations
    }

    private func sectionReferences(in text: NSAttributedString, pages: [TextPage]) -> [SectionPDFLink] {
        var links: [SectionPDFLink] = []
        for (pageIndex, page) in pages.enumerated() {
            let characters = page.layoutManager.characterRange(forGlyphRange: page.glyphRange, actualGlyphRange: nil)
            text.enumerateAttribute(.markdownSectionReference, in: characters) { value, range, _ in
                guard let anchor = value as? String else { return }
                let glyphs = NSIntersectionRange(page.glyphRange, page.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
                page.layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, container, lineGlyphs, _ in
                    let visible = NSIntersectionRange(glyphs, lineGlyphs)
                    guard visible.length > 0 else { return }
                    let rect = page.layoutManager.boundingRect(forGlyphRange: visible, in: container)
                    let pdfRect = CGRect(x: self.configuration.pageMargins.left + rect.minX, y: self.configuration.pageSize.height - self.configuration.pageMargins.top - rect.maxY, width: rect.width, height: rect.height)
                    links.append(SectionPDFLink(anchor: anchor, pageIndex: pageIndex, bounds: pdfRect))
                }
            }
        }
        return links
    }

    private func footnoteNavigation(
        in attributedText: NSAttributedString,
        pages: [TextPage]
    ) -> [FootnoteLink] {
        guard containsAttribute(.markdownFootnoteReference, in: attributedText),
              containsAttribute(.markdownFootnoteDefinition, in: attributedText) else {
            return []
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
        guard !references.isEmpty, !definitions.isEmpty else { return [] }

        let definitionByLabel = Dictionary(
            uniqueKeysWithValues: definitions.map { ($0.label, $0) }
        )
        let firstReferenceByLabel = Dictionary(
            references.map { ($0.label, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var links: [FootnoteLink] = []
        for reference in references {
            guard let definition = definitionByLabel[reference.label] else { continue }
            links.append(FootnoteLink(source: reference, target: definition))
        }
        for definition in definitions {
            guard let reference = firstReferenceByLabel[definition.label] else { continue }
            links.append(FootnoteLink(source: definition, target: reference))
        }

        return links
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

    private func drawFootnoteNavigation(
        _ links: [FootnoteLink],
        pageIndex: Int,
        in context: CGContext
    ) {
        // Write named destinations in the original PDF context. Rewriting GoTo
        // actions with PDFKit can serialize malformed page references.
        for (index, link) in links.enumerated() {
            let name = "footnote-\(index)" as CFString
            if link.target.pageIndex == pageIndex {
                context.addDestination(
                    name,
                    at: CGPoint(x: link.target.bounds.minX, y: link.target.bounds.maxY + 4)
                )
            }
            if link.source.pageIndex == pageIndex {
                context.setDestination(name, for: link.source.bounds)
            }
        }
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

private struct SectionPDFLink {
    let anchor: String
    let pageIndex: Int
    let bounds: CGRect
}

private struct FootnoteLink {
    let source: FootnoteLocation
    let target: FootnoteLocation
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

#if canImport(AppKit)
import AppKit
import Foundation

extension NSAttributedString.Key {
    static let wordRevisionNoteGeometry = Self("MarkdownPrinter.wordRevisionNoteGeometry")
    static let wordEmbeddedDrawing = Self("MarkdownPrinter.wordEmbeddedDrawing")
    static let wordRevisionNotes = Self("MarkdownPrinter.wordRevisionNotes")
}

@MainActor
public final class WordExporter {
    private let unzipURL: URL
    private let zipURL: URL
    private static let tableGridWidth = 9_000
    private static let tableCellHorizontalInset: CGFloat = 5.4
    private static let tableCalloutRightAllowance: CGFloat = 8

    public init(
        unzipURL: URL = URL(fileURLWithPath: "/usr/bin/unzip"),
        zipURL: URL = URL(fileURLWithPath: "/usr/bin/zip")
    ) {
        self.unzipURL = unzipURL
        self.zipURL = zipURL
    }

    public func wordData(
        from attributedText: NSAttributedString,
        pageSetup: DocumentPageSetup = .letter,
        footers: ResolvedFooterConfiguration = ResolvedFooterConfiguration(),
        decorations: RevisionDecorations = RevisionDecorations()
    ) throws -> Data {
        let decorated = NSMutableAttributedString(attributedString: attributedText)
        for range in decorations.highlights {
            decorated.addAttributes([.backgroundColor: RevisionFormatter.highlightColor, .revisionHighlight: true], range: range)
        }
        for range in decorations.images { decorated.addAttribute(.revisionImageChanged, value: true, range: range) }
        if decorated.length == 0, !decorations.deletions.isEmpty { decorated.append(NSAttributedString(string: "\u{200b}")) }
        let noteLayout = NSLayoutManager()
        let noteStorage = decorations.deletions.isEmpty ? nil : NSTextStorage(attributedString: decorated)
        defer { withExtendedLifetime(noteStorage) {} }
        if let storage = noteStorage {
            storage.addLayoutManager(noteLayout)
            let container = NSTextContainer(size: CGSize(width: max(1, pageSetup.pageSize.width - 108), height: 10_000_000))
            container.lineFragmentPadding = 0
            noteLayout.addTextContainer(container)
            noteLayout.ensureLayout(for: container)
        }
        for note in decorations.deletions {
            var index = min(note.location, max(0, decorated.length - 1))
            let string = decorated.string as NSString
            while index > 0, [10, 13].contains(string.character(at: index)) { index -= 1 }
            // Anchor to a visible glyph. Splitting a tab into an attributed
            // note run changes the native writer's whitespace expansion.
            var visibleIndex = index
            while visibleIndex < string.length - 1, [9, 32].contains(string.character(at: visibleIndex)) { visibleIndex += 1 }
            if ![10, 13].contains(string.character(at: visibleIndex)) { index = visibleIndex }
            let range = string.rangeOfComposedCharacterSequence(at: index)
            var notes = decorated.attribute(.wordRevisionNotes, at: index, effectiveRange: nil) as? [RevisionDeletion] ?? []
            notes.append(note)
            decorated.addAttribute(.wordRevisionNotes, value: notes, range: range)
            let glyph = noteLayout.glyphIndexForCharacter(at: range.location)
            let fragment = noteLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = noteLayout.location(forGlyphAt: glyph)
            let remaining = max(0, fragment.width - position.x)
            let minimumWidth = minimumCalloutWidth(for: notes)
            let width = min(240, max(42, max(minimumWidth, remaining)))
            let font = decorated.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? NSFont.systemFont(ofSize: 10)
            let geometry: CGRect
            if let cellBounds = try tableCalloutBounds(at: index, in: decorated, minimumWidth: minimumWidth) {
                geometry = CGRect(x: cellBounds.origin.x, y: ceil(font.ascender - font.descender) - 1, width: cellBounds.width, height: 10)
            } else {
                geometry = CGRect(x: min(0, remaining - width), y: ceil(font.ascender - font.descender) - 1, width: width, height: 10)
            }
            decorated.addAttribute(.wordRevisionNoteGeometry, value: NSValue(rect: geometry), range: range)
        }
        let preparedDocument = try prepareDocument(
            decorated,
            pageSetup: pageSetup,
            footers: footers
        )
        let nativeData = try preparedDocument.text.data(
            from: NSRange(location: 0, length: preparedDocument.text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        )
        guard preparedDocument.requiresPackaging else { return nativeData }
        return try packaging(preparedDocument, nativeData: nativeData)
    }

    public func write(_ attributedText: NSAttributedString, to url: URL) throws {
        try wordData(from: attributedText).write(to: url, options: .atomic)
    }

    private func minimumCalloutWidth(for notes: [RevisionDeletion]) -> CGFloat {
        let font = FontBook(configuration: RendererConfiguration()).regular(size: 7)
        return notes.map { note in
            let firstWord = note.text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let informativeStem = String(firstWord.prefix(6))
            let label = note.isImage ? note.label : "^ \(informativeStem)…"
            let full = (label as NSString).size(withAttributes: [.font: font]).width
            let shifted = (String(label.dropFirst(2)) as NSString).size(withAttributes: [.font: font]).width + 8
            return max(full, shifted)
        }.max() ?? 0
    }

    private func tableCalloutBounds(at index: Int, in text: NSAttributedString, minimumWidth: CGFloat) throws -> CGRect? {
        var cellRange = NSRange()
        guard let style = text.attribute(.paragraphStyle, at: index, longestEffectiveRange: &cellRange,
                                        in: NSRange(location: 0, length: text.length)) as? NSParagraphStyle,
              let block = style.textBlocks.first as? NSTextTableBlock else { return nil }
        let columns = max(1, block.table.numberOfColumns)
        // Word tables use the existing equal-column grid, independently of PDF
        // table widths. Leave room for Word's default cell margins and border.
        let cellWidth = CGFloat(Self.tableGridWidth / columns) / 20
        let contentWidth = max(0, cellWidth - 2 * Self.tableCellHorizontalInset - 1)
        // Native Word can size an autofit column slightly narrower than its
        // preferred grid and draw text wider than AppKit's measurement.
        let calloutRight = max(0, contentWidth - Self.tableCalloutRightAllowance)
        guard calloutRight >= minimumWidth else { throw RevisionAnnotationError.noSpace }
        let cell = NSMutableAttributedString(attributedString: text.attributedSubstring(from: cellRange))
        let paragraph = style.mutableCopy() as! NSMutableParagraphStyle
        paragraph.textBlocks = []
        paragraph.alignment = .left
        cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
        let storage = NSTextStorage(attributedString: cell)
        defer { withExtendedLifetime(storage) {} }
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: contentWidth, height: 10_000_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: index - cellRange.location)
        let anchorX = max(0, layout.location(forGlyphAt: glyph).x)
        let remaining = calloutRight - anchorX
        let width = min(calloutRight, min(240, max(42, max(minimumWidth, remaining))))
        return CGRect(x: min(0, remaining - width), y: 0, width: width, height: 10)
    }

    private func prepareDocument(
        _ attributedText: NSAttributedString,
        pageSetup: DocumentPageSetup,
        footers: ResolvedFooterConfiguration
    ) throws -> PreparedWordDocument {
        var images: [WordImage] = []
        var links: [WordLink] = []
        var footnoteReferences: [(label: String, range: NSRange)] = []
        var footnoteDefinitions: [(label: String, range: NSRange)] = []
        attributedText.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            images.append(WordImage(
                token: "MDPRINTERIMAGE\(images.count)\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                range: range,
                attachment: attachment,
                destination: attributedText.attribute(.link, at: range.location, effectiveRange: nil).flatMap { Self.linkDestination(from: $0) },
                changed: attributedText.attribute(.revisionImageChanged, at: range.location, effectiveRange: nil) as? Bool == true,
                notes: calloutXML(attributedText.attribute(.wordRevisionNotes, at: range.location, effectiveRange: nil) as? [RevisionDeletion] ?? [],
                    geometry: attributedText.attribute(.wordRevisionNoteGeometry, at: range.location, effectiveRange: nil) as? NSValue)
            ))
        }

        attributedText.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, range, _ in
            guard let value, let destination = Self.linkDestination(from: value) else { return }
            links.append(WordLink(
                token: "MDPRINTERLINK\(links.count)\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                range: range,
                destination: destination,
                text: attributedText.attributedSubstring(from: range)
            ))
        }

        attributedText.enumerateAttribute(
            .markdownFootnoteReference,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, range, _ in
            guard let label = value as? String else { return }
            footnoteReferences.append((label, range))
        }
        attributedText.enumerateAttribute(
            .markdownFootnoteDefinition,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, range, _ in
            guard let label = value as? String else { return }
            footnoteDefinitions.append((label, range))
        }

        let tables = tables(in: attributedText)
        let quotes = quotes(in: attributedText)
        images.removeAll { image in tables.contains { NSIntersectionRange($0.range, image.range).length > 0 } }
        links.removeAll { link in
            tables.contains { NSIntersectionRange($0.range, link.range).length > 0 }
                || images.contains { $0.range == link.range }
        }
        footnoteReferences.removeAll { reference in
            tables.contains { NSIntersectionRange($0.range, reference.range).length > 0 }
        }
        footnoteDefinitions.removeAll { definition in
            tables.contains { NSIntersectionRange($0.range, definition.range).length > 0 }
        }

        let renderedFootnoteLinks = renderFootnoteLinks(
            references: footnoteReferences,
            definitions: footnoteDefinitions,
            attributedText: attributedText
        ) + renderSectionLinks(in: attributedText, excluding: tables.map(\.range))

        var revisionRuns: [WordRevisionRun] = []
        attributedText.enumerateAttributes(in: NSRange(location: 0, length: attributedText.length)) { attributes, range, _ in
            guard attributes[.wordRevisionNotes] != nil || attributes[.revisionHighlight] as? Bool == true
                    || attributes[.revisionImageChanged] as? Bool == true,
                  !(tables.map(\.range) + images.map(\.range) + links.map(\.range) + renderedFootnoteLinks.map(\.range))
                    .contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }
            // Leave paragraph boundaries and tabs in the native text. A single
            // placeholder spanning them would collapse code lines or change
            // the native writer's whitespace handling.
            let string = attributedText.string as NSString
            let initialRunCount = revisionRuns.count
            var start = range.location
            for index in range.location..<NSMaxRange(range) {
                guard [9, 10, 13, 0x2028, 0x2029].contains(Int(string.character(at: index))) else { continue }
                if index > start {
                    let content = NSRange(location: start, length: index - start)
                    revisionRuns.append(WordRevisionRun(token: "MDPRINTERREVISION" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                        range: content, xml: runXML(for: attributedText.attributedSubstring(from: content))))
                }
                start = index + 1
            }
            if start < NSMaxRange(range) {
                let content = NSRange(location: start, length: NSMaxRange(range) - start)
                revisionRuns.append(WordRevisionRun(token: "MDPRINTERREVISION" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    range: content, xml: runXML(for: attributedText.attributedSubstring(from: content))))
            }
            if revisionRuns.count == initialRunCount, let notes = attributes[.wordRevisionNotes] as? [RevisionDeletion] {
                // Whitespace-only code still needs an anchor. Insert a note-only
                // marker after the native whitespace rather than replacing it.
                revisionRuns.append(WordRevisionRun(token: "MDPRINTERREVISION" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    range: NSRange(location: NSMaxRange(range), length: 0),
                    xml: "<w:r>" + calloutXML(notes, geometry: attributes[.wordRevisionNoteGeometry] as? NSValue) + "</w:r>",
                    attributesSourceLocation: range.location))
            }
        }

        guard !images.isEmpty || !links.isEmpty || !tables.isEmpty
                || !renderedFootnoteLinks.isEmpty || !quotes.isEmpty || !revisionRuns.isEmpty else {
            return PreparedWordDocument(
                text: attributedText,
                images: [],
                links: [],
                footnoteLinks: [],
                tables: [],
                quotes: [],
                pageSetup: pageSetup,
                footers: footers
            )
        }

        let renderedImages = try images.map { try render($0) }
        let renderedLinks = links.map(render)
        var sectionNames: [String: String] = [:]
        attributedText.enumerateAttribute(.markdownSectionAnchor, in: NSRange(location: 0, length: attributedText.length)) { value, _, _ in
            if let anchor = value as? String { sectionNames[anchor] = "MarkdownPrinterSection\(sectionNames.count)" }
        }
        let renderedTables = try tables.enumerated().map { try render($0.element, index: $0.offset, sectionNames: sectionNames) }
        let text = NSMutableAttributedString(attributedString: attributedText)
        let replacements = renderedImages.map {
            WordReplacement(
                range: $0.range,
                token: $0.token,
                removedAttribute: .attachment,
                preservesParagraphStyle: false
            )
        } + renderedLinks.map {
            WordReplacement(
                range: $0.range,
                token: $0.token,
                removedAttribute: .link,
                preservesParagraphStyle: false
            )
        } + renderedFootnoteLinks.map {
            WordReplacement(
                range: $0.range,
                token: $0.token,
                removedAttribute: nil,
                preservesParagraphStyle: $0.bookmarkAnchor.hasPrefix("MarkdownPrinterSection")
            )
        } + renderedTables.map {
            // A table replacement covers its last cell's newline. Preserve that
            // boundary so native Word serialization keeps following content in
            // its own paragraph before the table placeholder is replaced.
            WordReplacement(
                range: $0.range,
                token: $0.token + "\n",
                removedAttribute: nil,
                preservesParagraphStyle: false
            )
        } + revisionRuns.map {
            WordReplacement(range: $0.range, token: $0.token, removedAttribute: .wordRevisionNotes,
                preservesParagraphStyle: true, attributesSourceLocation: $0.attributesSourceLocation)
        } + quotes.map {
            WordReplacement(
                range: $0.range,
                token: $0.token,
                removedAttribute: nil,
                preservesParagraphStyle: true
            )
        }
        var revisionRunNumber = 0
        for replacement in replacements.sorted(by: {
            if $0.range.location != $1.range.location {
                return $0.range.location > $1.range.location
            }
            return $0.range.length > $1.range.length
        }) {
            var attributes = replacement.preservesParagraphStyle
                ? attributedText.attributes(at: replacement.attributesSourceLocation ?? replacement.range.location, effectiveRange: nil)
                : text.attributes(at: replacement.range.location, effectiveRange: nil)
            if let removedAttribute = replacement.removedAttribute {
                attributes.removeValue(forKey: removedAttribute)
            }
            if replacement.preservesParagraphStyle {
                attributes.removeValue(forKey: .attachment)
                attributes.removeValue(forKey: .link)
                attributes.removeValue(forKey: .markdownFootnoteReference)
                attributes.removeValue(forKey: .markdownFootnoteDefinition)
                // Force a separate native Word run so removing the bookmark token keeps adjacent heading text.
                if replacement.token.hasPrefix("MDPRINTERSECTION") { attributes[.kern] = 0.25 }
                if replacement.token.hasPrefix("MDPRINTERREVISION") {
                    revisionRunNumber += 1
                    // Distinct temporary colors keep placeholders in separate
                    // native runs without changing character widths or tabs.
                    attributes[.foregroundColor] = NSColor(srgbRed: CGFloat(revisionRunNumber % 251 + 1) / 255,
                        green: 0, blue: 1, alpha: 1)
                }
            } else {
                attributes.removeValue(forKey: .paragraphStyle)
            }
            text.replaceCharacters(in: replacement.range, with: replacement.token)
            text.addAttributes(
                attributes,
                range: NSRange(location: replacement.range.location, length: replacement.token.utf16.count)
            )
        }
        return PreparedWordDocument(
            text: text,
            images: renderedImages,
            links: renderedLinks,
            footnoteLinks: renderedFootnoteLinks,
            tables: renderedTables,
            quotes: quotes,
            revisionRuns: revisionRuns,
            pageSetup: pageSetup,
            footers: footers
        )
    }

    private static func linkDestination(from value: Any) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String { return string }
        return nil
    }

    private func tables(in attributedText: NSAttributedString) -> [WordTable] {
        var groups: [ObjectIdentifier: [WordTableCell]] = [:]
        attributedText.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.first as? NSTextTableBlock else { return }
            let contentRange = Self.trimmingTrailingNewline(from: range, in: attributedText.string)
            groups[ObjectIdentifier(block.table), default: []].append(WordTableCell(
                row: block.startingRow,
                column: block.startingColumn,
                sourceRange: contentRange,
                text: attributedText.attributedSubstring(from: contentRange)
            ))
        }
        return groups.values.compactMap { cells in
            guard let first = cells.min(by: { $0.textRange.location < $1.textRange.location }),
                  let last = cells.max(by: { NSMaxRange($0.textRange) < NSMaxRange($1.textRange) }) else {
                return nil
            }
            let start = first.textRange.location
            let end = min(NSMaxRange(last.textRange) + 1, attributedText.length)
            return WordTable(
                token: "MDPRINTERTABLE\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                range: NSRange(location: start, length: end - start),
                cells: cells
            )
        }
    }

    private func quotes(in attributedText: NSAttributedString) -> [RenderedWordQuote] {
        var quotes: [RenderedWordQuote] = []
        attributedText.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: attributedText.length)
        ) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  style.textBlocks.contains(where: { block in
                      !(block is NSTextTableBlock)
                          && block.width(for: .border, edge: .minX) > 0
                  }) else { return }

            quotes.append(RenderedWordQuote(
                token: Self.quoteToken(at: quotes.count),
                range: NSRange(location: range.location, length: 0)
            ))
            let string = attributedText.string as NSString
            var searchLocation = range.location
            while searchLocation < NSMaxRange(range),
                  let newlineRange = Self.nextNewline(
                      in: string,
                      range: NSRange(
                          location: searchLocation,
                          length: NSMaxRange(range) - searchLocation
                      )
                  ) {
                let nextLineLocation = NSMaxRange(newlineRange)
                guard nextLineLocation < NSMaxRange(range) else { break }
                quotes.append(RenderedWordQuote(
                    token: Self.quoteToken(at: quotes.count),
                    range: NSRange(location: nextLineLocation, length: 0)
                ))
                searchLocation = nextLineLocation
            }
        }
        return quotes
    }

    private static func nextNewline(in string: NSString, range: NSRange) -> NSRange? {
        let result = string.range(of: "\n", options: [], range: range)
        return result.location == NSNotFound ? nil : result
    }

    private static func quoteToken(at index: Int) -> String {
        "MDPRINTERQUOTE\(index)\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private static func trimmingTrailingNewline(from range: NSRange, in string: String) -> NSRange {
        guard range.length > 0,
              (string as NSString).substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n"
        else { return range }
        return NSRange(location: range.location, length: range.length - 1)
    }

    private func render(_ image: WordImage) throws -> RenderedWordImage {
        guard let sourceImage = image.attachment.image
            ?? image.attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
            let tiffData = sourceImage.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiffData),
            let pngData = representation.representation(using: .png, properties: [:])
        else {
            throw WordExporterError.imageEncodingFailed
        }

        let attachmentSize = image.attachment.bounds.size
        let size = NSSize(
            width: attachmentSize.width > 0 ? attachmentSize.width : sourceImage.size.width,
            height: attachmentSize.height > 0 ? attachmentSize.height : sourceImage.size.height
        )
        return RenderedWordImage(
            token: image.token,
            range: image.range,
            pngData: pngData,
            widthEMU: max(Int64(size.width * 12_700), 12_700),
            heightEMU: max(Int64(size.height * 12_700), 12_700),
            destination: image.destination,
            changed: image.changed,
            notes: image.notes
        )
    }

    private func render(_ link: WordLink) -> RenderedWordLink {
        RenderedWordLink(
            token: link.token,
            range: link.range,
            destination: link.destination,
            runXML: runXML(for: link.text)
        )
    }

    private func render(_ table: WordTable, index: Int, sectionNames: [String: String]) throws -> RenderedWordTable {
        var relationships: [String] = []
        var media: [WordEmbeddedMedia] = []
        let cells = try table.cells.map { cell in
            let text = NSMutableAttributedString(attributedString: cell.text)
            var attachments: [(NSTextAttachment, NSRange)] = []
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let attachment = value as? NSTextAttachment { attachments.append((attachment, range)) }
            }
            for (attachment, range) in attachments {
                let number = media.count
                let fileName = "markdown-printer-table-\(index)-image-\(number).png"
                let relationshipID = "rIdMarkdownPrinterTable\(index)Image\(number)"
                let image = try render(WordImage(token: "", range: range, attachment: attachment, destination: nil,
                    changed: text.attribute(.revisionImageChanged, at: range.location, effectiveRange: nil) as? Bool == true,
                    notes: calloutXML(text.attribute(.wordRevisionNotes, at: range.location, effectiveRange: nil) as? [RevisionDeletion] ?? [],
                    geometry: text.attribute(.wordRevisionNoteGeometry, at: range.location, effectiveRange: nil) as? NSValue)))
                text.addAttribute(.wordEmbeddedDrawing, value: drawingXML(image: image, relationshipID: relationshipID,
                    fileName: fileName, index: 10_000 + index * 1000 + number), range: range)
                media.append(WordEmbeddedMedia(fileName: fileName, data: image.pngData))
                relationships.append("<Relationship Id=\"\(relationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(fileName)\"/>")
            }
            return WordTableCell(row: cell.row, column: cell.column, sourceRange: cell.sourceRange, text: text)
        }
        let xml = tableXML(for: cells) { attributes, run in
            if let anchor = attributes[.markdownSectionReference] as? String,
               let name = sectionNames[anchor] {
                return "<w:hyperlink w:anchor=\"\(name)\">\(run)</w:hyperlink>"
            }
            if let destination = attributes[.link] as? URL {
                let id = "rIdMarkdownPrinterTable\(index)Link\(relationships.count)"
                relationships.append("<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(Self.escapeXML(destination.absoluteString))\" TargetMode=\"External\"/>")
                return "<w:hyperlink r:id=\"\(id)\">\(run)</w:hyperlink>"
            }
            return run
        }
        return RenderedWordTable(token: table.token, range: table.range, tableXML: xml, relationships: relationships, media: media)
    }

    private func renderSectionLinks(in text: NSAttributedString, excluding tables: [NSRange]) -> [RenderedWordFootnoteLink] {
        var headings: [(String, NSRange)] = []
        var references: [(String, NSRange)] = []
        let range = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.markdownSectionAnchor, in: range) { value, range, _ in
            if let anchor = value as? String { headings.append((anchor, NSRange(location: range.location, length: 0))) }
        }
        text.enumerateAttribute(.markdownSectionReference, in: range) { value, range, _ in
            if let anchor = value as? String, !tables.contains(where: { NSIntersectionRange($0, range).length > 0 }) { references.append((anchor, range)) }
        }
        let names = Dictionary(uniqueKeysWithValues: headings.enumerated().map { ($0.element.0, "MarkdownPrinterSection\($0.offset)") })
        return headings.map { anchor, range in
            RenderedWordFootnoteLink(token: "MDPRINTERSECTION\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", range: range, bookmarkAnchor: names[anchor]!, targetAnchor: nil, runXML: "")
        } + references.enumerated().compactMap { index, entry in
            guard let target = names[entry.0] else { return nil }
            return RenderedWordFootnoteLink(token: "MDPRINTERSECTION\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))", range: entry.1, bookmarkAnchor: "MarkdownPrinterSectionReference\(index)", targetAnchor: target, runXML: runXML(for: text.attributedSubstring(from: entry.1)))
        }
    }

    private func renderFootnoteLinks(
        references: [(label: String, range: NSRange)],
        definitions: [(label: String, range: NSRange)],
        attributedText: NSAttributedString
    ) -> [RenderedWordFootnoteLink] {
        let definitionAnchors = Dictionary(uniqueKeysWithValues: definitions.enumerated().map {
            ($0.element.label, "MarkdownPrinterFootnoteDefinition\($0.offset + 1)")
        })
        let referenceAnchors = references.enumerated().map {
            "MarkdownPrinterFootnoteReference\($0.offset + 1)"
        }
        let firstReferenceAnchorByLabel = Dictionary(
            references.enumerated().map { ($0.element.label, referenceAnchors[$0.offset]) },
            uniquingKeysWith: { first, _ in first }
        )

        let renderedReferences = references.enumerated().compactMap { offset, reference in
            definitionAnchors[reference.label].map { definitionAnchor in
                RenderedWordFootnoteLink(
                    token: "MDPRINTERFOOTNOTE\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                    range: reference.range,
                    bookmarkAnchor: referenceAnchors[offset],
                    targetAnchor: definitionAnchor,
                    runXML: runXML(for: attributedText.attributedSubstring(from: reference.range))
                )
            }
        }
        let renderedDefinitions = definitions.enumerated().map { offset, definition in
            RenderedWordFootnoteLink(
                token: "MDPRINTERFOOTNOTE\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                range: definition.range,
                bookmarkAnchor: definitionAnchors[definition.label]!,
                targetAnchor: firstReferenceAnchorByLabel[definition.label],
                runXML: runXML(for: attributedText.attributedSubstring(from: definition.range))
            )
        }
        return renderedReferences + renderedDefinitions
    }

    private func packaging(_ document: PreparedWordDocument, nativeData: Data) throws -> Data {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPrinter-Word-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = temporaryDirectory.appendingPathComponent("Native.docx")
        let expandedURL = temporaryDirectory.appendingPathComponent("Expanded", isDirectory: true)
        let outputURL = temporaryDirectory.appendingPathComponent("Document.docx")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try nativeData.write(to: archiveURL, options: .atomic)
            try run(unzipURL, arguments: ["-q", archiveURL.path, "-d", expandedURL.path])
            try inject(document, into: expandedURL)
            try run(
                zipURL,
                arguments: ["-q", "-X", "-r", outputURL.path, "."],
                currentDirectoryURL: expandedURL
            )
            return try Data(contentsOf: outputURL)
        } catch let error as WordExporterError {
            throw error
        } catch {
            throw WordExporterError.packagingFailed
        }
    }

    private func inject(_ document: PreparedWordDocument, into directoryURL: URL) throws {
        let documentURL = directoryURL.appendingPathComponent("word/document.xml")
        let relationshipsURL = directoryURL.appendingPathComponent("word/_rels/document.xml.rels")
        let contentTypesURL = directoryURL.appendingPathComponent("[Content_Types].xml")
        let mediaURL = directoryURL.appendingPathComponent("word/media", isDirectory: true)
        guard var documentXML = try readXML(at: documentURL),
              var relationshipsXML = try readXML(at: relationshipsURL),
              var contentTypesXML = try readXML(at: contentTypesURL) else {
            throw WordExporterError.packagingFailed
        }

        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        var xmlReplacements: [WordXMLReplacement] = []
        var relationshipFragments: [String] = []
        let nativeXML = documentXML as NSString
        let nativeTokens = document.images.map(\.token) + document.links.map(\.token)
            + document.footnoteLinks.map(\.token) + document.tables.map(\.token)
            + document.quotes.map(\.token) + document.revisionRuns.map(\.token)
        let nativeTokenRanges = tokenRanges(in: nativeXML, expectedTokens: nativeTokens)
        for run in document.revisionRuns {
            guard let tokenRange = nativeTokenRanges[run.token],
                  let range = elementRange(containing: tokenRange, opening: "<w:r>", closing: "</w:r>", in: nativeXML) else {
                throw WordExporterError.packagingFailed
            }
            let nativeRun = nativeXML.substring(with: range)
            var properties = ""
            if let start = nativeRun.range(of: "<w:rPr>"),
               let end = nativeRun.range(of: "</w:rPr>", range: start.lowerBound..<nativeRun.endIndex) {
                properties = String(nativeRun[start.lowerBound..<end.upperBound])
            }
            // The native writer may put expanded tab spaces in the same run
            // as a marker. Split only at the marker, retaining surrounding text.
            let insertion = "</w:t></w:r>" + run.xml + "<w:r>" + properties + "<w:t xml:space=\"preserve\">"
            xmlReplacements.append(WordXMLReplacement(range: tokenRange, value: insertion))
        }
        for (offset, image) in document.images.enumerated() {
            let index = offset + 1
            let relationshipID = "rIdMarkdownPrinterImage\(index)"
            let fileName = "markdown-printer-image-\(index).png"
            guard let range = elementRange(containing: nativeTokenRanges[image.token], opening: "<w:r>", closing: "</w:r>", in: nativeXML) else {
                throw WordExporterError.packagingFailed
            }
            var drawing = "<w:r>" + drawingXML(image: image, relationshipID: relationshipID, fileName: fileName, index: index) + "</w:r>"
            if let destination = image.destination {
                let linkID = "rIdMarkdownPrinterImageLink\(index)"
                drawing = "<w:hyperlink r:id=\"\(linkID)\">" + drawing + "</w:hyperlink>"
                relationshipFragments.append("<Relationship Id=\"\(linkID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(Self.escapeXML(destination))\" TargetMode=\"External\"/>")
            }
            xmlReplacements.append(WordXMLReplacement(range: range, value: drawing))
            relationshipFragments.append(
                "<Relationship Id=\"\(relationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(fileName)\"/>",
            )
            try image.pngData.write(to: mediaURL.appendingPathComponent(fileName), options: .atomic)
        }

        for (offset, link) in document.links.enumerated() {
            let relationshipID = "rIdMarkdownPrinterLink\(offset + 1)"
            guard let range = elementRange(
                containing: nativeTokenRanges[link.token],
                opening: "<w:r>",
                closing: "</w:r>",
                in: nativeXML
            ) else {
                throw WordExporterError.packagingFailed
            }
            xmlReplacements.append(WordXMLReplacement(
                range: range,
                value: "<w:hyperlink r:id=\"\(relationshipID)\">\(link.runXML)</w:hyperlink>"
            ))
            relationshipFragments.append(
                "<Relationship Id=\"\(relationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(Self.escapeXML(link.destination))\" TargetMode=\"External\"/>",
            )
        }

        for (offset, link) in document.footnoteLinks.enumerated() {
            let content = link.targetAnchor.map {
                "<w:hyperlink w:anchor=\"\($0)\">\(link.runXML)</w:hyperlink>"
            } ?? link.runXML
            let bookmarkID = 2_000 + offset
            let replacement = "<w:bookmarkStart w:id=\"\(bookmarkID)\" w:name=\"\(link.bookmarkAnchor)\"/>\(content)<w:bookmarkEnd w:id=\"\(bookmarkID)\"/>"
            guard let range = elementRange(
                containing: nativeTokenRanges[link.token],
                opening: "<w:r>",
                closing: "</w:r>",
                in: nativeXML
            ) else {
                throw WordExporterError.packagingFailed
            }
            xmlReplacements.append(WordXMLReplacement(range: range, value: replacement))
        }

        for table in document.tables {
            guard let range = elementRange(
                containing: nativeTokenRanges[table.token],
                opening: "<w:p>",
                closing: "</w:p>",
                in: nativeXML
            ) else {
                throw WordExporterError.packagingFailed
            }
            xmlReplacements.append(WordXMLReplacement(range: range, value: table.tableXML))
            relationshipFragments.append(contentsOf: table.relationships)
            for media in table.media { try media.data.write(to: mediaURL.appendingPathComponent(media.fileName), options: .atomic) }
        }

        documentXML = try applying(xmlReplacements, to: documentXML)
        let linkedXML = documentXML as NSString
        let linkedTokenRanges = tokenRanges(
            in: linkedXML,
            expectedTokens: document.quotes.map(\.token)
        )
        let quoteReplacements = try document.quotes.map { quote in
            guard let replacement = quoteReplacement(
                containing: linkedTokenRanges[quote.token],
                token: quote.token,
                in: linkedXML
            ) else {
                throw WordExporterError.packagingFailed
            }
            return replacement
        }
        documentXML = try applying(quoteReplacements, to: documentXML)

        let footerRelationshipID = "rIdMarkdownPrinterFooter"
        documentXML = try applyingSectionProperties(
            pageSetup: document.pageSetup,
            footerRelationshipID: footerRelationshipID,
            to: documentXML
        )
        relationshipFragments.append(
            "<Relationship Id=\"\(footerRelationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>",
        )
        relationshipsXML = try inserting(
            relationshipFragments.joined(),
            before: "</Relationships>",
            in: relationshipsXML
        )
        let footerURL = directoryURL.appendingPathComponent("word/footer1.xml")
        try Data(footerXML(for: document).utf8).write(to: footerURL, options: .atomic)

        if !contentTypesXML.contains("Extension=\"png\"") {
            contentTypesXML = try inserting(
                "<Default Extension=\"png\" ContentType=\"image/png\"/>",
                before: "</Types>",
                in: contentTypesXML
            )
        }
        if !contentTypesXML.contains("PartName=\"/word/footer1.xml\"") {
            contentTypesXML = try inserting(
                "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>",
                before: "</Types>",
                in: contentTypesXML
            )
        }

        try Data(documentXML.utf8).write(to: documentURL, options: .atomic)
        try Data(relationshipsXML.utf8).write(to: relationshipsURL, options: .atomic)
        try Data(contentTypesXML.utf8).write(to: contentTypesURL, options: .atomic)
    }

    private func readXML(at url: URL) throws -> String? {
        String(data: try Data(contentsOf: url), encoding: .utf8)
    }

    private func inserting(_ fragment: String, before marker: String, in xml: String) throws -> String {
        guard let range = xml.range(of: marker) else { throw WordExporterError.packagingFailed }
        var result = xml
        result.insert(contentsOf: fragment, at: range.lowerBound)
        return result
    }

    private func applyingSectionProperties(
        pageSetup: DocumentPageSetup,
        footerRelationshipID: String,
        to xml: String
    ) throws -> String {
        guard let start = xml.range(of: "<w:sectPr"),
              let end = xml.range(of: "</w:sectPr>", range: start.lowerBound..<xml.endIndex)
        else { throw WordExporterError.packagingFailed }
        let sectionRange = start.lowerBound..<end.upperBound
        var section = String(xml[sectionRange])
        section = section.replacingOccurrences(
            of: #"<w:footerReference\b[^>]*/>"#,
            with: "",
            options: .regularExpression
        )
        section = section.replacingOccurrences(
            of: #"<w:pgSz\b[^>]*/>"#,
            with: "",
            options: .regularExpression
        )
        section = section.replacingOccurrences(
            of: #"<w:pgMar\b[^>]*/>"#,
            with: "",
            options: .regularExpression
        )
        guard let openingEnd = section.firstIndex(of: ">") else {
            throw WordExporterError.packagingFailed
        }
        let size = pageSetup.pageSize
        let orientation = pageSetup.orientation == .landscape
            ? " w:orient=\"landscape\""
            : ""
        let fragment = "<w:footerReference w:type=\"default\" r:id=\"\(footerRelationshipID)\"/>"
            + "<w:pgSz w:w=\"\(Int((size.width * 20).rounded()))\" w:h=\"\(Int((size.height * 20).rounded()))\"\(orientation)/>"
            + "<w:pgMar w:top=\"1080\" w:right=\"1080\" w:bottom=\"1080\" w:left=\"1080\" w:header=\"360\" w:footer=\"360\" w:gutter=\"0\"/>"
        section.insert(contentsOf: fragment, at: section.index(after: openingEnd))
        var result = xml
        result.replaceSubrange(sectionRange, with: section)
        return result
    }

    private func footerXML(for document: PreparedWordDocument) -> String {
        let pageWidth = Int((document.pageSetup.pageSize.width * 20).rounded())
        let contentWidth = max(1, pageWidth - 2_160)
        let centerWidth = min(1_440, Int(Double(contentWidth) * 0.2))
        let sideWidth = max(1, (contentWidth - centerWidth) / 2)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:tbl>
            <w:tblPr><w:tblW w:w="\(contentWidth)" w:type="dxa"/><w:tblLayout w:type="fixed"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="0" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="0" w:type="dxa"/></w:tblCellMar></w:tblPr>
            <w:tblGrid><w:gridCol w:w="\(sideWidth)"/><w:gridCol w:w="\(centerWidth)"/><w:gridCol w:w="\(sideWidth)"/></w:tblGrid>
            <w:tr>
              <w:tc><w:tcPr><w:tcW w:w="\(sideWidth)" w:type="dxa"/><w:noWrap/></w:tcPr>\(footerParagraphs(lines: document.footers.leftLines, alignment: "left", width: CGFloat(sideWidth) / 20))</w:tc>
              <w:tc><w:tcPr><w:tcW w:w="\(centerWidth)" w:type="dxa"/></w:tcPr>\(pageFieldParagraph())</w:tc>
              <w:tc><w:tcPr><w:tcW w:w="\(sideWidth)" w:type="dxa"/><w:noWrap/></w:tcPr>\(footerParagraphs(lines: document.footers.rightLines, alignment: "right", width: CGFloat(sideWidth) / 20))</w:tc>
            </w:tr>
          </w:tbl>
        </w:ftr>
        """
    }

    private func footerParagraphs(lines: [ResolvedFooterLine], alignment: String, width: CGFloat) -> String {
        let font = FontBook(configuration: RendererConfiguration()).regular(size: 8)
        let visibleLines = lines.isEmpty ? [ResolvedFooterLine(text: "")] : Array(lines.prefix(2))
        return visibleLines.map { line in
            let value = Self.escapeXML(RevisionAnnotationLayout.truncate(line.text, width: width, font: font))
            let color = line.style == .original ? "C70F14" : "808080"
            let style: String
            switch line.style {
            case .ordinary: style = ""
            case .current: style = "<w:highlight w:val=\"yellow\"/>"
            case .original: style = "<w:strike/>"
            }
            let family = Self.escapeXML(font.familyName ?? font.fontName)
            return "<w:p><w:pPr><w:jc w:val=\"\(alignment)\"/><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"exact\"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=\"\(family)\" w:hAnsi=\"\(family)\"/><w:sz w:val=\"16\"/><w:color w:val=\"\(color)\"/>\(style)</w:rPr><w:t xml:space=\"preserve\">\(value)</w:t></w:r></w:p>"
        }.joined()
    }

    private func pageFieldParagraph() -> String {
        let properties = "<w:rPr><w:rFonts w:ascii=\"Avenir Next\" w:hAnsi=\"Avenir Next\"/><w:sz w:val=\"16\"/><w:color w:val=\"808080\"/></w:rPr>"
        return "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
            + "<w:r>\(properties)<w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + "<w:r>\(properties)<w:instrText xml:space=\"preserve\"> PAGE </w:instrText></w:r>"
            + "<w:r>\(properties)<w:fldChar w:fldCharType=\"separate\"/></w:r>"
            + "<w:r>\(properties)<w:t>1</w:t></w:r>"
            + "<w:r>\(properties)<w:fldChar w:fldCharType=\"end\"/></w:r></w:p>"
    }

    private func tokenRanges(
        in xml: NSString,
        expectedTokens: [String]
    ) -> [String: NSRange] {
        guard !expectedTokens.isEmpty else { return [:] }
        let expected = Set(expectedTokens)
        let minimumLength = expectedTokens.map(\.utf16.count).min() ?? 0
        let maximumLength = expectedTokens.map(\.utf16.count).max() ?? 0
        var result: [String: NSRange] = [:]
        var searchLocation = 0
        while searchLocation < xml.length {
            let marker = xml.range(
                of: "MDPRINTER",
                range: NSRange(
                    location: searchLocation,
                    length: xml.length - searchLocation
                )
            )
            guard marker.location != NSNotFound else { break }

            let available = min(maximumLength, xml.length - marker.location)
            if available >= minimumLength {
                for length in stride(from: available, through: minimumLength, by: -1) {
                    let range = NSRange(location: marker.location, length: length)
                    let candidate = xml.substring(with: range)
                    if expected.contains(candidate) {
                        result[candidate] = range
                        break
                    }
                }
            }
            searchLocation = NSMaxRange(marker)
        }
        return result
    }

    private func elementRange(
        containing tokenRange: NSRange?,
        opening: String,
        closing: String,
        in xml: NSString
    ) -> NSRange? {
        guard let tokenRange else { return nil }
        let backwardStart = max(0, tokenRange.location - 16_384)
        let start = xml.range(
            of: opening,
            options: .backwards,
            range: NSRange(
                location: backwardStart,
                length: tokenRange.location - backwardStart
            )
        )
        let afterToken = NSMaxRange(tokenRange)
        let end = xml.range(
            of: closing,
            range: NSRange(location: afterToken, length: xml.length - afterToken)
        )
        guard start.location != NSNotFound, end.location != NSNotFound else { return nil }
        return NSRange(location: start.location, length: NSMaxRange(end) - start.location)
    }

    private func applying(
        _ replacements: [WordXMLReplacement],
        to xml: String
    ) throws -> String {
        let sorted = replacements.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location > rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }
        var nextEnd = Int.max
        let result = NSMutableString(string: xml)
        for replacement in sorted {
            guard NSMaxRange(replacement.range) <= nextEnd,
                  NSMaxRange(replacement.range) <= result.length else {
                throw WordExporterError.packagingFailed
            }
            result.replaceCharacters(in: replacement.range, with: replacement.value)
            nextEnd = replacement.range.location
        }
        return result as String
    }

    private func quoteReplacement(
        containing tokenRange: NSRange?,
        token: String,
        in xml: NSString
    ) -> WordXMLReplacement? {
        guard let range = elementRange(
            containing: tokenRange,
            opening: "<w:p>",
            closing: "</w:p>",
            in: xml
        ) else { return nil }
        var paragraph = xml.substring(with: range)
        guard paragraph.contains(token) else { return nil }
        paragraph = paragraph.replacingOccurrences(of: token, with: "")
        let border = "<w:pBdr><w:left w:val=\"single\" w:sz=\"12\" w:space=\"8\" w:color=\"7F7F7F\"/></w:pBdr>"
        let indent = "<w:ind w:left=\"360\"/>"
        if let propertiesStart = paragraph.range(of: "<w:pPr>"),
           paragraph.range(of: "</w:pPr>") != nil {
            paragraph.insert(contentsOf: border, at: propertiesStart.upperBound)
            guard let updatedPropertiesEnd = paragraph.range(of: "</w:pPr>") else {
                return nil
            }
            paragraph.insert(contentsOf: indent, at: updatedPropertiesEnd.lowerBound)
        } else {
            guard let openingParagraph = paragraph.range(of: "<w:p>") else { return nil }
            paragraph.insert(
                contentsOf: "<w:pPr>\(border)\(indent)</w:pPr>",
                at: openingParagraph.upperBound
            )
        }
        return WordXMLReplacement(range: range, value: paragraph)
    }

    private func tableXML(for cells: [WordTableCell], linkRun: @escaping ([NSAttributedString.Key: Any], String) -> String) -> String {
        let rows = Dictionary(grouping: cells, by: \.row)
        let maximumColumn = cells.map(\.column).max() ?? 0
        let columns = max(maximumColumn + 1, 1)
        let gridWidth = Self.tableGridWidth / columns
        let grid = (0..<columns).map { _ in "<w:gridCol w:w=\"\(gridWidth)\"/>" }.joined()
        let rowXML = rows.keys.sorted().map { row in
            let cellsByColumn = Dictionary(uniqueKeysWithValues: rows[row, default: []].map { ($0.column, $0) })
            let content = (0..<columns).map { column in
                let cell = cellsByColumn[column]
                return "<w:tc><w:tcPr><w:tcW w:w=\"\(gridWidth)\" w:type=\"dxa\"/></w:tcPr><w:p>\(cell.map { runXML(for: $0.text, linkRun: linkRun) } ?? "<w:r><w:t></w:t></w:r>")</w:p></w:tc>"
            }.joined()
            return "<w:tr>\(content)</w:tr>"
        }.joined()
        return "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:left w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:right w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/></w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>\(rowXML)</w:tbl>"
    }

    private func runXML(for text: NSAttributedString, linkRun: (([NSAttributedString.Key: Any], String) -> String)? = nil) -> String {
        guard text.length > 0 else { return "<w:r><w:t></w:t></w:r>" }
        var xml = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            if let drawing = attributes[.wordEmbeddedDrawing] as? String {
                let run = "<w:r>" + drawing + "</w:r>"
                xml += linkRun?(attributes, run) ?? run
                return
            }
            let value = (text.string as NSString).substring(with: range)
            let font = attributes[.font] as? NSFont
            var properties = ""
            if let font {
                properties += "<w:rFonts w:ascii=\"\(Self.escapeXML(font.familyName ?? font.fontName))\" w:hAnsi=\"\(Self.escapeXML(font.familyName ?? font.fontName))\"/>"
                properties += "<w:sz w:val=\"\(Int(font.pointSize * 2))\"/>"
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { properties += "<w:b/>" }
                if traits.contains(.italicFontMask) { properties += "<w:i/>" }
            }
            if attributes[.underlineStyle] != nil { properties += "<w:u w:val=\"single\"/>" }
            if attributes[.strikethroughStyle] != nil { properties += "<w:strike/>" }
            if let baselineOffset = attributes[.baselineOffset] as? NSNumber {
                properties += "<w:position w:val=\"\(Int(baselineOffset.doubleValue * 2))\"/>"
            }
            if attributes[.revisionHighlight] as? Bool == true { properties += "<w:highlight w:val=\"yellow\"/>" }
            if attributes[.revisionImageChanged] as? Bool == true { properties += "<w:bdr w:val=\"single\" w:sz=\"16\" w:space=\"0\" w:color=\"EBBA00\"/>" }
            if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.deviceRGB) {
                properties += String(format: "<w:color w:val=\"%02X%02X%02X\"/>", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
            }
            let run = "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(Self.escapeXML(value == "\u{200b}" ? "" : value))</w:t></w:r>"
            let notes = attributes[.wordRevisionNotes] as? [RevisionDeletion] ?? []
            if !notes.isEmpty { xml += "<w:r>" + calloutXML(notes, geometry: attributes[.wordRevisionNoteGeometry] as? NSValue) + "</w:r>" }
            xml += linkRun?(attributes, run) ?? run
        }
        return xml
    }

    private func calloutXML(_ notes: [RevisionDeletion], geometry: NSValue? = nil) -> String {
        let font = FontBook(configuration: RendererConfiguration()).regular(size: 7)
        let bounds = geometry?.rectValue ?? CGRect(x: 0, y: 12, width: 240, height: 10)
        func box(_ label: String, x: CGFloat, y: CGFloat, width: CGFloat,
                 strikeWording: Bool, includesCaret: Bool = false) -> String {
            func run(_ text: String, struck: Bool) -> String {
                let strike = struck ? "<w:strike/>" : ""
                return "<w:r><w:rPr><w:rFonts w:ascii=\"\(Self.escapeXML(font.familyName ?? font.fontName))\" w:hAnsi=\"\(Self.escapeXML(font.familyName ?? font.fontName))\"/><w:sz w:val=\"14\"/><w:color w:val=\"C70F14\"/>\(strike)</w:rPr><w:t xml:space=\"preserve\">\(Self.escapeXML(text))</w:t></w:r>"
            }
            let runs = includesCaret && strikeWording
                ? run(String(label.prefix(2)), struck: false) + run(String(label.dropFirst(2)), struck: true)
                : run(label, struck: strikeWording)
            return """
            <w:pict><v:rect xmlns:v="urn:schemas-microsoft-com:vml" id="Revision\(UUID().uuidString)" style="position:absolute;margin-left:\(x)pt;margin-top:\(y)pt;width:\(width)pt;height:10pt;z-index:1;mso-position-horizontal-relative:char;mso-position-vertical-relative:line" filled="f" stroked="f"><v:textbox inset="0,0,0,0"><w:txbxContent><w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>\(runs)</w:p></w:txbxContent></v:textbox><w10:wrap xmlns:w10="urn:schemas-microsoft-com:office:word" type="none"/></v:rect></w:pict>
            """
        }
        return notes.enumerated().map { index, note in
            let y = bounds.minY + CGFloat(index * 10)
            let label = RevisionAnnotationLayout.truncate(note.label, width: bounds.width, font: font)
            guard bounds.minX < 0 else { return box(label, x: 0, y: y, width: bounds.width,
                                                     strikeWording: !note.isImage, includesCaret: true) }
            let caretWidth = min(8, bounds.width)
            let caretX = min(0, bounds.maxX - caretWidth)
            let caret = box("^", x: caretX, y: y, width: caretWidth, strikeWording: false)
            let shiftedWidth = max(0, bounds.width - caretWidth)
            let shifted = box(RevisionAnnotationLayout.truncate(String(note.label.dropFirst(2)), width: shiftedWidth, font: font),
                              x: bounds.minX, y: y, width: shiftedWidth, strikeWording: !note.isImage)
            let leader = """
            <w:pict><v:line xmlns:v="urn:schemas-microsoft-com:vml" from="0,0" to="\(-bounds.minX),0" strokecolor="#C70F14" strokeweight="0.4pt" style="position:absolute;margin-left:\(bounds.minX)pt;margin-top:\(y)pt;mso-position-horizontal-relative:char;mso-position-vertical-relative:line"><w10:wrap xmlns:w10="urn:schemas-microsoft-com:office:word" type="none"/></v:line></w:pict>
            """
            return caret + shifted + leader
        }.joined()
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func drawingXML(
        image: RenderedWordImage,
        relationshipID: String,
        fileName: String,
        index: Int
    ) -> String {
        let border = image.changed ? "<a:ln w=\"25400\"><a:solidFill><a:srgbClr val=\"EBBA00\"/></a:solidFill></a:ln>" : ""
        return image.notes + """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><wp:extent cx="\(image.widthEMU)" cy="\(image.heightEMU)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(1000 + index)" name="Image \(index)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="\(fileName)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(image.widthEMU)" cy="\(image.heightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\(border)</pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
        """
    }

    private func run(
        _ executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WordExporterError.packagingFailed
        }
        guard process.terminationStatus == 0 else {
            throw WordExporterError.packagingFailed
        }
    }
}

public enum WordExporterError: LocalizedError, Equatable {
    case imageEncodingFailed
    case packagingFailed

    public var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "An embedded image could not be prepared for Microsoft Word."
        case .packagingFailed:
            return "The Microsoft Word document could not be packaged."
        }
    }
}

private struct PreparedWordDocument {
    let text: NSAttributedString
    let images: [RenderedWordImage]
    let links: [RenderedWordLink]
    let footnoteLinks: [RenderedWordFootnoteLink]
    let tables: [RenderedWordTable]
    let quotes: [RenderedWordQuote]
    var revisionRuns: [WordRevisionRun] = []
    let pageSetup: DocumentPageSetup
    let footers: ResolvedFooterConfiguration

    var requiresPackaging: Bool {
        true
    }
}

private struct WordRevisionRun {
    let token: String
    let range: NSRange
    let xml: String
    var attributesSourceLocation: Int? = nil
}

private struct WordReplacement {
    let range: NSRange
    let token: String
    let removedAttribute: NSAttributedString.Key?
    let preservesParagraphStyle: Bool
    var attributesSourceLocation: Int? = nil
}

private struct WordXMLReplacement {
    let range: NSRange
    let value: String
}

private struct RenderedWordQuote {
    let token: String
    let range: NSRange
}

private struct WordImage {
    let token: String
    let range: NSRange
    let attachment: NSTextAttachment
    let destination: String?
    let changed: Bool
    let notes: String
}

private struct RenderedWordImage {
    let token: String
    let range: NSRange
    let pngData: Data
    let widthEMU: Int64
    let heightEMU: Int64
    let destination: String?
    let changed: Bool
    let notes: String
}

private struct WordLink {
    let token: String
    let range: NSRange
    let destination: String
    let text: NSAttributedString
}

private struct RenderedWordLink {
    let token: String
    let range: NSRange
    let destination: String
    let runXML: String
}

private struct RenderedWordFootnoteLink {
    let token: String
    let range: NSRange
    let bookmarkAnchor: String
    let targetAnchor: String?
    let runXML: String
}

private struct WordTable {
    let token: String
    let range: NSRange
    let cells: [WordTableCell]
}

private struct WordTableCell {
    let row: Int
    let column: Int
    let sourceRange: NSRange
    let text: NSAttributedString

    var textRange: NSRange {
        sourceRange
    }
}

private struct WordEmbeddedMedia {
    let fileName: String
    let data: Data
}

private struct RenderedWordTable {
    let token: String
    let range: NSRange
    let tableXML: String
    let relationships: [String]
    var media: [WordEmbeddedMedia] = []
}
#endif

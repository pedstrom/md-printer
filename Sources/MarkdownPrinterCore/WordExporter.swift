import AppKit
import Foundation

@MainActor
public final class WordExporter {
    private let unzipURL: URL
    private let zipURL: URL

    public init(
        unzipURL: URL = URL(fileURLWithPath: "/usr/bin/unzip"),
        zipURL: URL = URL(fileURLWithPath: "/usr/bin/zip")
    ) {
        self.unzipURL = unzipURL
        self.zipURL = zipURL
    }

    public func wordData(from attributedText: NSAttributedString) throws -> Data {
        let preparedDocument = try prepareDocument(attributedText)
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

    private func prepareDocument(_ attributedText: NSAttributedString) throws -> PreparedWordDocument {
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
                attachment: attachment
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
        images.removeAll { image in tables.contains { NSIntersectionRange($0.range, image.range).length > 0 } }
        links.removeAll { link in tables.contains { NSIntersectionRange($0.range, link.range).length > 0 } }
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
        )

        guard !images.isEmpty || !links.isEmpty || !tables.isEmpty || !renderedFootnoteLinks.isEmpty else {
            return PreparedWordDocument(
                text: attributedText,
                images: [],
                links: [],
                footnoteLinks: [],
                tables: []
            )
        }

        let renderedImages = try images.map { try render($0) }
        let renderedLinks = links.map(render)
        let renderedTables = tables.map(render)
        let text = NSMutableAttributedString(attributedString: attributedText)
        let replacements = renderedImages.map {
            WordReplacement(range: $0.range, token: $0.token, removedAttribute: .attachment)
        } + renderedLinks.map {
            WordReplacement(range: $0.range, token: $0.token, removedAttribute: .link)
        } + renderedFootnoteLinks.map {
            WordReplacement(range: $0.range, token: $0.token, removedAttribute: nil)
        } + renderedTables.map {
            WordReplacement(range: $0.range, token: $0.token, removedAttribute: nil)
        }
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            var attributes = text.attributes(at: replacement.range.location, effectiveRange: nil)
            if let removedAttribute = replacement.removedAttribute {
                attributes.removeValue(forKey: removedAttribute)
            }
            attributes.removeValue(forKey: .paragraphStyle)
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
            tables: renderedTables
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
            heightEMU: max(Int64(size.height * 12_700), 12_700)
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

    private func render(_ table: WordTable) -> RenderedWordTable {
        RenderedWordTable(
            token: table.token,
            range: table.range,
            tableXML: tableXML(for: table.cells)
        )
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
        for (offset, image) in document.images.enumerated() {
            let index = offset + 1
            let relationshipID = "rIdMarkdownPrinterImage\(index)"
            let fileName = "markdown-printer-image-\(index).png"
            guard replaceTextElement(
                containing: image.token,
                with: drawingXML(
                    image: image,
                    relationshipID: relationshipID,
                    fileName: fileName,
                    index: index
                ),
                in: &documentXML
            ) else {
                throw WordExporterError.packagingFailed
            }
            relationshipsXML = try inserting(
                "<Relationship Id=\"\(relationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(fileName)\"/>",
                before: "</Relationships>",
                in: relationshipsXML
            )
            try image.pngData.write(to: mediaURL.appendingPathComponent(fileName), options: .atomic)
        }

        for (offset, link) in document.links.enumerated() {
            let relationshipID = "rIdMarkdownPrinterLink\(offset + 1)"
            guard replaceTextElement(
                containing: link.token,
                with: "<w:hyperlink r:id=\"\(relationshipID)\">\(link.runXML)</w:hyperlink>",
                in: &documentXML
            ) else {
                throw WordExporterError.packagingFailed
            }
            relationshipsXML = try inserting(
                "<Relationship Id=\"\(relationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(Self.escapeXML(link.destination))\" TargetMode=\"External\"/>",
                before: "</Relationships>",
                in: relationshipsXML
            )
        }

        for (offset, link) in document.footnoteLinks.enumerated() {
            let content = link.targetAnchor.map {
                "<w:hyperlink w:anchor=\"\($0)\">\(link.runXML)</w:hyperlink>"
            } ?? link.runXML
            let bookmarkID = 2_000 + offset
            let replacement = "<w:bookmarkStart w:id=\"\(bookmarkID)\" w:name=\"\(link.bookmarkAnchor)\"/>\(content)<w:bookmarkEnd w:id=\"\(bookmarkID)\"/>"
            guard replaceTextElement(
                containing: link.token,
                with: replacement,
                in: &documentXML
            ) else {
                throw WordExporterError.packagingFailed
            }
        }

        for table in document.tables {
            guard replaceParagraph(
                containing: table.token,
                with: table.tableXML,
                in: &documentXML
            ) else {
                throw WordExporterError.packagingFailed
            }
        }

        if !contentTypesXML.contains("Extension=\"png\"") {
            contentTypesXML = try inserting(
                "<Default Extension=\"png\" ContentType=\"image/png\"/>",
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

    private func replaceTextElement(
        containing token: String,
        with replacement: String,
        in xml: inout String
    ) -> Bool {
        guard let tokenRange = xml.range(of: token),
              let start = xml[..<tokenRange.lowerBound].range(of: "<w:t", options: .backwards),
              let end = xml[tokenRange.upperBound...].range(of: "</w:t>") else {
            return false
        }
        xml.replaceSubrange(start.lowerBound..<end.upperBound, with: replacement)
        return true
    }

    private func replaceParagraph(
        containing token: String,
        with replacement: String,
        in xml: inout String
    ) -> Bool {
        guard let tokenRange = xml.range(of: token),
              let start = xml[..<tokenRange.lowerBound].range(of: "<w:p>", options: .backwards),
              let end = xml[tokenRange.upperBound...].range(of: "</w:p>") else {
            return false
        }
        xml.replaceSubrange(start.lowerBound..<end.upperBound, with: replacement)
        return true
    }

    private func tableXML(for cells: [WordTableCell]) -> String {
        let rows = Dictionary(grouping: cells, by: \.row)
        let maximumColumn = cells.map(\.column).max() ?? 0
        let columns = max(maximumColumn + 1, 1)
        let gridWidth = 9_000 / columns
        let grid = (0..<columns).map { _ in "<w:gridCol w:w=\"\(gridWidth)\"/>" }.joined()
        let rowXML = rows.keys.sorted().map { row in
            let cellsByColumn = Dictionary(uniqueKeysWithValues: rows[row, default: []].map { ($0.column, $0) })
            let content = (0..<columns).map { column in
                let cell = cellsByColumn[column]
                return "<w:tc><w:tcPr><w:tcW w:w=\"\(gridWidth)\" w:type=\"dxa\"/></w:tcPr><w:p>\(cell.map { runXML(for: $0.text) } ?? "<w:r><w:t></w:t></w:r>")</w:p></w:tc>"
            }.joined()
            return "<w:tr>\(content)</w:tr>"
        }.joined()
        return "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:left w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:right w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:insideH w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/><w:insideV w:val=\"single\" w:sz=\"4\" w:color=\"B8B8B8\"/></w:tblBorders></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>\(rowXML)</w:tbl>"
    }

    private func runXML(for text: NSAttributedString) -> String {
        guard text.length > 0 else { return "<w:r><w:t></w:t></w:r>" }
        var xml = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
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
            xml += "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(Self.escapeXML(value))</w:t></w:r>"
        }
        return xml
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
        """
        <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><wp:extent cx="\(image.widthEMU)" cy="\(image.heightEMU)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(1000 + index)" name="Image \(index)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="\(fileName)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(image.widthEMU)" cy="\(image.heightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
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

    var requiresPackaging: Bool {
        !images.isEmpty || !links.isEmpty || !footnoteLinks.isEmpty || !tables.isEmpty
    }
}

private struct WordReplacement {
    let range: NSRange
    let token: String
    let removedAttribute: NSAttributedString.Key?
}

private struct WordImage {
    let token: String
    let range: NSRange
    let attachment: NSTextAttachment
}

private struct RenderedWordImage {
    let token: String
    let range: NSRange
    let pngData: Data
    let widthEMU: Int64
    let heightEMU: Int64
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

private struct RenderedWordTable {
    let token: String
    let range: NSRange
    let tableXML: String
}

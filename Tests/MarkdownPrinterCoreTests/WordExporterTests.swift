import AppKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class WordExporterTests: XCTestCase {
    func testExportFormatsExposeExpectedNamesExtensionsAndContentTypes() {
        XCTAssertEqual(ExportFormat.allCases, [.pdf, .word])
        XCTAssertEqual(ExportFormat.pdf.id, "pdf")
        XCTAssertEqual(ExportFormat.pdf.displayName, "PDF")
        XCTAssertEqual(ExportFormat.pdf.pathExtension, "pdf")
        XCTAssertEqual(ExportFormat.pdf.contentType.identifier, "com.adobe.pdf")
        XCTAssertEqual(ExportFormat.word.id, "word")
        XCTAssertEqual(ExportFormat.word.displayName, "Microsoft Word")
        XCTAssertEqual(ExportFormat.word.pathExtension, "docx")
        XCTAssertEqual(
            ExportFormat.word.contentType.identifier,
            "org.openxmlformats.wordprocessingml.document"
        )
    }

    func testWordExportProducesEditableOfficeOpenXMLWithRepresentativeContent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("sample.png")
        try makePNG().write(to: imageURL)
        let markdown = """
        # Quarterly Résumé

        Text with **bold**, *italic*, <u>underline</u>, `code`, and [a link](https://example.com).

        - First item
        - Second item

        | Name | Value |
        | --- | ---: |
        | Alpha | 42 |

        ![Sample](sample.png)

        ![Offline](https://example.com/remote.png)
        """
        let rendered = MarkdownRenderer().render(markdown: markdown, baseURL: directory)

        let data = try WordExporter().wordData(from: rendered)
        let outputURL = directory.appendingPathComponent("Representative.docx")
        try data.write(to: outputURL)

        XCTAssertTrue(data.starts(with: Data([0x50, 0x4B, 0x03, 0x04])))
        let packageListing = try unzip(arguments: ["-l", outputURL.path])
        let documentXML = try unzip(arguments: ["-p", outputURL.path, "word/document.xml"])
        let relationshipsXML = try unzip(
            arguments: ["-p", outputURL.path, "word/_rels/document.xml.rels"]
        )
        XCTAssertTrue(packageListing.contains("word/media/markdown-printer-image-1.png"))
        XCTAssertTrue(documentXML.contains("<w:drawing>"))
        XCTAssertTrue(documentXML.contains("cx=\"1524000\" cy=\"762000\""))
        XCTAssertTrue(documentXML.contains("<w:tbl>"))
        XCTAssertTrue(documentXML.contains("<w:b"))
        XCTAssertTrue(documentXML.contains("<w:i"))
        XCTAssertTrue(documentXML.contains("<w:u"))
        XCTAssertTrue(documentXML.contains("<w:hyperlink"))
        XCTAssertTrue(relationshipsXML.contains("relationships/image"))
        XCTAssertTrue(relationshipsXML.contains("https://example.com"))
        XCTAssertFalse(documentXML.contains("MDPRINTERIMAGE"))
        let decoded = try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        )
        XCTAssertTrue(decoded.string.contains("Quarterly Résumé"))
        XCTAssertTrue(decoded.string.contains("Text with bold, italic, underline, code, and a link."))
        XCTAssertTrue(decoded.string.contains("First item"))
        XCTAssertTrue(decoded.string.contains("Name"))
        XCTAssertTrue(decoded.string.contains("42"))
        XCTAssertTrue(decoded.string.contains("[Image: Offline]"))
    }

    func testWordExporterWritesEmptyAndNonemptyDocuments() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let emptyURL = directory.appendingPathComponent("Empty.docx")
        let textURL = directory.appendingPathComponent("Text.docx")
        let exporter = WordExporter()

        try exporter.write(NSAttributedString(string: ""), to: emptyURL)
        try exporter.write(NSAttributedString(string: "Editable"), to: textURL)

        XCTAssertTrue(try Data(contentsOf: emptyURL).starts(with: Data([0x50, 0x4B])))
        let decoded = try NSAttributedString(
            url: textURL,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil
        )
        XCTAssertEqual(decoded.string.trimmingCharacters(in: .newlines), "Editable")
    }

    func testWordExporterReportsImageAndPackagingFailuresReadably() throws {
        let missingImage = NSTextAttachment()
        XCTAssertThrowsError(try WordExporter().wordData(from: NSAttributedString(attachment: missingImage))) {
            XCTAssertEqual($0 as? WordExporterError, .imageEncodingFailed)
            XCTAssertEqual(
                $0.localizedDescription,
                "An embedded image could not be prepared for Microsoft Word."
            )
        }

        let image = NSImage(data: Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!)!
        let attachment = NSTextAttachment()
        attachment.image = image
        XCTAssertThrowsError(try WordExporter(
            unzipURL: URL(fileURLWithPath: "/missing/unzip")
        ).wordData(from: NSAttributedString(attachment: attachment))) {
            XCTAssertEqual($0 as? WordExporterError, .packagingFailed)
            XCTAssertEqual(
                $0.localizedDescription,
                "The Microsoft Word document could not be packaged."
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 120, height: 60))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 60)).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }

    private func unzip(arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }
}

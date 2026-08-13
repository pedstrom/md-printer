import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class PDFExporterTests: XCTestCase {
    func testGeneratesLetterPDFWithSearchableAvenirText() throws {
        let renderer = MarkdownRenderer()
        let data = try PDFExporter().pdfData(from: renderer.render(markdown: "# Report\n\nHello **world**."))
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 0.5)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 792, accuracy: 0.5)
        XCTAssertTrue(page.string?.contains("Report") == true)
        XCTAssertTrue(page.string?.contains("Hello world") == true)
        let headingSelection = try XCTUnwrap(document.findString("Report", withOptions: []).first)
        XCTAssertGreaterThan(headingSelection.bounds(for: page).midY, 600, "The first heading should render upright near the top margin.")
    }

    func testLongDocumentPaginates() throws {
        let markdown = (1...180).map { "Paragraph \($0): Enough text to occupy a line in the rendered document." }.joined(separator: "\n\n")
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 2)
        XCTAssertTrue(document.page(at: document.pageCount - 1)?.string?.contains("Paragraph 180") == true)
    }

    func testEveryHeadingLevelMovesWithTwoFollowingLines() throws {
        for level in 1...6 {
            let heading = "Boundary heading \(level)"
            let firstLine = "Level \(level) first following line."
            let secondLine = "Level \(level) second following line."
            let payload = """
            \(String(repeating: "#", count: level)) \(heading)

            \(firstLine)

            \(secondLine)
            """
            let markdown = try XCTUnwrap(naturalBoundaryMarkdown(
                payload: payload,
                heading: heading
            ) { pageText in
                pageText.contains("Filler")
                    && [firstLine, secondLine].filter(pageText.contains).count < 2
            })

            let document = try protectedDocument(markdown: markdown)
            let headingPage = try page(containing: heading, in: document)
            let pageText = headingPage.string ?? ""
            XCTAssertTrue(pageText.contains(firstLine), "H\(level) did not stay with its first line.")
            XCTAssertTrue(pageText.contains(secondLine), "H\(level) did not stay with its second line.")
        }
    }

    func testHeadingUsesAvailableContentWithoutAddingFutilePages() throws {
        let endingHeading = "Heading at document end"
        let endingMarkdown = try XCTUnwrap(naturalBoundaryMarkdown(
            payload: "## \(endingHeading)",
            heading: endingHeading,
            matches: { $0.contains("Filler") }
        ))
        let naturalEnding = try naturalDocument(markdown: endingMarkdown)
        let protectedEnding = try protectedDocument(markdown: endingMarkdown)
        XCTAssertEqual(protectedEnding.pageCount, naturalEnding.pageCount)
        XCTAssertEqual(
            try pageIndex(containing: endingHeading, in: protectedEnding),
            try pageIndex(containing: endingHeading, in: naturalEnding)
        )

        let singleHeading = "Single-line section"
        let onlyLine = "The only available following line."
        let singleMarkdown = try XCTUnwrap(naturalBoundaryMarkdown(
            payload: "## \(singleHeading)\n\n\(onlyLine)",
            heading: singleHeading
        ) { !$0.contains(onlyLine) })
        let protectedSingle = try protectedDocument(markdown: singleMarkdown)
        XCTAssertTrue(try page(containing: singleHeading, in: protectedSingle).string?.contains(onlyLine) == true)
    }

    func testWrappedConsecutiveHeadingsMoveAsOneGroup() throws {
        let parent = "Parent boundary heading"
        let child = "A deliberately long child heading that wraps across multiple rendered lines near the page boundary"
        let childNeedle = "A deliberately long child heading"
        let firstLine = "Grouped first following line."
        let secondLine = "Grouped second following line."
        let payload = """
        ## \(parent)
        ### \(child)

        \(firstLine)

        \(secondLine)
        """
        let markdown = try XCTUnwrap(naturalBoundaryMarkdown(
            payload: payload,
            heading: childNeedle
        ) { pageText in
            pageText.contains(parent)
                && [firstLine, secondLine].filter(pageText.contains).count < 2
        })

        let document = try protectedDocument(markdown: markdown)
        let pageText = try page(containing: childNeedle, in: document).string ?? ""
        XCTAssertTrue(pageText.contains(parent))
        XCTAssertTrue(pageText.contains(firstLine))
        XCTAssertTrue(pageText.contains(secondLine))
    }

    func testHeadingsStayWithParagraphListQuoteCodeAndImageContent() throws {
        let contentCases: [(name: String, markdown: String, markers: [String])] = [
            ("paragraph", "Paragraph first row.\n\nParagraph second row.", ["Paragraph first row.", "Paragraph second row."]),
            ("list", "- List first row.\n- List second row.", ["List first row.", "List second row."]),
            ("quotation", "> Quote first row.\n> Quote second row.", ["Quote first row.", "Quote second row."]),
            ("code", "```\ncode-first-row\ncode-second-row\n```", ["code-first-row", "code-second-row"])
        ]

        for contentCase in contentCases {
            let heading = "\(contentCase.name) boundary"
            let payload = "## \(heading)\n\n\(contentCase.markdown)"
            let markdown = try XCTUnwrap(naturalBoundaryMarkdown(
                payload: payload,
                heading: heading
            ) { pageText in
                contentCase.markers.filter(pageText.contains).count < 2
            })
            let pageText = try page(
                containing: heading,
                in: protectedDocument(markdown: markdown)
            ).string ?? ""
            for marker in contentCase.markers {
                XCTAssertTrue(pageText.contains(marker), "Missing \(contentCase.name) marker \(marker)")
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("boundary.png")
        try makePNG(size: NSSize(width: 120, height: 20)).write(to: imageURL)
        let imageHeading = "image boundary"
        let afterImage = "Text after the image row."
        let imagePayload = "## \(imageHeading)\n\n![Boundary](boundary.png)\n\n\(afterImage)"
        let imageMarkdown = try XCTUnwrap(naturalBoundaryMarkdown(
            payload: imagePayload,
            heading: imageHeading,
            baseURL: directory,
            matches: { !$0.contains(afterImage) }
        ))
        let imagePage = try page(
            containing: imageHeading,
            in: protectedDocument(markdown: imageMarkdown, baseURL: directory)
        )
        XCTAssertTrue(imagePage.string?.contains(afterImage) == true)
    }

    func testTableCellsSharingARowCountAsOneFollowingLine() throws {
        let heading = "table boundary"
        let payload = """
        ## \(heading)

        | Left header | Right header |
        | --- | --- |
        | First data row | Second data row |
        """
        let markdown = try XCTUnwrap(naturalBoundaryMarkdown(
            payload: payload,
            heading: heading
        ) { pageText in
            pageText.contains("Left header")
                && pageText.contains("Right header")
                && !pageText.contains("First data row")
        })

        let pageText = try page(
            containing: heading,
            in: protectedDocument(markdown: markdown)
        ).string ?? ""
        XCTAssertTrue(pageText.contains("Left header"))
        XCTAssertTrue(pageText.contains("Right header"))
        XCTAssertTrue(pageText.contains("First data row"))
        XCTAssertTrue(pageText.contains("Second data row"))
    }

    func testEveryPageHasASequentialCenteredFooterNumber() throws {
        let markdown = Array(
            repeating: "A paragraph without digits that occupies space in the rendered document.",
            count: 180
        ).joined(separator: "\n\n")
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 2)

        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let pageNumber = String(pageIndex + 1)
            XCTAssertEqual(page.string?.split(whereSeparator: \.isWhitespace).last.map(String.init), pageNumber)
            let selection = try XCTUnwrap(
                document.findString(pageNumber, withOptions: []).first(where: { $0.pages.contains(page) })
            )
            let bounds = selection.bounds(for: page)
            XCTAssertEqual(bounds.midX, page.bounds(for: .mediaBox).midX, accuracy: 1)
            XCTAssertLessThan(bounds.maxY, 54)
        }
    }

    func testLongTablePaginatesAndStaysSearchable() throws {
        let rows = (1...70).map { "| Row \($0) | Value \($0) |" }.joined(separator: "\n")
        let markdown = "| Name | Value |\n| --- | ---: |\n" + rows
        let data = try PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 1)
        let allText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        XCTAssertTrue(allText.contains("Row 1"))
        XCTAssertTrue(allText.contains("Row 70"))
    }

    func testPDFPreservesLinkAnnotation() throws {
        let text = MarkdownRenderer().render(markdown: "[OpenAI](https://openai.com)")
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        let annotations = try XCTUnwrap(document.page(at: 0)).annotations
        XCTAssertTrue(annotations.contains(where: { $0.url?.absoluteString == "https://openai.com" }))
    }

    func testPDFPreservesResolvedLocalMarkdownLinkAnnotation() throws {
        let baseURL = URL(fileURLWithPath: "/tmp/reports/deeper-research", isDirectory: true)
        let expectedURL = try XCTUnwrap(
            URL(string: "../overview.md#details", relativeTo: baseURL)?.absoluteURL
        )
        let text = MarkdownRenderer().render(
            markdown: "[Project overview](../overview.md#details)",
            baseURL: baseURL
        )
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        let annotations = try XCTUnwrap(document.page(at: 0)).annotations

        XCTAssertTrue(annotations.contains(where: { $0.url == expectedURL }))
    }

    func testPDFFootnoteReferencesAndDefinitionsLinkInBothDirections() throws {
        let filler = (1...80)
            .map { "Filler paragraph \($0) keeps the notes after the body." }
            .joined(separator: "\n\n")
        let markdown = """
        First claim[^source] and repeated[^source].

        \(filler)

        [^source]: Supporting footnote text.
        """
        let text = MarkdownRenderer().render(markdown: markdown)
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        XCTAssertGreaterThan(document.pageCount, 1)

        var links: [(pageIndex: Int, action: PDFActionGoTo)] = []
        for pageIndex in 0..<document.pageCount {
            for annotation in try XCTUnwrap(document.page(at: pageIndex)).annotations {
                if let action = annotation.action as? PDFActionGoTo {
                    links.append((pageIndex, action))
                }
            }
        }

        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links.filter { $0.pageIndex == 0 }.count, 2)
        XCTAssertEqual(links.filter { $0.pageIndex == document.pageCount - 1 }.count, 1)
        XCTAssertTrue(links.filter { $0.pageIndex == 0 }.allSatisfy {
            $0.action.destination.page.map(document.index(for:)) == document.pageCount - 1
        })
        let backLink = try XCTUnwrap(links.first { $0.pageIndex == document.pageCount - 1 })
        XCTAssertEqual(
            document.index(for: try XCTUnwrap(backLink.action.destination.page)),
            0
        )

        let allText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
        XCTAssertFalse(allText.contains("[^source]"))
        XCTAssertTrue(allText.contains("Supporting footnote text."))
    }

    func testFencedCodeBlockRendersWithoutStallingPagination() throws {
        let text = MarkdownRenderer().render(markdown: "```swift\nlet answer = 42\nprint(answer)\n```")
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("let answer = 42") == true)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("print(answer)") == true)
    }

    func testWrappedQuotationRendersAndRemainsSearchable() throws {
        let markdown = "> A quoted passage long enough to wrap onto another visible line while retaining one continuous left border."
        let text = MarkdownRenderer().render(markdown: markdown)
        let document = try XCTUnwrap(PDFDocument(data: try PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 1)
        let extractedText = try XCTUnwrap(document.page(at: 0)?.string)
        let normalizedText = extractedText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertTrue(normalizedText.contains("A quoted passage"))
        XCTAssertTrue(normalizedText.contains("continuous"))
        XCTAssertTrue(normalizedText.contains("left border"), "Extracted quotation: \(extractedText)")
    }

    func testWriteAndPrintExistingPDF() throws {
        let exporter = PDFExporter()
        let text = MarkdownRenderer().render(markdown: "Printable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.pdf")
        try exporter.write(text, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(PDFDocument(data: data))
        let operation = try exporter.printOperation(forPDFData: data)
        XCTAssertNotNil(operation.view)
        XCTAssertEqual(operation.printInfo.paperSize.width, 612, accuracy: 0.5)
        XCTAssertEqual(operation.printInfo.paperSize.height, 792, accuracy: 0.5)
        XCTAssertEqual(operation.printInfo.topMargin, 0)
        XCTAssertEqual(operation.printInfo.leftMargin, 0)
        XCTAssertEqual(operation.printInfo.bottomMargin, 0)
        XCTAssertEqual(operation.printInfo.rightMargin, 0)
        XCTAssertThrowsError(try exporter.printOperation(forPDFData: Data([0x00])))
    }

    func testPrintToPDFPreservesPreviewPageAndContentPosition() throws {
        let exporter = PDFExporter()
        let paragraphs = (1...90)
            .map { "Paragraph \($0): Printing must preserve every generated page without adding another layout pass." }
            .joined(separator: "\n\n")
        let previewData = try exporter.pdfData(
            from: MarkdownRenderer().render(markdown: "# Print fidelity\n\n\(paragraphs)")
        )
        let previewDocument = try XCTUnwrap(PDFDocument(data: previewData))
        XCTAssertGreaterThan(previewDocument.pageCount, 1)
        let previewPage = try XCTUnwrap(previewDocument.page(at: 0))
        let previewHeading = try XCTUnwrap(previewDocument.findString("Print fidelity", withOptions: []).first)
            .bounds(for: previewPage)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let printedURL = directory.appendingPathComponent("printed.pdf")

        let operation = try exporter.printOperation(forPDFData: previewData)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = printedURL
        XCTAssertTrue(operation.run())

        let printedDocument = try XCTUnwrap(PDFDocument(url: printedURL))
        XCTAssertEqual(printedDocument.pageCount, previewDocument.pageCount)
        let printedPage = try XCTUnwrap(printedDocument.page(at: 0))
        let printedHeading = try XCTUnwrap(printedDocument.findString("Print fidelity", withOptions: []).first)
            .bounds(for: printedPage)

        XCTAssertEqual(printedPage.bounds(for: .mediaBox).width, previewPage.bounds(for: .mediaBox).width, accuracy: 0.5)
        XCTAssertEqual(printedPage.bounds(for: .mediaBox).height, previewPage.bounds(for: .mediaBox).height, accuracy: 0.5)
        XCTAssertEqual(printedHeading.minX, previewHeading.minX, accuracy: 0.5)
        XCTAssertEqual(printedHeading.maxY, previewHeading.maxY, accuracy: 0.5)
        XCTAssertTrue(printedDocument.page(at: printedDocument.pageCount - 1)?.string?.contains("Paragraph 90") == true)
    }

    func testEmptyAttributedStringStillCreatesOnePage() throws {
        let data = try PDFExporter().pdfData(from: NSAttributedString(string: ""))
        XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
    }

    private func naturalBoundaryMarkdown(
        payload: String,
        heading: String,
        baseURL: URL? = nil,
        matches: (String) -> Bool
    ) throws -> String? {
        for fillerCount in 1...80 {
            let filler = (1...fillerCount)
                .map { "Filler line \($0)." }
                .joined(separator: "\n")
            let markdown = "\(filler)\n\n\(payload)"
            let document = try naturalDocument(markdown: markdown, baseURL: baseURL)
            let pageText = try page(containing: heading, in: document).string ?? ""
            if matches(pageText) { return markdown }
        }
        return nil
    }

    private func protectedDocument(markdown: String, baseURL: URL? = nil) throws -> PDFDocument {
        let text = MarkdownRenderer().render(markdown: markdown, baseURL: baseURL)
        return try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
    }

    private func naturalDocument(markdown: String, baseURL: URL? = nil) throws -> PDFDocument {
        let text = NSMutableAttributedString(
            attributedString: MarkdownRenderer().render(markdown: markdown, baseURL: baseURL)
        )
        text.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: text.length)
        ) { value, range, _ in
            guard let paragraph = value as? NSParagraphStyle,
                  paragraph.headerLevel > 0,
                  let unmarked = paragraph.mutableCopy() as? NSMutableParagraphStyle else {
                return
            }
            unmarked.headerLevel = 0
            text.addAttribute(.paragraphStyle, value: unmarked, range: range)
        }
        return try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
    }

    private func page(containing text: String, in document: PDFDocument) throws -> PDFPage {
        try XCTUnwrap(document.page(at: pageIndex(containing: text, in: document)))
    }

    private func pageIndex(containing text: String, in document: PDFDocument) throws -> Int {
        try XCTUnwrap((0..<document.pageCount).first(where: {
            document.page(at: $0)?.string?.contains(text) == true
        }))
    }

    private func makePNG(size: NSSize) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    }
}

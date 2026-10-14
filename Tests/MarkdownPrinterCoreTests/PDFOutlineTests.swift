import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class PDFOutlineTests: XCTestCase {
    func testAllHeadingLevelsNestInSourceOrderWithSiblingsAndSkippedLevels() throws {
        let markdown = """
        ## Opening without H1
        #### Skipped level
        ### Back to H3
        # Report
        ## Second
        ### Third
        #### Fourth
        ##### Fifth
        ###### Sixth
        ## Sibling
        # Next report
        """
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))))
        let root = try XCTUnwrap(pdf.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 3)
        let opening = try entry(root, at: 0, title: "Opening without H1", children: 2)
        _ = try entry(opening, at: 0, title: "Skipped level")
        _ = try entry(opening, at: 1, title: "Back to H3")
        let report = try entry(root, at: 1, title: "Report", children: 2)
        let second = try entry(report, at: 0, title: "Second", children: 1)
        let third = try entry(second, at: 0, title: "Third", children: 1)
        let fourth = try entry(third, at: 0, title: "Fourth", children: 1)
        let fifth = try entry(fourth, at: 0, title: "Fifth", children: 1)
        _ = try entry(fifth, at: 0, title: "Sixth")
        _ = try entry(report, at: 1, title: "Sibling")
        _ = try entry(root, at: 2, title: "Next report")
    }

    func testOutlineTitlesUseReadableHeadingTextAndIncludeQuoteAndListHeadings() throws {
        let markdown = """
        **Résumé[^source]** &amp; [Café](https://example.com) `code` ![Map](missing-map.png)
        ======================================================================

        > ## Quoted *heading*
        >
        > Body.

        - ### Listed <u>heading</u>
          Body.

        ## Sibling ~~heading~~

        [^source]: The reference stays available in the PDF.
        """
        let text = MarkdownRenderer().render(markdown: markdown)
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        let root = try XCTUnwrap(pdf.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 1)
        let report = try entry(root, at: 0, title: "Résumé & Café code Map", children: 2)
        let quoted = try entry(report, at: 0, title: "Quoted heading", children: 1)
        _ = try entry(quoted, at: 0, title: "Listed heading")
        _ = try entry(report, at: 1, title: "Sibling heading")
    }

    func testSavedSyncAndAsyncOutlinesTargetTheSamePaginatedHeadingsAsSectionLinks() async throws {
        let filler = String(repeating: "A paragraph that occupies space on the printed pages.\n\n", count: 70)
        let markdown = "# Report\n\n[Jump forward](#repeated-1) [Website](https://example.com)\n\n"
            + filler + "## Repeated\n\n" + filler + "## Repeated\n\n[Back](#report)\n\n"
        let text = MarkdownRenderer().render(markdown: markdown)
        let exporter = PDFExporter()
        let synchronous = try exporter.render(from: text)
        let asynchronous = try await exporter.renderAsync(from: text)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedURL = directory.appendingPathComponent("outline.pdf")
        try exporter.write(text, to: savedURL)
        let saved = try XCTUnwrap(PDFDocument(url: savedURL))

        for pdf in [try XCTUnwrap(PDFDocument(data: synchronous.data)),
                    try XCTUnwrap(PDFDocument(data: asynchronous.data)), saved] {
            XCTAssertGreaterThan(pdf.pageCount, 2)
            let root = try XCTUnwrap(pdf.outlineRoot)
            XCTAssertEqual(root.numberOfChildren, 1)
            let report = try entry(root, at: 0, title: "Report", children: 2)
            let first = try entry(report, at: 0, title: "Repeated")
            let second = try entry(report, at: 1, title: "Repeated")
            for (outline, anchor) in [(report, "report"), (first, "repeated"), (second, "repeated-1")] {
                let expected = try XCTUnwrap(synchronous.sectionDestinations[anchor])
                let destination = try XCTUnwrap(outline.destination)
                XCTAssertEqual(pdf.index(for: try XCTUnwrap(destination.page)), expected.pageIndex)
                XCTAssertEqual(destination.point.x, expected.point.x, accuracy: 0.1)
                XCTAssertEqual(destination.point.y, expected.point.y, accuracy: 0.1)
                XCTAssertEqual(destination.zoom, kPDFDestinationUnspecifiedValue, "Outline navigation should retain the viewer's zoom.")
            }
            let annotations = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }
            let links = annotations.compactMap { $0.action as? PDFActionGoTo }
            XCTAssertEqual(links.count, 2)
            XCTAssertTrue(annotations.contains { $0.url?.absoluteString == "https://example.com" })
            let forward = try XCTUnwrap(links.first?.destination)
            XCTAssertEqual(forward.page, second.destination?.page)
            XCTAssertEqual(forward.point.y, second.destination!.point.y, accuracy: 0.1)
            XCTAssertTrue(pdf.string?.contains("A paragraph that occupies space") == true)
        }
        XCTAssertEqual(synchronous.sectionDestinations, asynchronous.sectionDestinations)
    }

    func testDocumentsWithoutNamedHeadingsHaveNoOutline() throws {
        for markdown in ["", "An ordinary paragraph.\n\n```\n# Code is not a heading\n```", "#\n\nBody."] {
            let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: markdown))))
            XCTAssertNil(pdf.outlineRoot)
            XCTAssertEqual(pdf.pageCount, 1)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: MarkdownRenderer().render(markdown: "#\n## Named child"))))
        let root = try XCTUnwrap(pdf.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 1)
        _ = try entry(root, at: 0, title: "Named child")
    }

    private func entry(_ parent: PDFOutline, at index: Int, title: String, children: Int = 0,
                       file: StaticString = #filePath, line: UInt = #line) throws -> PDFOutline {
        let child = try XCTUnwrap(parent.child(at: index), file: file, line: line)
        XCTAssertEqual(child.label, title, file: file, line: line)
        XCTAssertEqual(child.numberOfChildren, children, file: file, line: line)
        XCTAssertNotNil(child.destination?.page, file: file, line: line)
        return child
    }
}

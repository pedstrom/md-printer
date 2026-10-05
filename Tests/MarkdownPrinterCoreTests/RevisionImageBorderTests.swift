import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionImageBorderTests: XCTestCase {
    func testStandaloneImageBorderMatchesActualImagePixels() throws {
        try assertBorderInsideImage(markdown: "# Image\n\nBefore the image.\n\n![Diagram](current.png)\n\nAfter the image.", name: "standalone")
    }

    func testLinkedInlineImageBorderMatchesActualImagePixels() throws {
        try assertBorderInsideImage(markdown: "Text before [![Diagram](current.png)](https://example.com/image) text after.", name: "linked")
    }

    func testTableImageBorderMatchesActualImagePixels() throws {
        try assertBorderInsideImage(markdown: "| Image | Status |\n| :---: | --- |\n| ![Diagram](current.png) | Unchanged |", name: "table")
    }

    private func assertBorderInsideImage(markdown: String, name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RevisionImageBorder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 160, height: 80))
        image.lockFocus()
        NSColor(calibratedRed: 0, green: 0.4, blue: 1, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("current.png"))
        let current = MarkdownDocument(sourceURL: directory.appendingPathComponent("current.md"), title: "Image", markdown: markdown)
        let original = MarkdownDocument(title: "Old", markdown: markdown.replacingOccurrences(of: "current.png", with: "older.png"))
        let renderer = MarkdownRenderer()
        let revision = renderer.render(document: current, original: original)
        XCTAssertEqual(revision.decorations.images.count, 1)
        XCTAssertTrue(revision.decorations.highlights.isEmpty)
        let plainData = try PDFExporter().pdfData(from: renderer.render(document: current))
        let markedData = try PDFExporter().pdfData(from: revision.text, decorations: revision.decorations)
        let plain = try XCTUnwrap(PDFDocument(data: plainData)), marked = try XCTUnwrap(PDFDocument(data: markedData))
        XCTAssertEqual(plain.pageCount, 1)
        XCTAssertEqual(marked.pageCount, plain.pageCount)
        XCTAssertEqual(marked.string, plain.string)
        let pageSize = try XCTUnwrap(plain.page(at: 0)).bounds(for: .mediaBox).size
        let plainPixels = try pixels(of: plain, pageSize: pageSize)
        let markedPixels = try pixels(of: marked, pageSize: pageSize)
        XCTAssertEqual(markedPixels.pixelsWide, plainPixels.pixelsWide)
        XCTAssertEqual(markedPixels.pixelsHigh, plainPixels.pixelsHigh)
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_IMAGE_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try plainData.write(to: output.appendingPathComponent(name + "-plain.pdf"))
            try markedData.write(to: output.appendingPathComponent(name + "-marked.pdf"))
            try XCTUnwrap(plainPixels.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + "-plain.png"))
            try XCTUnwrap(markedPixels.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + "-marked.png"))
        }
        let blue = try XCTUnwrap(bounds(in: plainPixels) { color in
            color.blueComponent > 0.7 && color.blueComponent > color.redComponent + 0.4
                && color.blueComponent > color.greenComponent + 0.25
        })
        let yellow = try XCTUnwrap(bounds(in: markedPixels) { color in
            color.redComponent > 0.75 && color.greenComponent > 0.5 && color.blueComponent < 0.35
        })
        // Use the unmarked PDF's actual pixels as the boundary. Attachment
        // metadata may describe a baseline offset that TextKit does not draw.
        XCTAssertTrue(blue.insetBy(dx: -1, dy: -1).contains(yellow), "\(name) border \(yellow) escaped rendered image \(blue)")
        XCTAssertEqual(yellow.minX, blue.minX, accuracy: 1)
        XCTAssertEqual(yellow.maxX, blue.maxX, accuracy: 1)
        XCTAssertEqual(yellow.minY, blue.minY, accuracy: 1)
        XCTAssertEqual(yellow.maxY, blue.maxY, accuracy: 1)
        let scale = CGFloat(markedPixels.pixelsWide) / pageSize.width
        let middleY = Int(blue.midY)
        var strokePixels = 0
        for x in Int(blue.minX)..<Int(blue.maxX) {
            let color = try XCTUnwrap(markedPixels.colorAt(x: x, y: middleY)?.usingColorSpace(.deviceRGB))
            // Include antialiased edge pixels blended with the blue image.
            if color.redComponent > 0.5 && color.greenComponent > 0.5 && color.blueComponent < 0.6 { strokePixels += 1 }
        }
        XCTAssertEqual(CGFloat(strokePixels) / scale, 4, accuracy: 1, "Both vertical edges should be two-point strokes")

    }

    private func pixels(of document: PDFDocument, pageSize: CGSize) throws -> NSBitmapImageRep {
        let thumbnail = try XCTUnwrap(document.page(at: 0)).thumbnail(of: pageSize, for: .mediaBox)
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(thumbnail.tiffRepresentation)))
    }

    private func bounds(in pixels: NSBitmapImageRep, matching predicate: (NSColor) -> Bool) -> CGRect? {
        var minX = pixels.pixelsWide, minY = pixels.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<pixels.pixelsHigh {
            for x in 0..<pixels.pixelsWide {
                guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

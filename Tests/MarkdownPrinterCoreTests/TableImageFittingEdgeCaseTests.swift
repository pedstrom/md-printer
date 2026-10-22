import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class TableImageFittingEdgeCaseTests: XCTestCase {
    func testUnequalAspectRatiosRemainVisibleAndUndistortedInTheirColumns() throws {
        let directory = try temporaryDirectory()
        try writeImage(size: NSSize(width: 400, height: 2000), tint: .blue, name: "portrait.png", in: directory)
        try writeImage(size: NSSize(width: 1200, height: 600), tint: .red, name: "landscape.png", in: directory)
        let text = MarkdownRenderer().render(markdown: """
        | Image | Image |
        | --- | --- |
        | ![Image](portrait.png) | ![Image](landscape.png) |
        | Caption | Caption |
        """, baseURL: directory)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 1)
        let regions = try imageRegions(on: XCTUnwrap(document.page(at: 0)))
        let portrait = try XCTUnwrap(regions[.blue])
        let landscape = try XCTUnwrap(regions[.red])
        XCTAssertGreaterThan(portrait.height, 200)
        XCTAssertGreaterThan(landscape.width, 100)
        XCTAssertEqual(portrait.width / portrait.height, 0.2, accuracy: 0.02)
        XCTAssertEqual(landscape.width / landscape.height, 2, accuracy: 0.04)
        XCTAssertLessThan(portrait.maxX, 306)
        XCTAssertGreaterThanOrEqual(landscape.minX, 306)
    }

    func testPDFFittingPreservesSmallImagesAndExplicitWidthLimits() throws {
        let directory = try temporaryDirectory()
        try writeImage(size: NSSize(width: 20, height: 10), tint: .red, name: "small.png", in: directory)
        try writeImage(size: NSSize(width: 1000, height: 500), tint: .green, name: "requested.png", in: directory)
        try writeImage(size: NSSize(width: 1000, height: 500), tint: .blue, name: "configured.png", in: directory)
        let configuration = RendererConfiguration(maximumImageWidth: 80)
        let text = MarkdownRenderer(configuration: configuration).render(markdown: """
        | Small | Requested | Configured |
        | --- | --- | --- |
        | ![Small](small.png) | <img src='requested.png' width='30'> | ![Configured](configured.png) |
        """, baseURL: directory)
        let original = attachmentSizes(in: text)
        XCTAssertEqual(original, [NSSize(width: 20, height: 10), NSSize(width: 30, height: 15), NSSize(width: 80, height: 40)])
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter(configuration: configuration).pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 1)
        let regions = try imageRegions(on: XCTUnwrap(document.page(at: 0)))
        for (tint, expected) in [(Tint.red, original[0]), (.green, original[1]), (.blue, original[2])] {
            let bounds = try XCTUnwrap(regions[tint])
            XCTAssertEqual(bounds.width, expected.width, accuracy: 2)
            XCTAssertEqual(bounds.height, expected.height, accuracy: 2)
        }
        XCTAssertEqual(attachmentSizes(in: text), original)
    }

    func testSeveralImagesInOneCellRemainCompleteAfterMovingPastAPageBoundary() throws {
        let directory = try temporaryDirectory()
        for tint in Tint.allCases {
            try writeImage(size: NSSize(width: 800, height: 1000), tint: tint, name: "\(tint).png", in: directory)
        }
        let introduction = Array(repeating: "A short paragraph before the comparison.", count: 12).joined(separator: "\n\n")
        let text = MarkdownRenderer().render(markdown: """
        \(introduction)

        | Image | Image |
        | --- | --- |
        | ![Image](blue.png) ![Image](red.png) | ![Image](green.png) |
        | Final caption | Final caption |
        """, baseURL: directory)
        let original = attachmentSizes(in: text)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertGreaterThan(document.pageCount, 1)
        let caption = try XCTUnwrap(document.findString("Final caption", withOptions: []).first)
        let page = try XCTUnwrap(caption.pages.first)
        let regions = try imageRegions(on: page)
        for tint in Tint.allCases {
            let bounds = try XCTUnwrap(regions[tint], "Every image must remain on the caption's page")
            XCTAssertGreaterThan(bounds.width, 100)
            XCTAssertEqual(bounds.width / bounds.height, 0.8, accuracy: 0.02)
        }
        XCTAssertLessThan(try XCTUnwrap(regions[.blue]).maxX, 306)
        XCTAssertLessThan(try XCTUnwrap(regions[.red]).maxX, 306)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(regions[.green]).minX, 306)
        XCTAssertEqual(attachmentSizes(in: text), original)
    }

    func testFreshPageHeightFitReservesWrappedTextInsideTheImageCell() throws {
        let directory = try temporaryDirectory()
        try writeImage(size: NSSize(width: 400, height: 2000), tint: .blue, name: "portrait.png", in: directory)
        let note = Array(repeating: "A detailed note about this screenshot.", count: 15).joined(separator: " ")
        let text = MarkdownRenderer().render(markdown: """
        | Image | Image |
        | --- | --- |
        | \(note) ![Image](portrait.png) | \(note) ![Image](portrait.png) |
        | Final caption | Final caption |
        """, baseURL: directory)
        let original = attachmentSizes(in: text)
        let document = try XCTUnwrap(PDFDocument(data: PDFExporter().pdfData(from: text)))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(page.string?.contains("Final caption") == true)
        let blue = try XCTUnwrap(imageRegions(on: page)[.blue])
        XCTAssertGreaterThan(blue.width, 300, "Both portrait columns must remain visible")
        XCTAssertGreaterThan(blue.height, 200)
        XCTAssertEqual(attachmentSizes(in: text), original)
    }

    private enum Tint: CaseIterable {
        case red, green, blue

        var color: NSColor {
            switch self {
            case .red: return NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            case .green: return NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
            case .blue: return NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeImage(size: NSSize, tint: Tint, name: String, in directory: URL) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        tint.color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }

    private func attachmentSizes(in text: NSAttributedString) -> [NSSize] {
        var sizes: [NSSize] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { sizes.append(attachment.bounds.size) }
        }
        return sizes
    }

    private func imageRegions(on page: PDFPage) throws -> [Tint: CGRect] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox).tiffRepresentation)))
        var regions: [Tint: CGRect] = [:]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let tint: Tint
                if color.redComponent > 0.5,
                   color.redComponent > color.greenComponent + 0.3,
                   color.redComponent > color.blueComponent + 0.3 { tint = .red }
                else if color.greenComponent > 0.5,
                        color.greenComponent > color.redComponent + 0.3,
                        color.greenComponent > color.blueComponent + 0.3 { tint = .green }
                else if color.blueComponent > 0.5,
                        color.blueComponent > color.redComponent + 0.3,
                        color.blueComponent > color.greenComponent + 0.3 { tint = .blue }
                else { continue }
                let pixel = CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
                regions[tint] = regions[tint].map { $0.union(pixel) } ?? pixel
            }
        }
        for bounds in regions.values {
            XCTAssertGreaterThanOrEqual(bounds.minX, 54)
            XCTAssertLessThanOrEqual(bounds.maxX, 558)
            XCTAssertGreaterThanOrEqual(bounds.minY, 54)
            XCTAssertLessThanOrEqual(bounds.maxY, 738, "Images must remain above the footer")
        }
        return regions
    }
}

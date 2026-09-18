import AppKit
import XCTest
@testable import MarkdownPrinterCore
import MarkdownPrinterQuickLookSupport

final class HeadingTypographyTests: XCTestCase {
    private let sizes: [CGFloat] = [26, 20, 16, 13, 11, 10]
    private let names = ["AvenirNext-Bold", "AvenirNext-Bold", "AvenirNext-DemiBold",
                         "AvenirNext-DemiBold", "AvenirNext-DemiBold", "AvenirNext-DemiBoldItalic"]

    func testEveryHeadingHasDistinctTypographyAndDeliberateTotalSpacing() throws {
        for level in 1...6 {
            let source = "Body before.\n\n\(String(repeating: "#", count: level)) Heading\n\nBody after."
            let rendered = MarkdownRenderer().render(markdown: source)
            XCTAssertEqual(rendered.string, "Body before.\nHeading\nBody after.\n")
            let range = (rendered.string as NSString).range(of: "Heading")
            let font = try XCTUnwrap(rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(font.pointSize, sizes[level - 1])
            XCTAssertEqual(font.fontName, names[level - 1])
            XCTAssertEqual(paragraph.headerLevel, level)
            XCTAssertEqual(paragraph.paragraphSpacingBefore + 8, [24, 18, 14, 11, 9, 8][level - 1])
            XCTAssertEqual(paragraph.paragraphSpacing, [8, 6, 5, 4, 3, 3][level - 1])
            XCTAssertLessThan(paragraph.paragraphSpacing, paragraph.paragraphSpacingBefore + 8)
        }
    }

    func testLeadingConsecutiveAndScaledHeadingsAvoidExtraBlankLines() throws {
        let configuration = RendererConfiguration().applying(DocumentPageSetup(
            paperName: "na-letter", paperSize: CGSize(width: 612, height: 792),
            orientation: .portrait, scale: 1.25
        ))
        let rendered = MarkdownRenderer(configuration: configuration).render(markdown: "# First\n## Second\n###### Last\n\nBody")
        XCTAssertEqual(rendered.string, "First\nSecond\nLast\nBody\n")
        let first = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(first.paragraphSpacingBefore, 0)
        let secondIndex = (rendered.string as NSString).range(of: "Second").location
        let second = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: secondIndex, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(second.paragraphSpacingBefore + first.paragraphSpacing, 18 * 1.25)
        XCTAssertEqual(second.paragraphSpacing, 6 * 1.25)
    }

    @MainActor
    func testQuickLookUsesTheSameWeightsAtScreenSizes() throws {
        let renderer = MarkdownRenderer(configuration: ContinuousPreviewStyle.rendererConfiguration)
        for level in 1...6 {
            let rendered = renderer.render(markdown: "\(String(repeating: "#", count: level)) Heading")
            let font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.fontName, names[level - 1])
            XCTAssertEqual(font.pointSize, [34, 26, 21, 17, 14, 13][level - 1])
        }
    }

    func testInlineEmphasisPreservesHeadingWeightAndItalicSixthLevel() throws {
        for level in [1, 2, 6] {
            let rendered = MarkdownRenderer().render(markdown: "\(String(repeating: "#", count: level)) Plain **strong** *emphasis* ***both***")
            for text in ["Plain", "strong", "emphasis", "both"] {
                let index = (rendered.string as NSString).range(of: text).location
                let font = try XCTUnwrap(rendered.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
                let italic = level == 6 || text == "emphasis" || text == "both"
                XCTAssertEqual(font.fontName, level == 6 ? "AvenirNext-DemiBoldItalic" : "AvenirNext-Bold\(italic ? "Italic" : "")")
            }
        }
    }

    func testBoundsFallbacksAndSpacingWithoutPreviousParagraphStyle() {
        XCTAssertEqual(HeadingTypography(level: -1).printSize, 26)
        XCTAssertEqual(HeadingTypography(level: 99).printSize, 10)
        let fonts = FontBook(configuration: RendererConfiguration(fontFamily: "Missing Font"))
        for level in 1...6 {
            let font = fonts.heading(level: level, size: sizes[level - 1])
            XCTAssertEqual(font.pointSize, sizes[level - 1])
            XCTAssertEqual(NSFontManager.shared.traits(of: font).contains(.italicFontMask), level == 6)
        }
        let heading = HeadingTypography(level: 2)
        XCTAssertEqual(heading.additionalSpacingBefore(in: NSAttributedString(string: "\n\n")), 0)
        XCTAssertEqual(heading.additionalSpacingBefore(in: NSAttributedString(string: "Text\n")), 18)
        XCTAssertEqual(heading.additionalSpacingBefore(after: 30), 0)
        XCTAssertEqual(heading.additionalSpacingBefore(after: nil), 0)
        XCTAssertEqual((1...6).map { HeadingTypography(level: $0).readerSize }, [40, 32, 26, 22, 19, 17])
    }
}

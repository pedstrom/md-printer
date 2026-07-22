import AppKit
import XCTest
@testable import MarkdownPrinterCore

final class RendererConfigurationTests: XCTestCase {
    func testDefaultsAndHeadingBounds() {
        let configuration = RendererConfiguration()
        XCTAssertEqual(configuration.fontFamily, "Avenir Next")
        XCTAssertEqual(configuration.bodyFontSize, 10)
        XCTAssertEqual(configuration.headingFontSizes, [24, 20, 17, 14, 12, 10])
        XCTAssertEqual(configuration.contentWidth, 504)
        XCTAssertEqual(configuration.headingSize(for: -1), 24)
        XCTAssertEqual(configuration.headingSize(for: 1), 24)
        XCTAssertEqual(configuration.headingSize(for: 6), 10)
        XCTAssertEqual(configuration.headingSize(for: 99), 10)
        XCTAssertEqual(configuration.codeBlockPadding, 8)
        XCTAssertEqual(configuration.textColor, .black)
        XCTAssertEqual(configuration.secondaryTextColor, NSColor(calibratedWhite: 0.5, alpha: 1))
        XCTAssertEqual(
            configuration.accentColor,
            NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 1)
        )
        XCTAssertEqual(configuration, RendererConfiguration())
    }

    func testConfigurationInequalityAndMinimumContentWidth() {
        var configuration = RendererConfiguration()
        configuration.pageSize.width = 50
        XCTAssertEqual(configuration.contentWidth, 1)
        XCTAssertNotEqual(configuration, RendererConfiguration())
    }

    func testFontBookUsesAvenirNextVariants() {
        let fonts = FontBook(configuration: RendererConfiguration())
        XCTAssertEqual(fonts.regular(size: 12).familyName, "Avenir Next")
        XCTAssertEqual(fonts.bold(size: 12).familyName, "Avenir Next")
        XCTAssertEqual(fonts.italic(size: 12).familyName, "Avenir Next")
        XCTAssertEqual(fonts.boldItalic(size: 12).familyName, "Avenir Next")
        XCTAssertTrue(fonts.monospaced(size: 11).isFixedPitch)
    }

    func testFontFallbackForUnknownFamily() {
        let fonts = FontBook(configuration: RendererConfiguration(fontFamily: "Definitely Missing Font"))
        XCTAssertEqual(fonts.regular(size: 10).pointSize, 10)
        XCTAssertEqual(fonts.bold(size: 11).pointSize, 11)
        XCTAssertEqual(fonts.italic(size: 12).pointSize, 12)
        XCTAssertEqual(fonts.boldItalic(size: 13).pointSize, 13)
    }
}

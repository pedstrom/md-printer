import AppKit
import XCTest
@testable import MarkdownPrinterCore

final class RendererConfigurationTests: XCTestCase {
    func testDefaultsAndHeadingBounds() {
        let configuration = RendererConfiguration()
        XCTAssertEqual(configuration.fontFamily, "Avenir Next")
        XCTAssertEqual(configuration.contentWidth, 504)
        XCTAssertEqual(configuration.headingSize(for: -1), 28)
        XCTAssertEqual(configuration.headingSize(for: 1), 28)
        XCTAssertEqual(configuration.headingSize(for: 6), 12)
        XCTAssertEqual(configuration.headingSize(for: 99), 12)
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
    }

    func testFontFallbackForUnknownFamily() {
        let fonts = FontBook(configuration: RendererConfiguration(fontFamily: "Definitely Missing Font"))
        XCTAssertEqual(fonts.regular(size: 10).pointSize, 10)
        XCTAssertEqual(fonts.bold(size: 11).pointSize, 11)
        XCTAssertEqual(fonts.italic(size: 12).pointSize, 12)
        XCTAssertEqual(fonts.boldItalic(size: 13).pointSize, 13)
    }
}

import Foundation
import XCTest
@testable import MarkdownPrinterCore

final class CommonMarkSelectedConformanceTests: XCTestCase {
    func testAllPinnedExamplesFromSelectedCommonMarkSections() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.commonmarkVersion, "0.31.2")
        XCTAssertEqual(fixture.examples.count, 166)

        let parser = MarkdownParser()
        var failures: [String] = []
        for example in fixture.examples {
            let actual = CommonMarkHTMLSerializer.serialize(parser.parse(example.markdown))
            if normalizedCommonMarkHTML(actual) != normalizedCommonMarkHTML(example.html) {
                failures.append(
                    "Example \(example.example) [\(example.section)]\n"
                        + "Markdown:\n\(example.markdown)\n"
                        + "Expected:\n\(example.html)"
                        + "Actual:\n\(actual)"
                )
            }
        }

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n---\n"))
    }

    private func loadFixture() throws -> CommonMarkFixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "selected-examples",
            withExtension: "json",
            subdirectory: "CommonMark"
        ))
        return try JSONDecoder().decode(CommonMarkFixture.self, from: Data(contentsOf: url))
    }

}

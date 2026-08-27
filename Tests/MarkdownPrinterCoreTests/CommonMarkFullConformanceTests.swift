import Foundation
import XCTest
@testable import MarkdownPrinterCore

final class CommonMarkFullConformanceTests: XCTestCase {
    func testFullCommonMarkCompatibilityDoesNotRegress() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.commonmarkVersion, "0.31.2")
        XCTAssertEqual(fixture.examples.count, 652)

        let parser = MarkdownParser()
        var passesBySection: [String: Int] = [:]
        var totalsBySection: [String: Int] = [:]
        var failuresBySection: [String: [Int]] = [:]
        for example in fixture.examples {
            let actual = CommonMarkHTMLSerializer.serialize(parser.parse(example.markdown))
            let passed = normalizedCommonMarkHTML(actual) == normalizedCommonMarkHTML(example.html)
            totalsBySection[example.section, default: 0] += 1
            if passed {
                passesBySection[example.section, default: 0] += 1
            } else {
                failuresBySection[example.section, default: []].append(example.example)
                if ProcessInfo.processInfo.environment["COMMONMARK_VERBOSE"] == "1" {
                    print("Example \(example.example) [\(example.section)]\nMARKDOWN:\n\(example.markdown)EXPECTED:\n\(example.html)ACTUAL:\n\(actual)---")
                }
            }
        }

        let passed = passesBySection.values.reduce(0, +)
        let summary = totalsBySection.keys.sorted().map { section in
            let sectionPassed = passesBySection[section, default: 0]
            let total = totalsBySection[section, default: 0]
            let failures = failuresBySection[section, default: []].map(String.init).joined(separator: ",")
            return "\(section): \(sectionPassed)/\(total) failures=[\(failures)]"
        }.joined(separator: "\n")
        print("CommonMark 0.31.2 compatibility: \(passed)/\(fixture.examples.count)\n\(summary)")
        XCTAssertGreaterThanOrEqual(passed, 620, summary)
    }

    private func loadFixture() throws -> CommonMarkFixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "all-examples",
            withExtension: "json",
            subdirectory: "CommonMark"
        ))
        return try JSONDecoder().decode(CommonMarkFixture.self, from: Data(contentsOf: url))
    }
}

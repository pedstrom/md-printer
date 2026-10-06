import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class MarkdownPrinterHelpPromptTests: XCTestCase {
    func testSetupSeparatesTheCompletePromptFromInstructionsAndExample() throws {
        let section = try XCTUnwrap(
            MarkdownPrinterHelpContent.sections.first { $0.id == .codexComparisons }
        )
        let prompt = try XCTUnwrap(section.copyablePrompt)
        let instructions = section.paragraphs.joined(separator: "\n")

        XCTAssertEqual(section.title, "Set Up Codex Comparisons")
        XCTAssertTrue(instructions.contains("once on each Mac"))
        XCTAssertTrue(instructions.contains("Click Copy prompt below"))
        XCTAssertTrue(instructions.contains("paste it into a Codex chat on this Mac, and send it"))
        XCTAssertTrue(instructions.contains("across projects for your user on this Mac"))
        XCTAssertEqual(prompt.title, "Prompt to paste into Codex")
        XCTAssertEqual(prompt.text, MarkdownPrinterHelpContent.codexComparisonSkillPrompt)
        XCTAssertEqual(prompt.exampleTitle, "After setup, try…")
        XCTAssertTrue(prompt.example.hasPrefix("Compare notes.md"))
        XCTAssertFalse(prompt.text.contains(prompt.example))
        XCTAssertFalse(instructions.contains(prompt.text))
        XCTAssertEqual(MarkdownPrinterHelpContent.sections.compactMap(\.copyablePrompt).count, 1)
        for text in prompt.searchableTexts {
            XCTAssertTrue(MarkdownPrinterHelpContent.searchableText.contains(text))
        }
    }

    func testPromptRetainsPortableLaunchAndSourcePreservationInstructions() {
        let prompt = MarkdownPrinterHelpContent.codexComparisonSkillPrompt
        for instruction in [
            "available in every project on this Mac",
            "user-level skills directory supported by my Codex installation",
            "name and description frontmatter",
            "If “previous version” is ambiguous, ask one concise question",
            "without checking out, restoring, or modifying working files",
            "private temporary .md file",
            #""/Applications/Markdown Printer.app/Contents/MacOS/MarkdownPrinterCLI" open "/absolute/path/current.md" --original "/absolute/path/older.md""#,
            "exactly one current file",
            "If the app is installed elsewhere",
            "After a successful launch, delete only temporary originals",
            "Validate the skill"
        ] {
            XCTAssertTrue(prompt.contains(instruction), "Missing skill instruction: \(instruction)")
        }
    }
}

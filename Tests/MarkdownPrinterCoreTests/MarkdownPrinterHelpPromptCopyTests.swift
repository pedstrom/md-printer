import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class MarkdownPrinterHelpPromptCopyTests: XCTestCase {
    func testCopiesExactlyTheCompletePromptAsPlainTextAndReplacesOldClipboardContent() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Old rich content", forType: .html)
        let controller = MarkdownPrinterHelpPromptCopyController(pasteboard: pasteboard)
        XCTAssertFalse(controller.isCopied)

        XCTAssertTrue(controller.copy(MarkdownPrinterHelpContent.codexComparisonSkillPrompt))

        XCTAssertTrue(controller.isCopied)
        XCTAssertEqual(pasteboard.string(forType: .string), MarkdownPrinterHelpContent.codexComparisonSkillPrompt)
        XCTAssertNil(pasteboard.string(forType: .html))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    func testCopiedFeedbackExpires() async throws {
        let controller = MarkdownPrinterHelpPromptCopyController(
            feedbackDuration: .milliseconds(10), writeText: { _ in true }
        )
        controller.copy("Prompt")
        XCTAssertTrue(controller.isCopied)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(controller.isCopied)
    }

    func testRepeatedCopyRestartsFeedbackAndWritesAgain() async throws {
        var copiedTexts: [String] = []
        let controller = MarkdownPrinterHelpPromptCopyController(
            feedbackDuration: .milliseconds(100),
            writeText: { copiedTexts.append($0); return true }
        )
        controller.copy("First prompt")
        try await Task.sleep(for: .milliseconds(60))
        controller.copy("Second prompt")
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(controller.isCopied, "The first copy must not clear the second copy's feedback.")
        XCTAssertEqual(copiedTexts, ["First prompt", "Second prompt"])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(controller.isCopied)
    }

    func testFailedWriteDoesNotReportCopiedAndCancelsEarlierFeedback() {
        var canWrite = true
        let controller = MarkdownPrinterHelpPromptCopyController(writeText: { _ in canWrite })
        XCTAssertTrue(controller.copy("Prompt"))
        canWrite = false

        XCTAssertFalse(controller.copy("Prompt"))
        XCTAssertFalse(controller.isCopied)
    }
}

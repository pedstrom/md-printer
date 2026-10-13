import AppKit
import XCTest
@testable import MarkdownPrinterCore

final class RevisionCommitAttributionTests: XCTestCase {
    private func documents(_ versions: [String]) -> [MarkdownDocument] {
        versions.map { MarkdownDocument(title: "Fixture", markdown: $0) }
    }
    private func attributed(_ versions: [String]) throws -> [(RevisionReviewItem, Set<Int>)] {
        let docs = documents(versions)
        let items = MarkdownRenderer().render(document: docs.last!, original: docs.first!).reviewItems
        let contributions = try RevisionCommitAttribution.contributions(in: docs)
        XCTAssertEqual(Set(contributions.keys), Set(items.map(\.id)))
        return items.map { ($0, contributions[$0.id] ?? []) }
    }

    func testTwoContributorsAndSingleContributorAcrossThreeCommits() throws {
        let first = "# Plan\n\n## Review\n\nThe owner approves the final document before sharing.\n\n## Schedule\n\nThe team finishes by Friday."
        let second = first.replacingOccurrences(of: "approves", with: "reviews")
        let third = second.replacingOccurrences(of: "Friday", with: "Thursday")
        let final = third.replacingOccurrences(of: "reviews", with: "must approve")
        let result = try attributed([first, second, third, final, final])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.0.sectionTitle == "Review" }?.1, [0, 2])
        XCTAssertEqual(result.first { $0.0.sectionTitle == "Schedule" }?.1, [1])
    }

    func testIndependentParagraphsUnderSameHeadingAndShiftedPositions() throws {
        let old = "# Review\n\nThe owner checks every document.\n\nThe editor reviews every appendix."
        let first = old.replacingOccurrences(of: "checks", with: "approves")
        let second = "A new introduction.\n\n" + first
        let final = second.replacingOccurrences(of: "reviews", with: "signs")
        let result = try attributed([old, first, second, final])
        XCTAssertEqual(result.first { $0.0.current?.contains("owner") == true }?.1, [0])
        XCTAssertEqual(result.first { $0.0.current?.contains("editor") == true }?.1, [2])
        XCTAssertEqual(result.first { $0.0.kind == .added }?.1, [1])
    }

    func testDeletedPassageRetainsItsEarlierEditsAndExcludesLaterNeighborEdits() throws {
        let old = "# Notes\n\n## Removed\n\nA previous paragraph contains important review details.\n\n## Closing\n\nKeep this closing paragraph."
        let edited = old.replacingOccurrences(of: "important", with: "updated")
        let removed = "# Notes\n\n## Removed\n\n## Closing\n\nKeep this closing paragraph."
        let final = removed.replacingOccurrences(of: "closing", with: "final")
        let result = try attributed([old, edited, removed, final])
        XCTAssertEqual(result.first { $0.0.kind == .removed }?.1, [0, 1])
        XCTAssertEqual(result.first { $0.0.kind == .changed }?.1, [2])
    }

    func testConsolidatedPassageIncludesAllOfItsContributors() throws {
        let old = "# Notes\n\nA previous paragraph contains important review details.\n\nKeep this closing paragraph."
        let edited = old.replacingOccurrences(of: "important", with: "updated")
        let removed = "# Notes\n\nKeep this closing paragraph."
        let final = removed.replacingOccurrences(of: "closing", with: "final")
        let result = try attributed([old, edited, removed, final])
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.1, [0, 1, 2])
    }

    func testIdenticalParagraphsAndRepeatedHeadingTitlesRemainIndependent() throws {
        let paragraph = "The owner reviews the document."
        let old = "# Repeated\n\n\(paragraph)\n\n# Repeated\n\n\(paragraph)"
        let first = "# Repeated\n\nThe owner approves the document.\n\n# Repeated\n\n\(paragraph)"
        let final = first.replacingOccurrences(of: "reviews", with: "signs")
        let result = try attributed([old, first, final])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first { $0.0.current?.contains("approves") == true }?.1, [0])
        XCTAssertEqual(result.first { $0.0.current?.contains("signs") == true }?.1, [1])
    }

    func testTablesKeepContributionsWithTheirRowsAcrossAnInsertion() throws {
        let old = "# Table\n\n| ID | Status |\n|---|---|\n| A | Pending |\n| B | Waiting |"
        let first = old.replacingOccurrences(of: "A | Pending", with: "A | Approved")
        let second = first.replacingOccurrences(of: "| A |", with: "| Z | New |\n| A |")
        let final = second.replacingOccurrences(of: "B | Waiting", with: "B | Ready")
        let result = try attributed([old, first, second, final])
        XCTAssertEqual(result.first { $0.0.current?.contains("Approved") == true }?.1, [0])
        XCTAssertEqual(result.first { $0.0.current?.contains("Ready") == true }?.1, [2])
        XCTAssertEqual(result.first { $0.0.current?.contains("New") == true }?.1, [1])
    }

    func testFormattingImagesCodeAndUnicodeUseTheSameReviewIdentities() throws {
        for versions in [
            ["# Same\n\nPlain text", "# Same\n\n**Plain** text", "# Same\n\n**Plain** text"],
            ["![Old](missing.png)", "![New](other.png)", "![New](other.png)"],
            ["```swift\nlet a = 1\n```", "```swift\nlet a = 2\n```", "```swift\nlet a = 2\n```"],
            ["The café is in 東京.", "The café is near 東京.", "The café is near 東京."]
        ] {
            let result = try attributed(versions)
            XCTAssertFalse(result.isEmpty)
            XCTAssertTrue(result.allSatisfy { $0.1 == [0] })
        }
    }

    func testLocalOnlyRevertedAndEmptyHistories() throws {
        let local = try attributed(["The owner checks the final document.", "The owner approves the final document."])
        XCTAssertEqual(local.first?.1, [0])
        XCTAssertTrue(try attributed(["Keep this.", "Change this.", "Keep this."]).isEmpty)
        XCTAssertTrue(try RevisionCommitAttribution.contributions(in: []).isEmpty)
        XCTAssertTrue(try RevisionCommitAttribution.contributions(in: documents(["One"])).isEmpty)
        XCTAssertTrue(try attributed(["Entire removed paragraph.", ""]).allSatisfy { $0.1 == [0] })
    }

    func testCancellationStopsHistoryWork() async throws {
        let task = Task {
            try Task.checkCancellation()
            return try RevisionCommitAttribution.contributions(in: documents(["Old text.", "New text."]))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}

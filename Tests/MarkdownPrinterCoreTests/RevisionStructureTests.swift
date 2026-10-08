import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionStructureTests: XCTestCase {
    private func review(_ old: String, _ new: String) -> RevisionRenderedText {
        MarkdownRenderer().render(document: MarkdownDocument(title: "Current", markdown: new), original: MarkdownDocument(title: "Earlier", markdown: old))
    }
    private func wording(_ item: RevisionReviewItem, earlier: Bool) -> String {
        let source = (earlier ? item.earlier : item.current)! as NSString
        return (earlier ? item.removedRanges : item.addedRanges).map { source.substring(with: $0) }.joined(separator: "|")
    }
    func testAddedContentsSectionAndNestedLinksAreOneCompleteEntry() throws {
        let old = "# Guide\n\n## Opening\n\nKeep.\n\n## Tasks\n\nDo this."
        let links = (1...40).map { "- [Section \($0)](#section-\($0))\n  - [Child \($0)](#child-\($0))" }.joined(separator: "\n")
        let new = old.replacingOccurrences(of: "## Tasks", with: "## Contents\n\n" + links + "\n\n## Tasks")
        let result = review(old, new)
        let item = try XCTUnwrap(result.reviewItems.first)
        XCTAssertEqual(result.reviewItems.count, 1); XCTAssertEqual(item.kind, .added)
        XCTAssertEqual(item.sectionTitle, "Contents"); XCTAssertTrue(item.current!.contains("Child 40"))
        XCTAssertTrue(item.metadata.contains { $0.contains("#child-40") })
    }
    func testCompleteRemovedTableAndParagraphKeepOriginalSection() {
        let old = "# Guide\n\n## Status\n\nKeep introduction.\n\nRemoved advice.\n\n| Area | State |\n|---|---|\n| A | Active |\n| B | Open |\n\n## Following\n\nKeep ending."
        let new = "# Guide\n\n## Status\n\nKeep introduction.\n\n## Following\n\nKeep ending."
        let result = review(old, new)
        XCTAssertEqual(result.reviewItems.count, 2)
        XCTAssertTrue(result.reviewItems.allSatisfy { $0.sectionTitle == "Status" && $0.kind == .removed })
        XCTAssertTrue(result.reviewItems.last!.earlier!.contains("Open"))
        XCTAssertTrue(result.decorations.deletions.contains { $0.summary == .tables(1) })
    }
    func testRemovedSubsectionIncludesItsHeadingAndBodyOnce() {
        let old = "# Guide\n\n## Scope\n\nKeep scope.\n\n### Optional path\n\nRetired advice.\n\n### Tasks\n\nKeep tasks."
        let new = old.replacingOccurrences(of: "### Optional path\n\nRetired advice.\n\n", with: "")
        let items = review(old, new).reviewItems
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].sectionTitle, "Optional path")
        XCTAssertTrue(items[0].earlier!.contains("Optional path")); XCTAssertTrue(items[0].earlier!.contains("Retired advice"))
    }
    func testRemovingOnlyAHeadingKeepsItsSurvivingBodyUnchanged() {
        let result = review("# Retired heading\n\nKept body.", "Kept body.")
        XCTAssertEqual(result.reviewItems.count, 1)
        XCTAssertEqual(result.reviewItems[0].earlier, "Retired heading\n")
        XCTAssertTrue(result.decorations.highlights.isEmpty)
    }
    func testRemovedLooseListCountsItemsIncludingNestedItemsOnce() {
        let old = "- First item.\n\n  Continuation paragraph.\n\n  - Nested item.\n\n- Second item.\n\nKept body."
        let result = review(old, "Kept body.")
        XCTAssertEqual(result.reviewItems.count, 1)
        XCTAssertTrue(result.reviewItems[0].earlier!.contains("Continuation paragraph"))
        XCTAssertEqual(result.decorations.deletions.first?.summary, .listItems(3))
    }
    func testSubstantialLabeledParagraphRewriteIsOneReplacement() {
        let result = review("## Measures\n\nTarget: Set the savings target after the finance team approves the method and the pilot establishes a baseline.", "## Measures\n\nTarget: The portfolio ambition is substantial signed savings. Finance will define the realized target and method as the pilot establishes the operating baseline.")
        XCTAssertEqual(result.reviewItems.count, 1); XCTAssertEqual(result.reviewItems[0].kind, .changed)
        XCTAssertTrue(result.reviewItems[0].earlier!.contains("approves")); XCTAssertTrue(result.reviewItems[0].current!.contains("ambition"))
    }
    func testUnrelatedReplacementCandidatesRemainIndependent() {
        let result = review("## Notes\n\nApples grow beside orchards.", "## Notes\n\nSatellites orbit distant planets.")
        XCTAssertEqual(result.reviewItems.map(\.kind), [.removed, .added])
    }
    func testParagraphConsolidationRetainsEveryOriginalAndCurrentWord() {
        let result = review("## Notes\n\nThe service provides local access and reliable evidence.\n\nThe service uses approved source records and exact citations.", "## Notes\n\nThe service provides local access to approved source records with reliable evidence and exact citations.")
        XCTAssertEqual(result.reviewItems.count, 1); XCTAssertEqual(result.reviewItems[0].kind, .changed)
        XCTAssertTrue(result.reviewItems[0].earlier!.contains("\n\n"))
        XCTAssertTrue(result.reviewItems[0].earlier!.contains("exact citations"))
    }
    func testTableToListConversionIsACompleteReplacement() {
        let old = "## Evaluation\n\nThe evaluation baseline includes:\n\n- approved questions and source records;\n- reviewer results and scoring.\n\n| Area | Practice |\n|---|---|\n| Sources | Approved source records and exact citations |\n| Quality | Reviewer scoring and release evidence |"
        let new = "## Evaluation\n\nThe evaluation baseline contains approved questions, source records, reviewer results, and scoring.\n\nThe release approach includes:\n\n- approved source records and exact citations;\n- reviewer scoring and release evidence."
        let result = review(old, new)
        XCTAssertEqual(result.reviewItems.count, 2); XCTAssertTrue(result.reviewItems.allSatisfy { $0.kind == .changed })
        XCTAssertTrue(result.reviewItems[1].earlier!.contains("Practice"))
        XCTAssertTrue(result.reviewItems[1].current!.contains("release evidence"))
    }
    func testRenamedSectionKeepsChangesInOneGroupAndNavigationOrder() {
        let old = "## Previous Operating Model\n\nThe service has an old owner.\n\nRetired unrelated paragraph.\n\n## Ending\n\nKeep."
        let new = "## Current Operating Model\n\nThe service has a new owner.\n\n## Ending\n\nKeep."
        let items = review(old, new).reviewItems
        XCTAssertEqual(Set(items.map(\.sectionID)).count, 1)
        XCTAssertTrue(items.allSatisfy { $0.sectionTitle == "Current Operating Model" })
        XCTAssertEqual(items.map(\.kind), [.changed, .changed, .removed])
    }
    func testTablesMatchIdentifiersAndColumnMeaningAcrossInsertion() throws {
        let old = "## Gates\n\n| Gate | Decision | Team working status | Remaining proof |\n|---|---|---|---|\n| G0 | Approve scope | Complete | Reconcile the corpus |\n| G1 | Approve data | Open | Validate source records |"
        let new = "## Release Gates\n\n| Gate | Decision and authority | Current status and evidence | Required evidence for progression | Consequence |\n|---|---|---|---|---|\n| G1 | Leaders approve data | Open pending review | Validate source records | Allows testing |\n| G0 | Leaders approve scope | Complete with evidence | Maintain corpus alignment | Allows release |"
        let result = review(old, new)
        let row = try XCTUnwrap(result.reviewItems.first { $0.current?.hasPrefix("G0\n") == true })
        XCTAssertTrue(row.earlier!.contains("Complete"))
        XCTAssertFalse(wording(row, earlier: true).contains("Complete"), "The status survives within its corresponding column")
        XCTAssertTrue(wording(row, earlier: true).contains("Reconcile"))
        XCTAssertFalse(wording(row, earlier: false).contains("Complete"))
        XCTAssertEqual(result.reviewItems.filter { $0.current?.hasPrefix("G1\n") == true }.count, 1)
    }
    func testReorderedColumnsDoNotCompareAcrossFields() throws {
        let old = "| ID | Status | Evidence |\n|---|---|---|\n| A1 | Open | Prior record |"
        let new = "| ID | Evidence | Status |\n|---|---|---|\n| A1 | Updated record | Open |"
        let row = try XCTUnwrap(review(old, new).reviewItems.first { $0.current?.hasPrefix("A1\n") == true })
        XCTAssertFalse(wording(row, earlier: true).contains("Open"))
        XCTAssertFalse(wording(row, earlier: false).contains("Open"))
        XCTAssertTrue(wording(row, earlier: true).contains("Prior"))
    }
    func testEmptyCellsRetainTheirColumnInsteadOfShiftingEvidence() throws {
        let old = "| ID | Status | Evidence |\n|---|---|---|\n| R1 | | Exact source record |"
        let new = "| ID | Status | Evidence |\n|---|---|---|\n| R1 | Approved | Exact source record |"
        let row = try XCTUnwrap(review(old, new).reviewItems.first)
        XCTAssertEqual(row.kind, .changed)
        XCTAssertTrue(row.earlier!.contains("Exact source record"))
        XCTAssertFalse(wording(row, earlier: true).contains("Exact"))
        XCTAssertEqual(wording(row, earlier: false), "Approved")
    }
    func testInsertedAndRemovedIdentifiedRowsStayIndependent() {
        let old = "| ID | Value |\n|---|---|\n| A1 | Stable |\n| B2 | Retired |"
        let new = "| ID | Value |\n|---|---|\n| A1 | Stable |\n| C3 | Added |"
        let items = review(old, new).reviewItems
        XCTAssertEqual(Set(items.map(\.kind)), [.added, .removed])
        XCTAssertFalse(items.contains { $0.earlier?.contains("B2") == true && $0.current?.contains("C3") == true })
    }
    func testChangedRowIncludesUnchangedCellsAndExactEvidence() throws {
        let result = review("| ID | A | B |\n|---|---|---|\n| R1 | First old value | Second old value |", "| ID | A | B |\n|---|---|---|\n| R1 | First new value | Second new value |")
        XCTAssertEqual(result.reviewItems.count, 1)
        let row = try XCTUnwrap(result.reviewItems.first)
        XCTAssertTrue(row.current!.contains("R1")); XCTAssertEqual(wording(row, earlier: true), "old|old")
    }
    func testConsolidatedTablesRetainExistingIdentifiedRows() {
        let old = "## Requirements\n\n| ID | Detail |\n|---|---|\n| R1 | Keep first requirement |\n\n### Additional Requirements\n\n| ID | Detail |\n|---|---|\n| R2 | Keep second requirement |"
        let new = "## Requirements\n\n| ID | Detail |\n|---|---|\n| R1 | Keep first requirement |\n| R2 | Keep second requirement |"
        let result = review(old, new)
        XCTAssertFalse(result.reviewItems.contains { $0.current?.contains("Keep second requirement") == true })
        XCTAssertTrue(result.reviewItems.contains { $0.kind == .removed && $0.earlier?.contains("Additional Requirements") == true })
        XCTAssertTrue(result.decorations.highlights.isEmpty)
    }
    func testListToTableConversionKeepsTheEntireEarlierList() {
        let old = "## Methods\n\nUse these methods:\n\n- source records have exact citations;\n- reviewer scoring provides release evidence."
        let new = "## Methods\n\n| Method | Practice |\n|---|---|\n| Sources | Source records have exact citations |\n| Scoring | Reviewer scoring provides release evidence |"
        let items = review(old, new).reviewItems
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0].kind, .changed)
        XCTAssertTrue(items[0].earlier!.contains("Use these methods"))
        XCTAssertTrue(items[0].current!.contains("Practice"))
    }
    func testSidebarHighlightsUseSameCoherentPassageAsPDF() throws {
        let result = review("The service manages old records and preserves a substantial unchanged ending with exact source citations for reviewers.", "The service manages newly approved records with additional context and preserves a substantial unchanged ending with exact source citations for reviewers.")
        let item = try XCTUnwrap(result.reviewItems.first)
        let pdf = result.decorations.highlights.map { (result.text.string as NSString).substring(with: $0) }.joined(separator: "|")
        XCTAssertEqual(wording(item, earlier: false), pdf)
        XCTAssertFalse(wording(item, earlier: true).contains("substantial unchanged ending"))
    }
    func testNumericChangesHighlightCompleteAmounts() throws {
        let result = review("The annual total is $120,000 with 2.5 units.", "The annual total is $135,000 with 3.5 units.")
        let item = try XCTUnwrap(result.reviewItems.first)
        XCTAssertTrue(wording(item, earlier: false).contains("135,000")); XCTAssertTrue(wording(item, earlier: false).contains("3.5"))
        XCTAssertTrue(wording(item, earlier: true).contains("120,000"))
    }
    func testVisibleEntriesNumbersAndNextNavigationUseOneSequence() throws {
        let old = "## Requirements\n\nOld introduction with shared guidance.\n\n| ID | Detail |\n|---|---|\n| R1 | First old detail |\n\n### Additional Requirements\n\n| ID | Detail |\n|---|---|\n| R2 | Second old detail |"
        let new = "## Requirements\n\nNew introduction with shared guidance.\n\n| ID | Detail |\n|---|---|\n| R1 | First new detail |\n| R2 | Second new detail |"
        let output = review(old, new)
        let pdf = try PDFExporter().render(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        let snapshot = RenderedDocumentSnapshot(document: MarkdownDocument(title: "Current", markdown: new), renderedText: output.text,
            pdfData: pdf.data, pageSetup: .letter, footers: .init(), revision: 1, decorations: output.decorations,
            reviewItems: output.reviewItems, reviewDestinations: pdf.reviewDestinations,
            baseline: OriginalDocumentSnapshot(document: MarkdownDocument(title: "Earlier", markdown: old)))
        let controller = RevisionReviewController(); controller.update(snapshot)
        let view = RevisionChangesView(controller: controller); view.refresh()
        let entries = (0..<view.outline.numberOfRows).compactMap { view.outline.item(atRow: $0) as? RevisionChangesView.Entry }
        XCTAssertEqual(entries.map { $0.value.id }, output.reviewItems.map(\.id))
        for (index, entry) in entries.enumerated() {
            let cell = try XCTUnwrap(view.outlineView(view.outline, viewFor: nil, item: entry) as? NSTableCellView)
            XCTAssertTrue(cell.textField!.stringValue.hasPrefix("\(index + 1) · "))
            XCTAssertEqual(controller.selectionLabel, "Change \(index + 1) of \(entries.count)")
            XCTAssertEqual(controller.selectedItem?.id, entry.value.id)
            controller.next()
        }
    }
    func testGroupedDestinationsAndPlainBodyPositionsRemainIdentical() throws {
        let old = "# Guide\n\n## End\n\nKeep."
        let new = old.replacingOccurrences(of: "## End", with: "## Contents\n\n- [End](#end)\n- Other entry\n\n## End")
        let result = review(old, new)
        let exporter = PDFExporter()
        let marked = try exporter.render(from: result.text, decorations: result.decorations, reviewItems: result.reviewItems)
        let plain = try exporter.render(from: MarkdownRenderer().render(markdown: new))
        let a = try XCTUnwrap(PDFDocument(data: marked.data)), b = try XCTUnwrap(PDFDocument(data: plain.data))
        XCTAssertEqual(a.pageCount, b.pageCount); XCTAssertEqual(a.string, b.string)
        XCTAssertEqual(marked.reviewDestinations.count, 1)
        XCTAssertGreaterThan(marked.reviewDestinations.values.first!.fragments[0].passageBounds.height, 15)
    }
}

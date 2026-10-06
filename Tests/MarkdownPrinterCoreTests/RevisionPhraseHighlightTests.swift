import AppKit
import XCTest
@testable import MarkdownPrinterCore

@MainActor
final class RevisionPhraseHighlightTests: XCTestCase {
    private func revision(_ old: String, _ current: String) -> RevisionRenderedText {
        MarkdownRenderer().render(document: MarkdownDocument(title: "Current", markdown: current),
            original: MarkdownDocument(title: "Original", markdown: old))
    }
    private func highlights(_ value: RevisionRenderedText) -> [String] {
        value.decorations.highlights.map { (value.text.string as NSString).substring(with: $0) }
    }

    func testMinorProsePunctuationAndWhitespaceDoNotHighlight() {
        for pair in [("Alpha beta.", "Alpha, beta."), ("Alpha beta.", "Alpha beta!"),
                     ("Alpha beta", "Alpha  beta")] {
            XCTAssertTrue(revision(pair.0, pair.1).decorations.highlights.isEmpty)
        }
        XCTAssertEqual(highlights(revision("Alpha old beta.", "Alpha new beta.")), ["new"])
        XCTAssertEqual(highlights(revision("support.", "support model.")), ["model"])
    }

    func testChangedPhrasesIncludeInternalSpacesAndTrimTheirEnds() {
        for phrase in ["while keeping", "cost of each component visible", "how an external release", "affect that advantage"] {
            let value = revision("Begin end.", "Begin \(phrase) end.")
            XCTAssertEqual(highlights(value), [phrase])
        }
    }

    func testNewParagraphIncludesAllInternalWhitespace() {
        let paragraph = "A new paragraph has several words, including punctuation."
        XCTAssertEqual(highlights(revision("", paragraph)), [paragraph])
        XCTAssertEqual(highlights(revision("Keep.\n\n", "Keep.\n\n" + paragraph)), [paragraph])
    }

    func testRewriteUsesPassageAnchorsAndPreservesUnchangedEnds() {
        let prefix = "The team manages "
        let tail = "and notes stay in a shared archive with consistent names and readers rely on the same examples to find relevant context."
        let old = prefix + "old library volumes across approximately 42 thousand in annual library loans, but volumes cannot be readily compared across groups. Data " + tail
        let passage = "approximately 7,200 library volumes, collects 360 new volumes each year, and reviews approximately 42 thousand in annual library loans. Volumes can have one or many uses, and different groups can review them whenever useful. Today, however, volumes cannot be easily compared across groups: data"
        let current = prefix + passage + " " + tail
        let value = revision(old, current)
        XCTAssertEqual(highlights(value), [passage])
        XCTAssertFalse(highlights(value).joined().contains(tail))
    }

    func testSmallIndependentEditsStayPrecise() {
        let value = revision("The red cat rests beside the blue dog, while the same long unchanged description stays intact.",
                             "The green cat rests beside the orange dog, while the same long unchanged description stays intact.")
        XCTAssertEqual(highlights(value), ["green", "orange"])
        XCTAssertFalse(revision("`a b`", "`a  b`").decorations.highlights.isEmpty)
        XCTAssertFalse(revision("one two", "one  \ntwo").decorations.highlights.isEmpty)
    }

    func testSurvivingShortPhraseBesideSubstantialSharedPassageStaysUnmarked() {
        let old = "If the director approves a public event, the budget must be reported separately from daily activities. The event budget should include venue rental, guest travel, refreshments after setup and staffing costs, and any sponsor or partner contributions. Tentative bookings and informal offers must remain outside the confirmed budget."
        let current = "For a public event, the budget will include venue rental, guest travel, refreshments after setup and staffing costs, and sponsor or partner contributions alongside the shared office budget."
        let value = revision(old, current)
        XCTAssertTrue(value.decorations.deletions.contains { $0.text == "any" })
        XCTAssertTrue(value.decorations.deletions.contains { $0.text.contains("Tentative bookings") })
        XCTAssertFalse(value.decorations.deletions.contains { $0.text.contains("sponsor or partner contributions") })
        XCTAssertFalse(highlights(value).joined().contains("sponsor or partner contributions"))
        let boundary = (value.text.string as NSString).range(of: "sponsor or partner contributions").location
        XCTAssertEqual(value.decorations.deletions.first { $0.text == "any" }?.location, boundary)
    }

    func testSurvivingPhraseSeparatesCoherentDeletionExcerpts() {
        let value = revision("The red cat and blue dog wait beside a lasting shared clause before the green bird and white fish sleep.",
                             "The orange cat and black dog run beside a lasting shared clause before the purple bird and gold fish swim.")
        XCTAssertEqual(value.decorations.deletions.map(\.text), ["red cat and blue dog wait", "green bird and white fish sleep"])
        XCTAssertFalse(value.decorations.deletions.contains { $0.text.contains("lasting shared clause") })
    }

    func testInlineDeletionBoundariesUseVisibleTokensInsteadOfProseSpacing() throws {
        for pair in [("Keep any distinct remaining words.", "Keep distinct remaining words.", "distinct"),
                     ("Élan any café 東京.", "Élan café 東京.", "café"),
                     ("The work resulted in clear value. These supporting measures explain the outcome.",
                      "The work resulted in clear value. Together, these measures show the outcome.", "Together")] {
            let value = revision(pair.0, pair.1)
            let deletion = try XCTUnwrap(value.decorations.deletions.first)
            XCTAssertEqual(deletion.location, (value.text.string as NSString).range(of: pair.2).location)
        }
        let trailing = revision("Keep deleted trailing words", "Keep")
        XCTAssertEqual(trailing.decorations.deletions.first?.location, 4)
        XCTAssertEqual(trailing.text.string, "Keep\n")
    }
}

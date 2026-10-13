import AppKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionCommitContextTests: XCTestCase {
    private let first = GitCommitDescription(id: "hidden-id-one", subject: "Clarify review ownership", body: "Name the owner as the reviewer.\n\nKeep the review deadline separate.", date: Date(timeIntervalSince1970: 1_700_000_000))
    private let second = GitCommitDescription(id: "hidden-id-two", subject: "Require approval", body: "Require explicit approval before sharing the final document.", date: Date(timeIntervalSince1970: 1_700_100_000))

    private func snapshot(current: String = "The owner must approve the final document.", baselineID: UUID = UUID(), revision: UInt64 = 1) -> RenderedDocumentSnapshot {
        let old = MarkdownDocument(title: "Fixture", markdown: "The owner reviews the final document.")
        let current = MarkdownDocument(sourceURL: URL(fileURLWithPath: "/tmp/fixture/current.md"), title: "Fixture", markdown: current)
        let rendered = MarkdownRenderer().render(document: current, original: old)
        return RenderedDocumentSnapshot(document: current, renderedText: rendered.text, pdfData: Data(), pageSetup: .letter,
            footers: ResolvedFooterConfiguration(), revision: revision, decorations: rendered.decorations, reviewItems: rendered.reviewItems,
            baseline: OriginalDocumentSnapshot(document: old, id: baselineID, gitRevision: String(repeating: "a", count: 40)))
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Timed out waiting for commit context")
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func labels(_ view: NSView) -> [NSTextField] { descendants(view).compactMap { $0 as? NSTextField } }

    func testControllerLoadsSelectedPassageContextCachesItAndClearsIt() async throws {
        let value = snapshot(), id = value.reviewItems[0].id
        let provider = TestContextProvider(context: GitChangeContext(commits: [id: [first, second]]))
        let controller = RevisionReviewController(); controller.contextProvider = provider
        var notifications = 0; controller.commitContextDidChange = { notifications += 1 }
        controller.update(value)
        XCTAssertEqual(controller.commitContextStatus, .loading)
        try await wait { controller.commitContextStatus == .ready }
        XCTAssertEqual(controller.commitContext.commits[id], [first, second]); XCTAssertEqual(notifications, 1)
        var refresh = value; refresh = RenderedDocumentSnapshot(document: value.document, renderedText: value.renderedText,
            pdfData: value.pdfData, pageSetup: value.pageSetup, footers: value.footers, revision: 2, reviewItems: value.reviewItems, baseline: value.baseline)
        controller.update(refresh)
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        var ordinary = value; ordinary.baseline = nil
        controller.update(ordinary)
        XCTAssertEqual(controller.commitContextStatus, .hidden); XCTAssertTrue(controller.commitContext.commits.isEmpty)
    }

    func testUnavailableContextDoesNotChangeTheComparisonOrSelection() async throws {
        let value = snapshot(), controller = RevisionReviewController()
        controller.contextProvider = TestContextProvider(error: GitDocumentHistoryError.unavailableVersion)
        controller.update(value)
        try await wait { controller.commitContextStatus == .unavailable }
        XCTAssertEqual(controller.selectedItem?.id, value.reviewItems[0].id)
        XCTAssertEqual(controller.baseline, value.baseline)
    }

    func testSupersededAndClearedComparisonsCannotPublishOldDescriptions() async throws {
        let provider = SuspendedContextProvider(), controller = RevisionReviewController()
        controller.contextProvider = provider
        let old = snapshot(), newer = snapshot(current: "The owner signs the final document.", revision: 2)
        controller.update(old)
        while await provider.count < 1 { await Task.yield() }
        controller.update(newer)
        while await provider.count < 2 { await Task.yield() }
        await provider.resolve(0, context: GitChangeContext(commits: [old.reviewItems[0].id: [first]]))
        await provider.resolve(1, context: GitChangeContext(commits: [newer.reviewItems[0].id: [second]]))
        try await wait { controller.commitContextStatus == .ready }
        XCTAssertNil(controller.commitContext.commits[old.reviewItems[0].id])
        XCTAssertEqual(controller.commitContext.commits[newer.reviewItems[0].id], [second])
        controller.update(snapshot(current: "The owner checks the final document.", revision: 3))
        while await provider.count < 3 { await Task.yield() }
        controller.cancelCommitContext()
        await provider.resolve(2, context: GitChangeContext(commits: [old.reviewItems[0].id: [first]]))
        await Task.yield()
        XCTAssertEqual(controller.commitContextStatus, .hidden); XCTAssertTrue(controller.commitContext.commits.isEmpty)
    }

    func testNativeGrayContextHasInlineDatesNoIDsOrSeparatorsAndExpandsBodies() async throws {
        let value = snapshot(), id = value.reviewItems[0].id
        let controller = RevisionReviewController()
        controller.contextProvider = TestContextProvider(context: GitChangeContext(commits: [id: [first, second]]))
        controller.update(value)
        let view = RevisionChangesView(controller: controller)
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 640); view.refresh()
        try await wait { controller.commitContextStatus == .ready }
        view.layoutSubtreeIfNeeded()
        let fields = labels(view.commitContextView)
        XCTAssertTrue(fields.contains { $0.stringValue.hasPrefix("Clarify review ownership — ") })
        XCTAssertTrue(fields.contains { $0.stringValue.hasPrefix("Require approval — ") })
        XCTAssertFalse(fields.contains { $0.stringValue.contains("hidden-id") })
        XCTAssertFalse(descendants(view.commitContextView).contains { $0 is NSBox })
        XCTAssertEqual(view.commitContextView.layer?.cornerRadius, 8)
        view.commitContextView.updateLayer(); XCTAssertNotNil(view.commitContextView.layer?.backgroundColor)
        view.commitContextView.appearance = NSAppearance(named: .aqua)
        view.commitContextView.updateLayer()
        let light = try XCTUnwrap(NSColor(cgColor: view.commitContextView.layer!.backgroundColor!)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(light.redComponent, 0.2); XCTAssertEqual(light.alphaComponent, 0.05, accuracy: 0.001)
        view.commitContextView.appearance = NSAppearance(named: .darkAqua)
        view.commitContextView.updateLayer()
        let dark = try XCTUnwrap(NSColor(cgColor: view.commitContextView.layer!.backgroundColor!)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(dark.redComponent, 0.8); XCTAssertEqual(dark.alphaComponent, 0.05, accuracy: 0.001)
        view.commitContextView.appearance = nil
        XCTAssertTrue(view.detailText.string.contains("Earlier")); XCTAssertTrue(view.detailText.string.contains("Current"))
        let expandedHeight = view.commitContextView.frame.height
        let toggle = try XCTUnwrap(descendants(view.commitContextView).compactMap { $0 as? NSButton }.first)
        toggle.performClick(nil)
        XCTAssertLessThan(view.commitContextView.frame.height, expandedHeight)
        toggle.performClick(nil)
        XCTAssertEqual(view.commitContextView.frame.height, expandedHeight, accuracy: 1)
        view.setFrameSize(NSSize(width: 240, height: 480)); view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.commitContextView.frame.height, expandedHeight)
        XCTAssertGreaterThan(view.detailText.frame.minY, view.commitContextView.frame.maxY)
        XCTAssertGreaterThanOrEqual(view.detailScroll.documentView!.frame.height, view.detailText.frame.maxY)
    }

    func testShortMessagesLocalEditsAndLoadingUnavailableStatesStayCompact() {
        let view = RevisionCommitContextView(frame: .zero)
        let short = GitCommitDescription(id: "never-display", subject: "", body: "", date: first.date)
        view.configure(status: .ready, commits: [short], uncommitted: true)
        let text = labels(view).map(\.stringValue).joined(separator: "\n")
        XCTAssertTrue(text.contains("Untitled commit — ")); XCTAssertTrue(text.contains("Includes uncommitted edits."))
        XCTAssertFalse(text.contains("never-display"))
        XCTAssertGreaterThan(view.contentHeight(width: 220), 0)
        view.configure(status: .ready, commits: [], uncommitted: true)
        XCTAssertTrue(labels(view).contains { $0.stringValue == "Uncommitted changes" })
        view.configure(status: .ready, commits: [], uncommitted: false)
        XCTAssertTrue(labels(view).contains { $0.stringValue == "No contributing commits found." })
        view.configure(status: .loading, commits: [], uncommitted: false)
        XCTAssertTrue(labels(view).contains { $0.stringValue.contains("Loading") })
        view.configure(status: .unavailable, commits: [], uncommitted: false)
        XCTAssertTrue(labels(view).contains { $0.stringValue.contains("unavailable") })
        view.configure(status: .hidden, commits: [], uncommitted: false)
        XCTAssertTrue(view.isHidden); XCTAssertEqual(view.contentHeight(width: 220), 0)
    }

    func testAsyncDescriptionsPreserveSelectedEarlierCurrentText() async throws {
        let value = snapshot(), provider = SuspendedContextProvider(), controller = RevisionReviewController()
        controller.contextProvider = provider; controller.update(value)
        let view = RevisionChangesView(controller: controller)
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 640); view.refresh()
        let selection = NSRange(location: 8, length: 12)
        view.detailText.setSelectedRange(selection)
        let wording = view.detailText.string
        while await provider.count < 1 { await Task.yield() }
        await provider.resolve(0, context: GitChangeContext(commits: [value.reviewItems[0].id: [first]]))
        try await wait { controller.commitContextStatus == .ready }
        XCTAssertEqual(view.detailText.selectedRange(), selection)
        XCTAssertEqual(view.detailText.string, wording)
        XCTAssertTrue(labels(view.commitContextView).contains { $0.stringValue.contains(first.subject) })
    }
}

private actor TestContextProvider: GitChangeContextProviding {
    private let value: GitChangeContext
    private let error: Error?
    private(set) var calls = 0
    init(context: GitChangeContext = GitChangeContext(), error: Error? = nil) { value = context; self.error = error }
    func context(current: MarkdownDocument, baseline: OriginalDocumentSnapshot) async throws -> GitChangeContext {
        calls += 1
        if let error { throw error }
        return value
    }
}

private actor SuspendedContextProvider: GitChangeContextProviding {
    private var continuations: [CheckedContinuation<GitChangeContext, Error>] = []
    var count: Int { continuations.count }
    func context(current: MarkdownDocument, baseline: OriginalDocumentSnapshot) async throws -> GitChangeContext {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func resolve(_ index: Int, context: GitChangeContext) { continuations[index].resume(returning: context) }
}

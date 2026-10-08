import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionReviewTests: XCTestCase {
    private func review(_ earlier: String, _ current: String) -> RevisionRenderedText {
        MarkdownRenderer().render(document: MarkdownDocument(title: "Fixture", markdown: current), original: MarkdownDocument(title: "Fixture", markdown: earlier))
    }
    private func snapshot(_ earlier: String, _ current: String, baseline: UUID = UUID(), revision: UInt64 = 1) throws -> RenderedDocumentSnapshot {
        let document = MarkdownDocument(title: "Fixture", markdown: current)
        let output = review(earlier, current)
        let pdf = try PDFExporter().render(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        return RenderedDocumentSnapshot(document: document, renderedText: output.text, pdfData: pdf.data,
            sectionDestinations: pdf.sectionDestinations, pageSetup: .letter, footers: ResolvedFooterConfiguration(), revision: revision,
            decorations: output.decorations, reviewItems: output.reviewItems, reviewDestinations: pdf.reviewDestinations,
            baseline: OriginalDocumentSnapshot(document: MarkdownDocument(sourceURL: URL(fileURLWithPath: "/tmp/original.md"), sourceModificationDate: Date(timeIntervalSince1970: 1), title: "Original", markdown: earlier), id: baseline, gitRevision: "abcdef12345"))
    }

    func testWordEditsStayInOneCompleteParagraphWithExactRanges() throws {
        let item = try XCTUnwrap(review("Pack one battery and a charger for every team.", "Pack two batteries for every team.").reviewItems.first)
        XCTAssertEqual(item.kind, .changed)
        XCTAssertEqual(item.earlier, "Pack one battery and a charger for every team.\n")
        XCTAssertEqual(item.current, "Pack two batteries for every team.\n")
        let removed = item.removedRanges.map { (item.earlier! as NSString).substring(with: $0) }.joined()
        XCTAssertTrue(removed.contains("one")); XCTAssertFalse(removed.contains("every"))
        let detail = RevisionReviewDetail.text(for: item)
        XCTAssertTrue(detail.string.contains("Earlier")); XCTAssertTrue(detail.string.contains("Current"))
        XCTAssertTrue(detail.string.contains("and a charger"))
        var strikes = 0, highlights = 0
        detail.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: detail.length)) { value, _, _ in if value != nil { strikes += 1 } }
        detail.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: detail.length)) { value, _, _ in if value != nil { highlights += 1 } }
        XCTAssertGreaterThan(strikes, 0); XCTAssertGreaterThan(highlights, 0)
    }

    func testFullRemovedParagraphsCombineAndNeverUseCalloutSummaries() throws {
        let old = "# Equipment\n\nFirst removed paragraph has several complete words.\n\nSecond removed paragraph keeps all of its wording.\n\nKeep this."
        let output = review(old, "# Equipment\n\nKeep this.")
        let item = try XCTUnwrap(output.reviewItems.first)
        XCTAssertEqual(output.reviewItems.count, 1); XCTAssertEqual(item.kind, .removed)
        XCTAssertTrue(item.earlier!.contains("First removed")); XCTAssertTrue(item.earlier!.contains("Second removed"))
        XCTAssertTrue(item.earlier!.contains("\n\n")); XCTAssertNil(item.current)
        XCTAssertTrue(output.decorations.deletions.contains { $0.label.contains("removed 2 paragraphs") })
        let detail = RevisionReviewDetail.text(for: item)
        XCTAssertTrue(detail.string.contains("This passage was removed."))
        XCTAssertNil(detail.attribute(.strikethroughStyle, at: detail.string.range(of: "First removed")!.lowerBound.utf16Offset(in: detail.string), effectiveRange: nil))
        let added = review("# Equipment", "# Equipment\n\nFirst added paragraph.\n\nSecond added paragraph.")
        XCTAssertEqual(added.reviewItems.count, 1)
        XCTAssertTrue(RevisionReviewDetail.text(for: added.reviewItems[0]).string.contains("No earlier passage—added here."))
        let quoted = review("# Quote\n\n> First removed paragraph.\n>\n> Second removed paragraph.\n\nKeep.", "# Quote\n\nKeep.")
        XCTAssertEqual(quoted.reviewItems.count, 1)
        XCTAssertTrue(quoted.reviewItems[0].earlier?.contains("Second removed") == true)
        XCTAssertTrue(quoted.reviewItems[0].metadata.contains("Quotation depth: 1"))
    }

    func testStableIDsDuplicateHeadingsMovesAndIndependentBlocks() {
        let old = "# Repeated\n\nFirst old wording.\n\n# Repeated\n\nSecond old wording."
        let new = old.replacingOccurrences(of: "old", with: "new")
        let items = review(old, new).reviewItems
        XCTAssertEqual(items.count, 2); XCTAssertNotEqual(items[0].sectionID, items[1].sectionID)
        XCTAssertEqual(items.map(\.id), review(old, new).reviewItems.map(\.id))
        XCTAssertEqual(items.map(\.id), review("Unrelated.\n\n" + old, "Unrelated.\n\n" + new).reviewItems.map(\.id))
        let moved = review("First.\n\nSecond.\n\nThird.", "Third.\n\nFirst.\n\nSecond.").reviewItems
        XCTAssertTrue(moved.contains { $0.kind == .removed }); XCTAssertTrue(moved.contains { $0.kind == .added })
        let duplicate = review("Old.\n\nOld.", "New.\n\nNew.").reviewItems
        XCTAssertEqual(Set(duplicate.map(\.id)).count, duplicate.count)
        XCTAssertTrue(review("Same.", "Same.").reviewItems.isEmpty)
        XCTAssertTrue(review("A normal sentence.", "A  normal sentence!").reviewItems.isEmpty)
    }

    func testFormattingLinksImagesTablesCodeAndUnicodeAreExplicit() throws {
        for (old, new) in [("Hello world", "**Hello** world"), ("## Heading", "### Heading"), ("[Label](https://example.com/old)", "[Label](https://example.com/new)"), ("- [ ] Task", "- [x] Task")] {
            let item = try XCTUnwrap(review(old, new).reviewItems.first)
            XCTAssertFalse(item.metadata.isEmpty)
            XCTAssertTrue(RevisionReviewDetail.text(for: item).string.contains(item.metadata[0]))
        }
        let image = try XCTUnwrap(review("![Old label](old.png)", "![New label](new.png)").reviewItems.first)
        XCTAssertTrue(image.earlier!.contains("old.png")); XCTAssertTrue(image.current!.contains("New label"))
        let removedImage = review("![Photo](missing.png)", "Text").reviewItems.first { $0.kind == .removed }
        XCTAssertTrue(removedImage?.earlier?.contains("missing.png") == true)
        let code = try XCTUnwrap(review("```\na b\n```", "```\na  b\n```").reviewItems.first)
        XCTAssertTrue(code.isCode); XCTAssertTrue(code.current!.contains("a  b"))
        let detail = RevisionReviewDetail.text(for: code)
        XCTAssertTrue((detail.attribute(.font, at: 8, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
        XCTAssertEqual(review("| A | B |\n|---|---|\n| Old | Old |", "| A | B |\n|---|---|\n| New | New |").reviewItems.count, 2)
        let centered = review("| H |\n|---|\n| Value |", "| H |\n|:---:|\n| Value |").reviewItems
        XCTAssertTrue(centered.contains { $0.metadata.joined().contains("Center") })
        XCTAssertTrue(review("1. Same item", "2. Same item").reviewItems.contains { $0.metadata.joined().contains("starting at 2") })
        let caption = review("![Photo](same.png \"Example (old)\")", "![Photo](same.png \"Example (new)\")")
        XCTAssertTrue(caption.reviewItems.contains { $0.metadata.joined().contains("Example (new)") })
        XCTAssertFalse(review("Café 東京 👩🏽‍💻", "Café 東京 👩🏽‍🚀").reviewItems.isEmpty)
    }

    func testTableReviewNeverPairsRemovedCellsWithAnotherSectionOrTableGap() {
        let earlier = "## First\n\n| Item |\n|---|\n| Obsolete |\n\n## Second\n\n| Item |\n|---|\n| Previous |"
        let current = "## First\n\n## Second\n\n| Item |\n|---|\n| Revised |"
        let items = review(earlier, current).reviewItems
        XCTAssertFalse(items.contains { $0.earlier?.contains("Obsolete") == true && $0.current?.contains("Revised") == true })
        XCTAssertTrue(items.contains { $0.kind == .removed && $0.earlier?.contains("Obsolete") == true })
        let old = "# Tables\n\n| Item |\n|---|\n| Obsolete |\n\nUnchanged separator.\n\n| Item |\n|---|\n| Previous |"
        let new = "# Tables\n\nUnchanged separator.\n\n| Item |\n|---|\n| Revised |"
        XCTAssertFalse(review(old, new).reviewItems.contains { $0.earlier?.contains("Obsolete") == true && $0.current?.contains("Revised") == true })
    }

    func testPDFDestinationsBodyGeometryAndAsyncOutput() async throws {
        let long = (0..<350).map { "Sentence \($0) has ordinary searchable words. " }.joined()
        let output = review("# Title\n\n" + long, "# Title\n\n" + long + "New ending.")
        let exporter = PDFExporter()
        let rendered = try exporter.render(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        let withoutMetadata = try exporter.render(from: output.text, decorations: output.decorations)
        let pdf = try XCTUnwrap(PDFDocument(data: rendered.data)), plain = try XCTUnwrap(PDFDocument(data: withoutMetadata.data))
        XCTAssertEqual(pdf.pageCount, plain.pageCount); XCTAssertEqual(pdf.string, plain.string)
        let destination = try XCTUnwrap(rendered.reviewDestinations[output.reviewItems[0].id])
        XCTAssertGreaterThan(destination.lastPageIndex, destination.destination.pageIndex)
        XCTAssertTrue(destination.pageLabel.hasPrefix("pp."))
        let async = try await exporter.renderAsync(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        XCTAssertEqual(async.reviewDestinations, rendered.reviewDestinations)
        for pair in [("All removed.", ""), ("Keep final removed text", "Keep")] {
            let value = review(pair.0, pair.1)
            let data = try exporter.render(from: value.text, decorations: value.decorations, reviewItems: value.reviewItems)
            XCTAssertEqual(data.reviewDestinations.count, value.reviewItems.count)
            XCTAssertEqual(data.reviewDestinations.values.first?.destination.pageIndex, 0)
            XCTAssertEqual(data.reviewDestinations.values.first?.pageLabel, "p. 1")
        }
    }

    func testControllerRevealNavigationRefreshRestorationAndClear() throws {
        let id = UUID(), controller = RevisionReviewController()
        let first = try snapshot("# Title\n\nOld one.\n\nOld two.", "# Title\n\nNew one.\n\nNew two.", baseline: id)
        var navigations: [(String, UInt64)] = []
        controller.navigate = { item, revision, _ in navigations.append((item, revision)) }
        controller.update(first)
        XCTAssertEqual(controller.state.mode, .changes); XCTAssertTrue(controller.state.isVisible)
        XCTAssertEqual(controller.selectedIndex, 0); XCTAssertTrue(navigations.isEmpty)
        XCTAssertTrue(controller.baselineLabel.contains("abcdef12"))
        XCTAssertFalse(controller.canPrevious); XCTAssertTrue(controller.canNext)
        controller.previous(); controller.select("unknown"); XCTAssertTrue(navigations.isEmpty)
        controller.state.collapsedGroups.insert(first.reviewItems[1].sectionID)
        controller.next(); XCTAssertEqual(controller.selectedIndex, 1); XCTAssertTrue(controller.state.collapsedGroups.isEmpty)
        controller.next(); XCTAssertEqual(navigations.count, 1)
        controller.previous(); XCTAssertEqual(controller.selectedIndex, 0)
        controller.state.isVisible = false; controller.state.mode = .pages; controller.state.detailOffset = 45
        controller.update(try snapshot("# Title\n\nOld one.\n\nOld two.", "# Title\n\nNew one.\n\nNew two.", baseline: id, revision: 2))
        XCTAssertFalse(controller.state.isVisible); XCTAssertEqual(controller.state.mode, .pages); XCTAssertEqual(controller.state.detailOffset, 45)
        controller.update(try snapshot("# Title\n\nOld one.\n\nOld two.", "# Title\n\nOld one.\n\nNew two.", baseline: id, revision: 3))
        XCTAssertEqual(controller.items.count, 1); XCTAssertEqual(controller.state.detailOffset, 0)
        var saved = controller.state; saved.mode = .changes; saved.detailOffset = 32
        let restored = RevisionReviewController(); restored.restore(saved); restored.update(first)
        XCTAssertFalse(restored.state.isVisible); XCTAssertEqual(restored.state.detailOffset, 32)
        var ordinary = first; ordinary.baseline = nil; ordinary.reviewItems = []
        restored.update(ordinary); XCTAssertEqual(restored.state.mode, .pages)
        XCTAssertEqual(restored.baselineLabel, ""); XCTAssertFalse(restored.canNext)
        XCTAssertEqual(restored.selectionLabel, "No meaningful document changes")
        var noDate = first; noDate.baseline = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Fixture", markdown: "Old"))
        controller.update(noDate); XCTAssertFalse(controller.baselineLabel.isEmpty)
    }

    func testPersistenceValidationAndLegacyWindowState() {
        var state = PersistedDocumentSidebar(); state.mode = .changes; state.isVisible = true
        state.selectedID = "selected"; state.collapsedGroups = ["group"]; state.changesWidth = 410
        XCTAssertEqual(PersistedDocumentSidebar(propertyList: state.propertyList), state)
        var values = state.propertyList; values["changesWidth"] = Double.infinity
        XCTAssertNil(PersistedDocumentSidebar(propertyList: values))
        values = state.propertyList; values["mode"] = "outline"; XCTAssertNil(PersistedDocumentSidebar(propertyList: values))
        values = state.propertyList; values["pagesWidth"] = 999.0; values["changesWidth"] = 10.0
        values["listProportion"] = 99.0; values["listOffset"] = -1.0; values["detailOffset"] = -2.0
        let clamped = PersistedDocumentSidebar(propertyList: values)
        XCTAssertEqual(clamped?.pagesWidth, 260); XCTAssertEqual(clamped?.changesWidth, 240)
        XCTAssertEqual(clamped?.listProportion, 0.9); XCTAssertEqual(clamped?.listOffset, 0)
    }

    func testNativeSidebarSizingModesAndIndependentDetail() async throws {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 760, height: 800))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container
        let sidebar = PDFSidebarController(); container.attach(sidebarController: sidebar)
        let first = try snapshot("# Title\n\nOld one.\n\nOld two.", "# Title\n\nNew one.\n\nNew two.")
        container.previewView.display(try XCTUnwrap(PDFDocument(data: first.pdfData)), data: first.pdfData, revision: first.revision)
        container.updateReview(first); container.layoutSubtreeIfNeeded()
        XCTAssertTrue(container.isThumbnailSidebarVisible); XCTAssertEqual(container.sidebarMode, .changes)
        XCTAssertFalse((container.subviews.first as? NSSplitView)?.subviews.first?.isHidden ?? true)
        XCTAssertEqual(sidebar.commandTitle, "Hide Sidebar")
        XCTAssertEqual(container.captureSidebarRestorationState().changesWidth, 340)
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        try await Task.sleep(nanoseconds: 100_000_000)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.subviews[0].frame.width, 340, accuracy: 1)
        split.setPosition(410, ofDividerAt: 0)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.captureSidebarRestorationState().changesWidth, 410)
        container.setSidebarMode(.pages); XCTAssertEqual(container.thumbnailSidebarWidth, 168)
        container.setSidebarMode(.changes)
        container.setFrameSize(NSSize(width: 408, height: 560)); container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.captureSidebarRestorationState().changesWidth, 410)
        XCTAssertGreaterThanOrEqual(container.previewView.frame.width, 160)
        var saved = container.captureSidebarRestorationState(); saved.isVisible = false
        let restored = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 760, height: 800))
        restored.restoreSidebarRestorationState(saved); restored.updateReview(first)
        XCTAssertFalse(restored.isThumbnailSidebarVisible); XCTAssertEqual(restored.sidebarMode, .changes)
        var ordinary = try snapshot("Same", "Same", revision: 2); ordinary.baseline = nil; ordinary.reviewItems = []
        restored.updateReview(ordinary); restored.setSidebarMode(.changes)
        XCTAssertEqual(restored.sidebarMode, .pages)
        container.updateReview(first) // Same committed revision is inert.
        container.prepareForDismantling(); restored.prepareForDismantling()
    }

    func testWindowResizingPreservesVisibleSidebarInBothModes() async throws {
        let container = PDFPreviewContainerView(frame: NSRect(x: 0, y: 0, width: 760, height: 800))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container
        let controller = PDFSidebarController(); container.attach(sidebarController: controller)
        let comparison = try snapshot("# Title\n\nEarlier passage.", "# Title\n\nCurrent passage.")
        container.updateReview(comparison)
        container.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        split.setPosition(410, ofDividerAt: 0)
        container.setThumbnailSidebarWidth(260)

        for mode in [DocumentSidebarMode.changes, .pages, .changes] {
            container.setSidebarMode(mode)
            for size in [NSSize(width: 1050, height: 850), NSSize(width: 408, height: 540), NSSize(width: 760, height: 800)] {
                window.setContentSize(size)
                // Allow AppKit's deferred split-view layout after the container has laid out.
                container.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 30_000_000)
                XCTAssertTrue(container.isThumbnailSidebarVisible)
                XCTAssertTrue(controller.isVisible)
                XCTAssertFalse(split.subviews[0].isHidden)
                let preferredWidth: CGFloat = mode == .pages ? 260 : 410
                let expectedWidth = min(preferredWidth, size.width - split.dividerThickness - 160)
                XCTAssertEqual(split.subviews[0].frame.width, expectedWidth, accuracy: 1)
                XCTAssertGreaterThanOrEqual(container.previewView.frame.width, 160)
                let saved = container.captureSidebarRestorationState()
                XCTAssertEqual(saved.mode, mode)
                XCTAssertEqual(saved.pagesWidth, 260, accuracy: 1)
                XCTAssertEqual(saved.changesWidth, 410, accuracy: 1)
            }
        }
        container.setThumbnailSidebarVisible(false)
        window.setContentSize(NSSize(width: 900, height: 700))
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(container.isThumbnailSidebarVisible)
        XCTAssertTrue(split.subviews[0].isHidden)
        XCTAssertEqual(container.previewView.frame.width, container.bounds.width, accuracy: 1)
        container.prepareForDismantling()
    }

    func testCommittedReviewIsAtomicAndPreviewNavigationWaitsForActiveRevision() async throws {
        let session = DocumentSession()
        let current = "# Review\n\n" + (0..<160).map { "Current paragraph \($0) has ordinary useful wording." }.joined(separator: "\n\n")
        try session.apply(MarkdownDocument(title: "Review", markdown: current))
        let first = try XCTUnwrap(session.renderedSnapshot)
        XCTAssertNil(first.baseline); XCTAssertTrue(first.reviewItems.isEmpty)
        let baseline = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Original", markdown: current.replacingOccurrences(of: "Current", with: "Earlier")))
        let comparison = Task { try await session.setOriginalSnapshot(baseline) }
        while !session.isPreparingDocument { await Task.yield() }
        XCTAssertNil(session.renderedSnapshot?.baseline)
        try await comparison.value
        let committed = try XCTUnwrap(session.renderedSnapshot)
        XCTAssertEqual(committed.baseline, baseline)
        XCTAssertEqual(committed.reviewItems.count, committed.reviewDestinations.count)
        XCTAssertFalse(committed.reviewItems.isEmpty)
        let preview = BufferedPDFPreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        preview.stagingDelay = 0
        preview.display(try XCTUnwrap(PDFDocument(data: first.pdfData)), data: first.pdfData, revision: first.revision)
        let target = PDFSectionDestination(pageIndex: 2, point: CGPoint(x: 54, y: 700))
        preview.navigateReview(id: "later", revision: committed.revision, destination: target)
        XCTAssertEqual(preview.activeView.document?.index(for: try XCTUnwrap(preview.activeView.currentPage)), 0)
        preview.display(try XCTUnwrap(PDFDocument(data: committed.pdfData)), data: committed.pdfData, revision: committed.revision)
        for _ in 0..<100 where preview.activeRevision != committed.revision { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(preview.activeView.document?.index(for: try XCTUnwrap(preview.activeView.currentPage)), 2)
        preview.navigateReview(id: "invalid", revision: committed.revision, destination: PDFSectionDestination(pageIndex: 999, point: .zero))
        try await session.setOriginalSnapshot(nil)
        XCTAssertNil(session.renderedSnapshot?.baseline); XCTAssertTrue(session.renderedSnapshot?.reviewItems.isEmpty == true)
        preview.prepareForDismantling()
    }

    func testSidebarWorkspaceRoundTripThroughDefaultsAndLegacyRecords() throws {
        let suite = "RevisionReview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let restoration = OpenDocumentRestorationController(defaults: defaults)
        var sidebar = PersistedDocumentSidebar(); sidebar.mode = .changes; sidebar.isVisible = true
        sidebar.pagesWidth = 210; sidebar.changesWidth = 420; sidebar.listProportion = 0.4
        sidebar.selectedID = "selected"; sidebar.collapsedGroups = ["heading:equipment"]
        sidebar.listOffset = 100; sidebar.detailOffset = 150
        let url = URL(fileURLWithPath: "/tmp/sidebar-workspace.md")
        let state = DocumentWindowRestorationState(frame: nil, viewport: nil,
            thumbnails: PersistedThumbnailSidebar(isVisible: true, width: 210, scrollOffset: 32), sidebar: sidebar)
        let workspace = WorkspaceSnapshot(groups: [WorkspaceWindowGroup(identifier: "review", tabs: [.document(url, state: state)], selectedTabIndex: 0, isTabBarVisible: false)])
        restoration.workspaceCaptureProvider = { workspace }; restoration.captureLastSession()
        XCTAssertEqual(OpenDocumentRestorationController(defaults: defaults).lastSessionWorkspace(), workspace)
        let legacy = DocumentWindowRestorationState(frame: nil, viewport: nil, thumbnails: state.thumbnails)
        restoration.workspaceCaptureProvider = { WorkspaceSnapshot(groups: [WorkspaceWindowGroup(identifier: "legacy", tabs: [.document(url, state: legacy)], selectedTabIndex: 0, isTabBarVisible: false)]) }
        restoration.captureLastSession()
        XCTAssertNil(restoration.lastSessionWorkspace()?.groups.first?.tabs.first?.windowState?.sidebar)
        XCTAssertEqual(restoration.lastSessionWorkspace()?.groups.first?.tabs.first?.windowState?.thumbnails, state.thumbnails)
    }

    func testComparisonBeforeWindowAttachmentKeepsActualPaneAndDefaultDivider() async throws {
        let container = PDFPreviewContainerView(frame: .zero)
        let data = try snapshot("Earlier wording in this paragraph.", "Current wording in this paragraph.")
        container.updateReview(data)
        container.previewView.display(try XCTUnwrap(PDFDocument(data: data.pdfData)), data: data.pdfData, revision: data.revision)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container; container.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        container.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        XCTAssertEqual(split.subviews[0].frame.width, 340, accuracy: 1)
        XCTAssertGreaterThanOrEqual(split.subviews[1].frame.width, 160)
        XCTAssertFalse(split.subviews[0].isHidden)
        let view = try XCTUnwrap(split.subviews[0].subviews.compactMap { $0 as? RevisionChangesView }.first)
        XCTAssertGreaterThan(view.outline.numberOfRows, 0)
        XCTAssertEqual(container.captureSidebarRestorationState().listProportion, 0.55, accuracy: 0.01)
        XCTAssertEqual(view.listScroll.frame.height / view.split.bounds.height, 0.55, accuracy: 0.01)
        XCTAssertGreaterThan(view.detailScroll.frame.height, 0)
        container.prepareForDismantling()
    }

    func testOrdinaryPreviewPreparationDoesNotChangeLaterComparisonDivider() async throws {
        let container = PDFPreviewContainerView(frame: .zero)
        let data = try snapshot("Earlier paragraph.", "Current paragraph.", revision: 2)
        var ordinary = data; ordinary.baseline = nil; ordinary.reviewItems = []
        container.updateReview(ordinary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container; container.layoutSubtreeIfNeeded()
        var comparison = data
        comparison = RenderedDocumentSnapshot(document: data.document, renderedText: data.renderedText, pdfData: data.pdfData,
            pageSetup: data.pageSetup, footers: data.footers, revision: 3, decorations: data.decorations,
            reviewItems: data.reviewItems, reviewDestinations: data.reviewDestinations, baseline: data.baseline)
        container.updateReview(comparison); container.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        container.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        let view = try XCTUnwrap(split.subviews[0].subviews.compactMap { $0 as? RevisionChangesView }.first)
        XCTAssertEqual(view.listScroll.frame.height / view.split.bounds.height, 0.55, accuracy: 0.01)
        XCTAssertEqual(container.captureSidebarRestorationState().listProportion, 0.55, accuracy: 0.01)
        container.prepareForDismantling()
    }

    func testNativeOutlineSelectionCollapseDetailsAndThousandEntries() throws {
        let old = (0..<1_000).map { "Paragraph \($0) contains old words." }.joined(separator: "\n\n")
        let new = old.replacingOccurrences(of: "old", with: "new")
        let output = review(old, new)
        XCTAssertEqual(output.reviewItems.count, 1_000)
        let controller = RevisionReviewController()
        var snapshot = try self.snapshot("Old", "New")
        snapshot.reviewItems = output.reviewItems
        snapshot.reviewDestinations = [:]
        controller.update(snapshot)
        let view = RevisionChangesView(controller: controller)
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 760); view.refresh(); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.outline.numberOfRows, 1_001)
        let group = view.outline.item(atRow: 0)!
        XCTAssertFalse(view.outlineView(view.outline, shouldSelectItem: group))
        XCTAssertTrue(view.outlineView(view.outline, isItemExpandable: group))
        XCTAssertNotNil(view.outlineView(view.outline, viewFor: nil, item: group))
        let entry = view.outline.item(atRow: 1)!
        XCTAssertNotNil(view.outlineView(view.outline, viewFor: nil, item: entry))
        view.outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        view.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification))
        XCTAssertEqual(controller.selectedIndex, 1)
        view.outline.collapseItem(group)
        view.outlineViewItemDidCollapse(Notification(name: NSOutlineView.itemDidCollapseNotification, userInfo: ["NSObject": group]))
        XCTAssertFalse(controller.state.collapsedGroups.isEmpty)
        controller.next(); view.refresh(); XCTAssertEqual(controller.selectedIndex, 2)
        view.outlineViewItemDidExpand(Notification(name: NSOutlineView.itemDidExpandNotification, userInfo: ["NSObject": group]))
        XCTAssertTrue(controller.state.collapsedGroups.isEmpty)
        XCTAssertGreaterThanOrEqual(view.listHeight, 120)
        XCTAssertEqual(view.splitView(view.split, constrainSplitPosition: 0, ofSubviewAt: 0), 120)
        XCTAssertGreaterThan(view.splitView(view.split, effectiveRect: .zero, forDrawnRect: .zero, ofDividerAt: 0).height, 0)
        view.captureScrollPositions(); view.splitViewDidResizeSubviews(Notification(name: NSSplitView.didResizeSubviewsNotification))
        controller.update(try self.snapshot("Same", "Same")); view.refresh()
        XCTAssertTrue(view.detailText.string.contains("No meaningful"))
    }
}

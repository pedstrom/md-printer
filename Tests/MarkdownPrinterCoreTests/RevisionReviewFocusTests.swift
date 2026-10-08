import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionReviewFocusTests: XCTestCase {
    private func render(_ old: String, _ new: String, configuration: RendererConfiguration = .init()) throws -> (RevisionRenderedText, PDFRenderResult) {
        let output = MarkdownRenderer(configuration: configuration).render(
            document: MarkdownDocument(title: "Review fixture", markdown: new),
            original: MarkdownDocument(title: "Review fixture", markdown: old))
        let pdf = try PDFExporter(configuration: configuration).render(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        return (output, pdf)
    }

    private func keyboardSnapshot(revision: UInt64 = 1, baseline: OriginalDocumentSnapshot? = nil) throws -> RenderedDocumentSnapshot {
        let old = "# First\n\nOld first.\n\n# Second\n\nOld second."
        let new = old.replacingOccurrences(of: "Old", with: "New")
        let (output, pdf) = try render(old, new)
        return RenderedDocumentSnapshot(document: MarkdownDocument(title: "Sample", markdown: new), renderedText: output.text,
            pdfData: pdf.data, sectionDestinations: pdf.sectionDestinations, pageSetup: .letter, footers: .init(), revision: revision,
            decorations: output.decorations, reviewItems: output.reviewItems, reviewDestinations: pdf.reviewDestinations,
            baseline: baseline ?? OriginalDocumentSnapshot(document: MarkdownDocument(title: "Original", markdown: old)))
    }

    private func changes(in container: PDFPreviewContainerView) throws -> RevisionChangesView {
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        return try XCTUnwrap(split.subviews[0].subviews.compactMap { $0 as? RevisionChangesView }.first)
    }

    private func arrow(_ code: UInt16, in window: NSWindow) throws -> NSEvent {
        let character = String(UnicodeScalar([123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700][Int(code)]!)!)
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }

    func testComparisonRevealFocusesSelectedRowForImmediateWindowArrowEvents() async throws {
        let snapshot = try keyboardSnapshot()
        let container = PDFPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 900, height: 750))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { container.prepareForDismantling(); window.orderOut(nil) }
        container.previewView.display(try XCTUnwrap(PDFDocument(data: snapshot.pdfData)), data: snapshot.pdfData, revision: snapshot.revision)
        container.layoutSubtreeIfNeeded()
        window.makeFirstResponder(container.previewView.activeView)
        let before = container.previewView.capturePersistedViewport()
        var navigations = 0
        let navigate = container.reviewController.navigate
        container.reviewController.navigate = { id, revision, destination in
            navigations += 1; navigate(id, revision, destination)
        }
        container.updateReview(snapshot)
        let view = try changes(in: container)
        XCTAssertTrue(window.firstResponder === view.outline)
        XCTAssertEqual((view.outline.item(atRow: view.outline.selectedRow) as? RevisionChangesView.Entry)?.value.id, snapshot.reviewItems[0].id)
        // Keep the initial comparison reveal free of PDF navigation.
        XCTAssertEqual(container.reviewController.selectedIndex, 0)
        XCTAssertEqual(navigations, 0)
        XCTAssertEqual(container.previewView.capturePersistedViewport()?.pageIndex, before?.pageIndex)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(window.firstResponder === view.outline, "Delayed PDF focus must not replace the Changes row focus")
        window.sendEvent(try arrow(125, in: window))
        XCTAssertEqual(container.reviewController.selectedIndex, 1)
        window.sendEvent(try arrow(123, in: window))
        XCTAssertEqual(container.reviewController.selectedIndex, 0)
    }

    func testReopeningChangesFocusesRememberedRowWhileRefreshPreservesReadingFocus() async throws {
        let snapshot = try keyboardSnapshot()
        let container = PDFPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 900, height: 750))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container
        defer { container.prepareForDismantling(); window.orderOut(nil) }
        container.previewView.display(try XCTUnwrap(PDFDocument(data: snapshot.pdfData)), data: snapshot.pdfData, revision: 1)
        container.updateReview(snapshot); container.layoutSubtreeIfNeeded()
        let view = try changes(in: container)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.makeFirstResponder(view.detailText)
        let refresh = try keyboardSnapshot(revision: 2, baseline: snapshot.baseline)
        container.previewView.display(try XCTUnwrap(PDFDocument(data: refresh.pdfData)), data: refresh.pdfData, revision: 2)
        container.updateReview(refresh)
        XCTAssertTrue(window.firstResponder === view.detailText)
        window.sendEvent(try arrow(124, in: window))
        XCTAssertEqual(container.reviewController.selectedIndex, 1)
        container.setThumbnailSidebarVisible(false)
        XCTAssertTrue(window.firstResponder === container.previewView.activeView)
        container.setThumbnailSidebarVisible(true)
        XCTAssertTrue(window.firstResponder === view.outline)
        XCTAssertEqual(container.reviewController.selectedIndex, 1)
        container.setSidebarMode(.pages)
        XCTAssertTrue(window.firstResponder === container.previewView.activeView)
        container.setSidebarMode(.changes)
        XCTAssertTrue(window.firstResponder === view.outline)
        window.makeFirstResponder(container.previewView.activeView)
        container.updateReview(try keyboardSnapshot(revision: 3, baseline: snapshot.baseline))
        XCTAssertTrue(window.firstResponder === container.previewView.activeView)
    }

    func testRestoredSelectionGainsFocusAfterWindowAttachmentAndKeepsOtherGroupsCollapsed() async throws {
        let snapshot = try keyboardSnapshot()
        let container = PDFPreviewContainerView(frame: .zero)
        var state = PersistedDocumentSidebar(); state.mode = .changes; state.isVisible = true
        state.selectedID = snapshot.reviewItems[1].id
        state.collapsedGroups = Set(snapshot.reviewItems.map(\.sectionID))
        container.restoreSidebarRestorationState(state)
        container.updateReview(snapshot)
        container.previewView.display(try XCTUnwrap(PDFDocument(data: snapshot.pdfData)), data: snapshot.pdfData, revision: 1)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 750), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container; container.layoutSubtreeIfNeeded()
        defer { container.prepareForDismantling(); window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let view = try changes(in: container)
        XCTAssertTrue(window.firstResponder === view.outline)
        XCTAssertEqual(container.reviewController.selectedIndex, 1)
        XCTAssertEqual(container.reviewController.state.collapsedGroups, [snapshot.reviewItems[0].sectionID])
        window.sendEvent(try arrow(126, in: window))
        XCTAssertEqual(container.reviewController.selectedIndex, 0)
        let other = PDFPreviewContainerView(frame: container.frame)
        let otherWindow = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.contentView = other
        other.updateReview(snapshot)
        XCTAssertTrue(window.firstResponder === view.outline)
        XCTAssertTrue(otherWindow.firstResponder === (try changes(in: other)).outline)
        other.prepareForDismantling(); otherWindow.orderOut(nil)
    }

    func testPendingSelectionFocusWaitsForComparisonSheetAndCancelsWhenHidden() async throws {
        let snapshot = try keyboardSnapshot()
        let container = PDFPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 900, height: 750))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        defer { container.prepareForDismantling(); window.orderOut(nil) }
        container.previewView.display(try XCTUnwrap(PDFDocument(data: snapshot.pdfData)), data: snapshot.pdfData, revision: 1)
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        container.updateReview(snapshot)
        let view = try changes(in: container)
        XCTAssertFalse(window.firstResponder === view.outline)
        window.endSheet(sheet); sheet.orderOut(nil)
        for _ in 0..<100 where window.firstResponder !== view.outline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(window.firstResponder === view.outline)
        window.beginSheet(sheet, completionHandler: nil)
        container.setThumbnailSidebarVisible(false); container.setThumbnailSidebarVisible(true)
        container.setThumbnailSidebarVisible(false)
        window.endSheet(sheet); sheet.orderOut(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(window.firstResponder === view.outline)
    }

    func testAdaptivePlacementKeepsContextAndAvoidsUnnecessaryScrolling() throws {
        let viewport = CGRect(x: 0, y: 100, width: 600, height: 800)
        func passage(_ y: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: 54, y: y, width: 504, height: height) }
        XCTAssertEqual(RevisionReviewScrollPlacement.targetTop(passage: passage(1200, 100), viewport: viewport), 1000)
        XCTAssertEqual(RevisionReviewScrollPlacement.targetTop(passage: passage(1200, 650), viewport: viewport), 1080)
        XCTAssertNil(RevisionReviewScrollPlacement.targetTop(passage: passage(300, 100), viewport: viewport))
        XCTAssertNil(RevisionReviewScrollPlacement.targetTop(passage: passage(250, 1100), viewport: viewport))
        XCTAssertEqual(RevisionReviewScrollPlacement.targetTop(passage: passage(105, 100), viewport: viewport), -95)
        XCTAssertNotNil(RevisionReviewScrollPlacement.targetTop(passage: passage(700, 100), viewport: viewport))
        XCTAssertNil(RevisionReviewScrollPlacement.targetTop(passage: passage(100, 100), viewport: .zero))
    }

    func testCompletePassageGeometryAndPageFragmentsPreservePDF() async throws {
        let passage = (0..<350).map { "Sentence \($0) contains searchable sample wording. " }.joined()
        let (output, pdf) = try render("# Context\n\n" + passage, "# Context\n\n" + passage + "A revised ending.")
        let destination = try XCTUnwrap(pdf.reviewDestinations[output.reviewItems[0].id])
        XCTAssertGreaterThan(destination.fragments.count, 1)
        XCTAssertEqual(destination.fragments.map(\.pageIndex), Array(destination.destination.pageIndex...destination.lastPageIndex))
        for fragment in destination.fragments {
            XCTAssertGreaterThan(fragment.passageBounds.height, 0)
            XCTAssertEqual(fragment.bandBounds.minX, 27, accuracy: 0.01)
            XCTAssertEqual(fragment.bandBounds.maxX, 585, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(fragment.bandBounds.minY, 50)
            XCTAssertLessThanOrEqual(fragment.bandBounds.maxY, 742)
            XCTAssertTrue(fragment.bandBounds.contains(fragment.passageBounds))
        }
        let exporter = PDFExporter()
        let plain = try XCTUnwrap(PDFDocument(data: exporter.render(from: output.text, decorations: output.decorations).data))
        let marked = try XCTUnwrap(PDFDocument(data: pdf.data))
        XCTAssertEqual(marked.pageCount, plain.pageCount); XCTAssertEqual(marked.string, plain.string)
        for word in ["Sentence 0", "Sentence 180", "revised ending"] {
            let a = try XCTUnwrap(plain.findString(word, withOptions: []).first)
            let b = try XCTUnwrap(marked.findString(word, withOptions: []).first)
            XCTAssertEqual(a.bounds(for: try XCTUnwrap(a.pages.first)), b.bounds(for: try XCTUnwrap(b.pages.first)))
        }
        let async = try await exporter.renderAsync(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        XCTAssertEqual(async.reviewDestinations, pdf.reviewDestinations)
    }

    func testRemovalGeometryIncludesDisplacedMarginNoteAndEmptyDocumentBoundary() throws {
        // Dense lines leave no internal gap; a generous margin holds the removal note.
        let configuration = RendererConfiguration(pageSize: CGSize(width: 400, height: 330),
            pageMargins: NSEdgeInsets(top: 40, left: 70, bottom: 40, right: 70))
        let prose = (0..<450).map { "Word\($0)" }.joined(separator: " ")
        let (output, _) = try render(prose.replacingOccurrences(of: "Word10 ", with: "Word10 previous detail "), prose, configuration: configuration)
        let text = NSMutableAttributedString(attributedString: output.text)
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineSpacing = 0; style.paragraphSpacing = 0
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
        let exporter = PDFExporter(configuration: configuration)
        let pdf = try exporter.render(from: text, decorations: output.decorations, reviewItems: output.reviewItems)
        let notes = try exporter.revisionNoteLayout(from: text, decorations: output.decorations)
        let destination = try XCTUnwrap(pdf.reviewDestinations[output.reviewItems[0].id])
        let note = try XCTUnwrap(notes.first)
        let actual = try XCTUnwrap(destination.fragments.first { $0.pageIndex == note.page })
        XCTAssertTrue(actual.bandBounds.contains(CGRect(x: note.frame.minX, y: configuration.pageSize.height - note.frame.maxY,
                                                       width: note.frame.width, height: note.frame.height)))
        let margin = RevisionPDFNote(page: 0, anchor: note.anchor,
            frame: CGRect(x: 334, y: 64, width: 60, height: 30), label: "previous detail", isMargin: true,
            leader: [note.anchor, CGPoint(x: 334, y: 74)])
        let fragment = PDFReviewFragmentLayout.fragment(pageIndex: 0,
            passage: CGRect(x: 70, y: 40, width: 260, height: 200), configuration: configuration, notes: [margin])
        let pdfNote = CGRect(x: margin.frame.minX, y: configuration.pageSize.height - margin.frame.maxY,
                             width: margin.frame.width, height: margin.frame.height)
        XCTAssertTrue(fragment.bandBounds.contains(pdfNote))
        XCTAssertTrue(fragment.bandBounds.minX < 35 || fragment.bandBounds.maxX > 365)
        for (old, new) in [("All removed.", ""), ("Kept.\n\nTrailing paragraph removed.", "Kept.")] {
            let (output, pdf) = try render(old, new)
            let item = try XCTUnwrap(output.reviewItems.first { $0.kind == .removed })
            let destination = try XCTUnwrap(pdf.reviewDestinations[item.id])
            XCTAssertEqual(destination.fragments.count, 1)
            XCTAssertGreaterThan(destination.fragments[0].bandBounds.height, 0)
            XCTAssertEqual(destination.fragments[0].pageIndex, destination.destination.pageIndex)
        }
    }

    func testNativeNavigationPlacesPassageAndRetainsVisibleSelectionPosition() async throws {
        let text = (0..<90).map { "Paragraph \($0). " + String(repeating: "Useful contextual wording. ", count: 5) }.joined(separator: "\n\n")
        let (_, pdf) = try render(text, text.replacingOccurrences(of: "Paragraph 40", with: "Revised paragraph 40"))
        let destination = try XCTUnwrap(pdf.reviewDestinations.values.first)
        let view = PageAdvancingPDFView(frame: CGRect(x: 0, y: 0, width: 650, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.displayInitial(try XCTUnwrap(PDFDocument(data: pdf.data)))
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        view.prepareForSectionNavigation()
        RevisionReviewScrollPlacement.navigate(to: destination, in: view)
        let documentView = try XCTUnwrap(view.documentView)
        let clip = try XCTUnwrap(documentView.enclosingScrollView?.contentView)
        let page = try XCTUnwrap(view.document?.page(at: destination.destination.pageIndex))
        let rect = documentView.convert(view.convert(destination.fragments[0].passageBounds, from: page), from: view)
        let distance = documentView.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
        XCTAssertEqual(distance / clip.bounds.height, 0.25, accuracy: 0.025)
        let offset = clip.bounds.origin
        RevisionReviewScrollPlacement.navigate(to: destination, in: view)
        XCTAssertEqual(clip.bounds.origin, offset)
        view.scaleFactor *= 1.3; view.layoutSubtreeIfNeeded()
        RevisionReviewScrollPlacement.navigate(to: destination, in: view)
        XCTAssertGreaterThanOrEqual(clip.bounds.minY, documentView.bounds.minY)
        let invalid = PDFReviewDestination(destination: PDFSectionDestination(pageIndex: 999, point: .zero), lastPageIndex: 999)
        RevisionReviewScrollPlacement.navigate(to: invalid, in: view)
    }

    func testFocusFollowsSelectionRefreshModesAndBufferedRevisionWithoutChangingPDF() async throws {
        let old = "# Sample\n\nOld first.\n\nOld second."
        let new = "# Sample\n\nNew first.\n\nNew second."
        let (output, pdf) = try render(old, new)
        let baseline = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Original", markdown: old))
        func snapshot(_ revision: UInt64) -> RenderedDocumentSnapshot {
            RenderedDocumentSnapshot(document: MarkdownDocument(title: "Sample", markdown: new), renderedText: output.text,
                pdfData: pdf.data, sectionDestinations: pdf.sectionDestinations, pageSetup: .letter,
                footers: .init(), revision: revision, decorations: output.decorations, reviewItems: output.reviewItems,
                reviewDestinations: pdf.reviewDestinations, baseline: baseline)
        }
        let container = PDFPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 900, height: 750))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.orderOut(nil) }
        let preview = container.previewView
        preview.display(try XCTUnwrap(PDFDocument(data: pdf.data)), data: pdf.data, revision: 1)
        container.updateReview(snapshot(1)); container.layoutSubtreeIfNeeded()
        let originalData = preview.activeData
        let originalAnnotations = preview.activeView.document?.page(at: 0)?.annotations
        XCTAssertEqual(preview.activeView.reviewFocusProvider.focus?.number, 1)
        container.reviewController.next()
        XCTAssertEqual(preview.activeView.reviewFocusProvider.focus?.number, 2)
        XCTAssertEqual(preview.activeData, originalData)
        XCTAssertEqual(preview.activeView.document?.page(at: 0)?.annotations, originalAnnotations)
        container.setSidebarMode(.pages); XCTAssertNil(preview.activeView.reviewFocusProvider.focus)
        container.setSidebarMode(.changes); XCTAssertEqual(preview.activeView.reviewFocusProvider.focus?.number, 2)
        let selection = container.reviewController.state.selectedID
        container.setThumbnailSidebarVisible(false)
        XCTAssertNil(preview.activeView.reviewFocusProvider.focus)
        XCTAssertEqual(container.reviewController.state.selectedID, selection)
        // Metadata arriving first must wait for the identical-data revision handoff too.
        container.updateReview(snapshot(2))
        XCTAssertEqual(preview.activeRevision, 1)
        preview.display(try XCTUnwrap(PDFDocument(data: pdf.data)), data: pdf.data, revision: 2)
        XCTAssertNil(preview.activeView.reviewFocusProvider.focus)
        container.setThumbnailSidebarVisible(true)
        XCTAssertEqual(preview.activeView.reviewFocusProvider.focus?.number, 2)
        var cleared = snapshot(3); cleared.baseline = nil; cleared.reviewItems = []; cleared.reviewDestinations = [:]
        container.updateReview(cleared)
        preview.display(try XCTUnwrap(PDFDocument(data: pdf.data)), data: pdf.data, revision: 3)
        XCTAssertNil(preview.activeView.reviewFocusProvider.focus)
        preview.prepareForDismantling()
    }

    func testOverlayPaintIsSelectableAndProviderRetiresOffscreenViews() throws {
        let (output, pdf) = try render("Old sample wording.", "New sample wording.")
        let view = PageAdvancingPDFView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        view.document = try XCTUnwrap(PDFDocument(data: pdf.data)); view.scaleFactor = 1; view.layoutSubtreeIfNeeded()
        let page = try XCTUnwrap(view.document?.page(at: 0))
        let provider = view.reviewFocusProvider
        let overlay = try XCTUnwrap(provider.pdfView(view, overlayViewFor: page) as? RevisionReviewFocusView)
        overlay.frame = view.bounds; view.addSubview(overlay)
        XCTAssertNil(overlay.hitTest(CGPoint(x: 100, y: 100)))
        for number in [4, 1000] {
            provider.update(RevisionReviewFocus(id: output.reviewItems[0].id, number: number,
                destination: try XCTUnwrap(pdf.reviewDestinations[output.reviewItems[0].id])))
            let image = NSImage(size: overlay.bounds.size)
            image.lockFocus(); NSColor.white.setFill(); overlay.bounds.fill(); overlay.draw(overlay.bounds); image.unlockFocus()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            var tinted = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.redComponent > color.blueComponent + 0.05 { tinted += 1 }
                }
            }
            XCTAssertGreaterThan(tinted, 20)
        }
        provider.pdfView(view, willEndDisplayingOverlayView: overlay, for: page)
        provider.update(nil)
        XCTAssertNotNil(overlay.focus) // Retired views are no longer held or updated.
        let replacement = try XCTUnwrap(provider.pdfView(view, overlayViewFor: page) as? RevisionReviewFocusView)
        XCTAssertNil(replacement.focus)
        replacement.draw(replacement.bounds)
    }

    func testBufferedFocusAndNavigationRejectSupersededRevisions() async throws {
        let (_, first) = try render("Before.", "First.")
        let (secondItems, second) = try render("Before.", "Second.")
        let (thirdItems, third) = try render("Before.", "Third.")
        let preview = BufferedPDFPreviewView(frame: CGRect(x: 0, y: 0, width: 650, height: 700))
        preview.stagingDelay = 0.05
        preview.display(try XCTUnwrap(PDFDocument(data: first.data)), data: first.data, revision: 1)
        let secondDestination = try XCTUnwrap(second.reviewDestinations.values.first)
        preview.updateReviewFocus(RevisionReviewFocus(id: secondItems.reviewItems[0].id, number: 2, destination: secondDestination), revision: 2)
        preview.navigateReview(id: "second", revision: 2, destination: secondDestination)
        XCTAssertNil(preview.activeView.reviewFocusProvider.focus)
        preview.display(try XCTUnwrap(PDFDocument(data: second.data)), data: second.data, revision: 2)
        let thirdFocus = RevisionReviewFocus(id: thirdItems.reviewItems[0].id, number: 3, destination: try XCTUnwrap(third.reviewDestinations.values.first))
        preview.updateReviewFocus(thirdFocus, revision: 3)
        preview.display(try XCTUnwrap(PDFDocument(data: third.data)), data: third.data, revision: 3)
        for _ in 0..<100 where preview.activeRevision != 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(preview.activeRevision, 3)
        XCTAssertEqual(preview.activeView.reviewFocusProvider.focus, thirdFocus)
        let secondWindow = BufferedPDFPreviewView(frame: preview.frame)
        secondWindow.display(try XCTUnwrap(PDFDocument(data: first.data)), data: first.data, revision: 1)
        XCTAssertNil(secondWindow.activeView.reviewFocusProvider.focus)
        preview.updateReviewFocus(nil, revision: 3)
        XCTAssertNil(preview.activeView.reviewFocusProvider.focus)
        preview.prepareForDismantling(); secondWindow.prepareForDismantling()
    }

    func testBothArrowPairsNavigateFromListAndDetailsThroughCollapsedGroups() throws {
        let old = "# First\n\nOld first.\n\n# Second\n\nOld second.\n\n# Third\n\nOld third."
        let new = old.replacingOccurrences(of: "Old", with: "New")
        // Use the same committed snapshot shape as the live sidebar.
        let (output, pdf) = try render(old, new)
        let snapshot = RenderedDocumentSnapshot(document: MarkdownDocument(title: "Sample", markdown: new), renderedText: output.text,
            pdfData: pdf.data, sectionDestinations: pdf.sectionDestinations, pageSetup: .letter, footers: .init(), revision: 1,
            decorations: output.decorations, reviewItems: output.reviewItems, reviewDestinations: pdf.reviewDestinations,
            baseline: OriginalDocumentSnapshot(document: MarkdownDocument(title: "Original", markdown: old)))
        let controller = RevisionReviewController(); controller.update(snapshot)
        controller.state.collapsedGroups = [output.reviewItems[1].sectionID, output.reviewItems[2].sectionID]
        let view = RevisionChangesView(controller: controller)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 340, height: 750), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; view.refresh()
        defer { window.orderOut(nil) }
        func arrow(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let character = String(UnicodeScalar([123: 0xF702, 124: 0xF703, 125: 0xF701, 126: 0xF700][Int(code)]!)!)
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union([.function, .numericPad]), timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        }
        let buttons = view.split.subviews[1].subviews.compactMap { $0 as? ReviewNavigationButton }
        XCTAssertEqual(buttons.count, 2)
        for target in [view.outline as NSView, view.detailText] + buttons {
            controller.select(output.reviewItems[0].id); view.refresh()
            if !(target is ReviewNavigationButton) { XCTAssertTrue(window.makeFirstResponder(target)) }
            target.keyDown(with: try arrow(124)); XCTAssertEqual(controller.selectedIndex, 1)
            target.keyDown(with: try arrow(125)); XCTAssertEqual(controller.selectedIndex, 2)
            target.keyDown(with: try arrow(125)); XCTAssertEqual(controller.selectedIndex, 2)
            target.keyDown(with: try arrow(123)); XCTAssertEqual(controller.selectedIndex, 1)
            target.keyDown(with: try arrow(126)); XCTAssertEqual(controller.selectedIndex, 0)
            controller.state.detailOffset = 30
            target.keyDown(with: try arrow(126)); XCTAssertEqual(controller.selectedIndex, 0)
            XCTAssertEqual(controller.state.detailOffset, 30)
        }
        XCTAssertTrue(controller.state.collapsedGroups.isEmpty)
        window.makeFirstResponder(view.detailText)
        view.detailText.setSelectedRange(NSRange(location: 10, length: 0))
        view.detailText.keyDown(with: try arrow(124, flags: .shift))
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertGreaterThan(view.detailText.selectedRange().length, 0)
    }
}

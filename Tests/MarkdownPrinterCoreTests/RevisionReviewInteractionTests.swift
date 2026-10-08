import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionReviewInteractionTests: XCTestCase {
    private func event(_ type: NSEvent.EventType, point: NSPoint = .zero, time: TimeInterval = 1,
                       count: Int = 1, modifiers: NSEvent.ModifierFlags = [], window: NSWindow? = nil) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: time,
            windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
    }
    private func click(_ view: PageAdvancingPDFView, page: Int, point: CGPoint) throws {
        let page = try XCTUnwrap(view.document?.page(at: page))
        let location = view.convert(view.convert(point, from: page), to: nil)
        let recognizer = view.reviewClickRecognizer
        recognizer.reset()
        recognizer.mouseDown(with: event(.leftMouseDown, point: location, window: view.window))
        recognizer.mouseUp(with: event(.leftMouseUp, point: location, time: 1.05, window: view.window))
    }
    private func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }
    private func snapshot(count: Int = 3, revision: UInt64 = 1, baseline: OriginalDocumentSnapshot? = nil, suffix: String = "") throws -> RenderedDocumentSnapshot {
        let old = (1...count).map { "## Section \($0)\n\nOld passage \($0) has unchanged words for selection and copying." }.joined(separator: "\n\n")
        let new = old.replacingOccurrences(of: "Old", with: "New") + suffix
        let output = MarkdownRenderer().render(document: MarkdownDocument(title: "Current", markdown: new), original: MarkdownDocument(title: "Original", markdown: old))
        let pdf = try PDFExporter().render(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        return RenderedDocumentSnapshot(document: MarkdownDocument(title: "Current", markdown: new), renderedText: output.text,
            pdfData: pdf.data, pageSetup: .letter, footers: .init(), revision: revision, decorations: output.decorations,
            reviewItems: output.reviewItems, reviewDestinations: pdf.reviewDestinations,
            baseline: baseline ?? OriginalDocumentSnapshot(document: MarkdownDocument(title: "Original", markdown: old)))
    }
    private func changes(_ container: PDFPreviewContainerView) throws -> RevisionChangesView {
        let split = try XCTUnwrap(container.subviews.first as? NSSplitView)
        return try XCTUnwrap(split.subviews[0].subviews.compactMap { $0 as? RevisionChangesView }.first)
    }
    private func window(_ container: NSView) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 950, height: 750), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = container; window.makeKeyAndOrderFront(nil)
        return window
    }
    private func show(_ snapshot: RenderedDocumentSnapshot, in container: PDFPreviewContainerView) throws {
        container.previewView.display(try XCTUnwrap(PDFDocument(data: snapshot.pdfData)), data: snapshot.pdfData, revision: snapshot.revision)
        container.updateReview(snapshot); container.layoutSubtreeIfNeeded()
    }
    private func passagePoint(_ item: RevisionReviewItem, in snapshot: RenderedDocumentSnapshot) throws -> (Int, CGPoint) {
        let fragment = try XCTUnwrap(snapshot.reviewDestinations[item.id]?.fragments.first)
        return (fragment.pageIndex, CGPoint(x: fragment.passageBounds.midX, y: fragment.passageBounds.midY))
    }
    private func arrow(_ code: UInt16, in window: NSWindow) -> NSEvent {
        let char = String(UnicodeScalar(code == 125 ? 0xF701 : 0xF700)!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code)!
    }

    func testOnlyCompletedOrdinaryClicksRecognizeWithoutConsumingOtherGestures() throws {
        let recognizer = RevisionReviewClickRecognizer(target: nil, action: nil)
        var clicks = 0; recognizer.onClick = { _ in clicks += 1 }
        XCTAssertFalse(recognizer.delaysPrimaryMouseButtonEvents)
        XCTAssertFalse(recognizer.canPrevent(NSClickGestureRecognizer()))
        XCTAssertFalse(recognizer.canBePrevented(by: NSPanGestureRecognizer()))
        recognizer.mouseDown(with: event(.leftMouseDown)); recognizer.mouseUp(with: event(.leftMouseUp, time: 1.05))
        XCTAssertEqual(clicks, 1)
        for variant in 0..<8 {
            recognizer.reset()
            let modifiers: NSEvent.ModifierFlags = variant == 1 ? .shift : []
            recognizer.mouseDown(with: event(.leftMouseDown, count: variant == 2 ? 2 : 1, modifiers: modifiers))
            if variant == 0 { recognizer.mouseDragged(with: event(.leftMouseDragged, point: NSPoint(x: 1, y: 0))) }
            if variant == 6 { recognizer.reset() }
            recognizer.mouseUp(with: event(.leftMouseUp, point: NSPoint(x: variant == 4 ? 5 : 0, y: 0),
                time: variant == 3 ? 3 : 1.05, count: variant == 5 ? 2 : 1, modifiers: variant == 7 ? .command : []))
        }
        XCTAssertEqual(clicks, 1, "Selection drags, holds, multi-clicks and modified clicks stay native")
        let data = try NSKeyedArchiver.archivedData(withRootObject: recognizer, requiringSecureCoding: false)
        let restored = try XCTUnwrap(NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as? RevisionReviewClickRecognizer)
        XCTAssertFalse(restored.delaysPrimaryMouseButtonEvents)
    }

    func testClickRevealsCollapsedOffscreenRowAndReadiesArrowsWithoutMovingPDF() async throws {
        let snapshot = try snapshot(count: 35)
        let container = PDFPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 950, height: 750))
        let window = window(container)
        defer { container.prepareForDismantling(); window.orderOut(nil) }
        try show(snapshot, in: container); await settle()
        let changes = try changes(container), item = snapshot.reviewItems[25]
        container.reviewController.state.collapsedGroups = [item.sectionID]
        changes.refresh()
        let destination = try XCTUnwrap(snapshot.reviewDestinations[item.id])
        container.previewView.navigateReview(id: item.id, revision: 1, destination: destination)
        window.makeFirstResponder(container.previewView.activeView)
        let before = container.previewView.capturePersistedViewport()
        let (page, point) = try passagePoint(item, in: snapshot)
        try click(container.previewView.activeView, page: page, point: point); await settle()
        XCTAssertEqual(container.reviewController.selectedItem?.id, item.id)
        XCTAssertFalse(container.reviewController.state.collapsedGroups.contains(item.sectionID))
        XCTAssertTrue(window.firstResponder === changes.outline)
        let row = changes.outline.selectedRow
        XCTAssertEqual((changes.outline.item(atRow: row) as? RevisionChangesView.Entry)?.value.id, item.id)
        XCTAssertTrue(changes.outline.visibleRect.intersects(changes.outline.rect(ofRow: row)))
        XCTAssertEqual(container.previewView.capturePersistedViewport(), before)
        XCTAssertEqual(container.previewView.activeView.reviewFocusProvider.focus?.number, 26)
        window.sendEvent(arrow(125, in: window)); XCTAssertEqual(container.reviewController.selectedIndex, 26)
        window.sendEvent(arrow(126, in: window)); XCTAssertEqual(container.reviewController.selectedIndex, 25)
        let other = PDFPreviewContainerView(frame: container.frame)
        try show(snapshot, in: other)
        XCTAssertEqual(other.reviewController.selectedIndex, 0)
        other.prepareForDismantling()
    }

    func testExistingAndNewNativeSelectionsRemainCopyableAndKeepPDFFocus() async throws {
        let snapshot = try snapshot()
        let container = PDFPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 950, height: 750))
        let window = window(container)
        defer { container.prepareForDismantling(); window.orderOut(nil) }
        try show(snapshot, in: container); await settle()
        let view = container.previewView.activeView
        window.makeFirstResponder(view)
        let selection = try XCTUnwrap(view.document?.findString("unchanged words for selection", withOptions: []).first)
        let (page, point) = try passagePoint(snapshot.reviewItems[1], in: snapshot)
        try click(view, page: page, point: point)
        view.setCurrentSelection(selection, animate: false)
        await settle()
        XCTAssertEqual(container.reviewController.selectedIndex, 1)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(view.currentSelection?.string, "unchanged words for selection")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { entries in let item = NSPasteboardItem(); entries.forEach { item.setData($0.1, forType: $0.0) }; return item })
        }
        view.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "unchanged words for selection")
        try click(view, page: page, point: point); await settle()
        XCTAssertEqual(container.reviewController.selectedIndex, 1)
        window.sendEvent(arrow(125, in: window))
        XCTAssertEqual(container.reviewController.selectedIndex, 2)
        XCTAssertTrue(window.firstResponder === (try changes(container)).outline)
        window.makeFirstResponder(view)
        view.reviewClickRecognizer.mouseDown(with: event(.leftMouseDown, count: 2))
        XCTAssertFalse(view.reviewArrowNavigationEnabled, "Word selection returns arrow handling to PDFKit")
        XCTAssertEqual(view.currentSelection?.string, "unchanged words for selection")
    }

    func testHiddenSidebarPagesLinksAndBlankPageAreasDoNotSelectChanges() async throws {
        let snapshot = try snapshot()
        let container = PDFPreviewContainerView(frame: CGRect(x: 0, y: 0, width: 950, height: 750))
        let window = window(container)
        defer { container.prepareForDismantling(); window.orderOut(nil) }
        try show(snapshot, in: container); await settle()
        let view = container.previewView.activeView, (page, point) = try passagePoint(snapshot.reviewItems[1], in: snapshot)
        window.makeFirstResponder(view)
        container.setThumbnailSidebarVisible(false)
        try click(view, page: page, point: point); await settle()
        XCTAssertEqual(container.reviewController.selectedIndex, 0)
        container.setThumbnailSidebarVisible(true); container.setSidebarMode(.pages)
        try click(view, page: page, point: point); await settle()
        XCTAssertEqual(container.reviewController.selectedIndex, 0)
        container.setSidebarMode(.changes); window.makeFirstResponder(view)
        let annotation = PDFAnnotation(bounds: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10), forType: .link, withProperties: nil)
        annotation.url = URL(string: "https://example.com")
        view.document!.page(at: page)!.addAnnotation(annotation)
        try click(view, page: page, point: point); await settle()
        XCTAssertEqual(container.reviewController.selectedIndex, 0)
        XCTAssertTrue(window.firstResponder === view)
        try click(view, page: page, point: CGPoint(x: 5, y: 5)); await settle()
        XCTAssertEqual(container.reviewController.selectedIndex, 0)
    }

    func testCalloutAndParagraphHitTestsResolveOverlapsAndPageFragments() throws {
        let snapshot = try snapshot()
        let a = snapshot.reviewItems[0], b = snapshot.reviewItems[1]
        var destinations = snapshot.reviewDestinations
        let large = CGRect(x: 40, y: 300, width: 400, height: 100)
        let small = CGRect(x: 40, y: 310, width: 100, height: 20)
        destinations[a.id]!.fragments = [PDFReviewFragment(pageIndex: 1, passageBounds: large, bandBounds: large.insetBy(dx: -10, dy: -10))]
        destinations[b.id]!.fragments = [PDFReviewFragment(pageIndex: 1, passageBounds: small, bandBounds: small.insetBy(dx: -10, dy: -10),
            noteBounds: [CGRect(x: 200, y: 320, width: 70, height: 10)])]
        XCTAssertEqual(RevisionReviewHitTest.item(at: CGPoint(x: 60, y: 315), pageIndex: 1, items: [a,b], destinations: destinations), b.id)
        XCTAssertEqual(RevisionReviewHitTest.item(at: CGPoint(x: 220, y: 325), pageIndex: 1, items: [a,b], destinations: destinations), b.id)
        XCTAssertEqual(RevisionReviewHitTest.item(at: CGPoint(x: 35, y: 320), pageIndex: 1, items: [a,b], destinations: destinations), b.id)
        XCTAssertNil(RevisionReviewHitTest.item(at: CGPoint(x: 60, y: 315), pageIndex: 0, items: [a,b], destinations: destinations))
        XCTAssertNil(RevisionReviewHitTest.item(at: .zero, pageIndex: 1, items: [a,b], destinations: destinations))
        let old = "Kept opening.\n\nRetired paragraph.\n\nKept ending."
        let output = MarkdownRenderer().render(document: MarkdownDocument(title: "New", markdown: "Kept opening.\n\nKept ending."), original: MarkdownDocument(title: "Old", markdown: old))
        let pdf = try PDFExporter().render(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
        let fragment = try XCTUnwrap(pdf.reviewDestinations.values.first?.fragments.first)
        let note = try XCTUnwrap(fragment.noteBounds.first)
        XCTAssertEqual(RevisionReviewHitTest.item(at: CGPoint(x: note.midX, y: note.midY), pageIndex: fragment.pageIndex,
            items: output.reviewItems, destinations: pdf.reviewDestinations), output.reviewItems.first?.id)
    }

    func testPendingClicksRejectNewPressesHiddenStateAndSupersededPDFs() async throws {
        let first = try snapshot()
        let preview = BufferedPDFPreviewView(frame: CGRect(x: 0, y: 0, width: 650, height: 750))
        let window = window(preview)
        defer { preview.prepareForDismantling(); window.orderOut(nil) }
        preview.display(try XCTUnwrap(PDFDocument(data: first.pdfData)), data: first.pdfData, revision: 1)
        var selected: [String] = []; preview.selectReviewItem = { id, _, _ in selected.append(id) }
        preview.updateReviewInteraction(items: first.reviewItems, destinations: first.reviewDestinations, revision: 1, enabled: true)
        let (page, point) = try passagePoint(first.reviewItems[1], in: first)
        try click(preview.activeView, page: page, point: point)
        preview.activeView.reviewClickRecognizer.mouseDown(with: event(.leftMouseDown, count: 2))
        await settle(); XCTAssertTrue(selected.isEmpty)
        try click(preview.activeView, page: page, point: point)
        preview.updateReviewInteraction(items: first.reviewItems, destinations: first.reviewDestinations, revision: 1, enabled: false)
        await settle(); XCTAssertTrue(selected.isEmpty)
        let second = try snapshot(revision: 2, baseline: first.baseline, suffix: "\n\nAnother addition.")
        preview.updateReviewInteraction(items: second.reviewItems, destinations: second.reviewDestinations, revision: 2, enabled: true)
        try click(preview.activeView, page: page, point: point); await settle(); XCTAssertTrue(selected.isEmpty)
        let retired = preview.activeView
        let callback = retired.reviewClickRecognizer.onClick
        preview.display(try XCTUnwrap(PDFDocument(data: second.pdfData)), data: second.pdfData, revision: 2)
        for _ in 0..<100 where preview.activeRevision != 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        callback(event(.leftMouseUp)); await settle(); XCTAssertTrue(selected.isEmpty)
        let (newPage, newPoint) = try passagePoint(second.reviewItems[1], in: second)
        try click(preview.activeView, page: newPage, point: newPoint); await settle()
        XCTAssertEqual(selected, [second.reviewItems[1].id])
        preview.display(try XCTUnwrap(PDFDocument(data: second.pdfData)), data: second.pdfData, revision: 3)
        preview.updateReviewInteraction(items: second.reviewItems, destinations: second.reviewDestinations, revision: 3, enabled: true)
        try click(preview.activeView, page: newPage, point: newPoint); await settle()
        XCTAssertEqual(selected.count, 2)
        try click(preview.activeView, page: newPage, point: newPoint)
        preview.prepareForDismantling(); await settle(); XCTAssertEqual(selected.count, 2)
    }

    func testStructuralRemovalNotesAtOneBoundarySelectTheirOwnEntry() throws {
        for removed in ["| Field | Value |\n|---|---|\n| R1 | Retired |", "- Retired list item.", "### Retired section\n\nRetired section body.", "![Retired picture](missing.png)"] {
            let old = "# Guide\n\n## Opening\n\nKeep introduction.\n\nRetired advice paragraph.\n\n" + removed + "\n\n## Ending\n\nKeep ending."
            let new = "# Guide\n\n## Opening\n\nKeep introduction.\n\n## Contents\n\n- [Ending](#ending)\n\n## Ending\n\nKeep ending."
            let output = MarkdownRenderer().render(document: MarkdownDocument(title: "New", markdown: new), original: MarkdownDocument(title: "Old", markdown: old))
            let pdf = try PDFExporter().render(from: output.text, decorations: output.decorations, reviewItems: output.reviewItems)
            let combinedImagePassage = removed.hasPrefix("![")
            XCTAssertEqual(output.reviewItems.filter { $0.kind == .removed }.count, combinedImagePassage ? 1 : 2)
            for item in output.reviewItems where item.kind == .removed {
                let fragment = try XCTUnwrap(pdf.reviewDestinations[item.id]?.fragments.first)
                XCTAssertEqual(fragment.noteBounds.count, combinedImagePassage ? 2 : 1)
                for note in fragment.noteBounds {
                    XCTAssertEqual(RevisionReviewHitTest.item(at: CGPoint(x: note.midX, y: note.midY), pageIndex: fragment.pageIndex,
                        items: output.reviewItems, destinations: pdf.reviewDestinations), item.id)
                }
            }
            let added = try XCTUnwrap(output.reviewItems.first { $0.kind == .added })
            XCTAssertTrue(pdf.reviewDestinations[added.id]!.fragments.allSatisfy { $0.noteBounds.isEmpty })
        }
    }
}

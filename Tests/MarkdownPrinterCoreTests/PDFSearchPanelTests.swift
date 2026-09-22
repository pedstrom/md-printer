import AppKit
import SwiftUI
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class PDFSearchPanelTests: XCTestCase {
    func testInitialPlacementUsesTheLaidOutPanelSize() async throws {
        let fixture = try SearchPanelFixture()
        defer { fixture.close() }
        let controller = try await readyController(in: fixture)
        let panel = try await present(controller, in: fixture)

        XCTAssertEqual(panel.frame.width, 420, accuracy: 1)
        XCTAssertEqual(panel.frame.maxX, fixture.window.frame.maxX - 24, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, fixture.window.frame.maxY - 52, accuracy: 1)
        XCTAssertTrue(fixture.visibleFrame.contains(panel.frame))
        XCTAssertTrue(fixture.visibleFrame.contains(try fieldFrame(in: panel)))
    }

    func testCommandFRecoversAnOffscreenPanelAndFocusesItsRetainedQuery() async throws {
        let fixture = try SearchPanelFixture()
        defer { fixture.close() }
        let controller = try await readyController(in: fixture)
        controller.query = "needle"
        let panel = try await present(controller, in: fixture)
        controller.findNext()
        let selectedMatch = controller.selectedMatchIndex

        moveSearchControlsOffscreen(panel, relativeTo: fixture.visibleFrame)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(fixture.visibleFrame.intersects(try fieldFrame(in: panel)))

        // Exercise the native panel shortcut as well as the SwiftUI presentation update.
        let commandF = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "f",
            charactersIgnoringModifiers: "f",
            isARepeat: false,
            keyCode: 3
        ))
        XCTAssertTrue(panel.performKeyEquivalent(with: commandF))
        try await waitUntil { fixture.visibleFrame.contains(panel.frame) }

        let field = try searchField(in: panel)
        try await waitUntil {
            (field.currentEditor() as? NSTextView)?.selectedRange().length == "needle".utf16.count
        }
        XCTAssertTrue(fixture.visibleFrame.contains(try fieldFrame(in: panel)))
        XCTAssertEqual(controller.query, "needle")
        XCTAssertEqual(controller.matchCount, 2)
        XCTAssertEqual(controller.selectedMatchIndex, selectedMatch)

        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Gamma", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil { controller.query == "Gamma" }
        XCTAssertEqual(controller.matchCount, 1)
    }

    func testReopeningFindRecoversItsPositionAfterTheDocumentMoves() async throws {
        let fixture = try SearchPanelFixture()
        defer { fixture.close() }
        let controller = try await readyController(in: fixture)
        controller.query = "needle"
        let panel = try await present(controller, in: fixture)

        // A usable user placement can become inaccessible when its parent moves.
        panel.setFrameOrigin(NSPoint(x: fixture.visibleFrame.minX + 32, y: fixture.visibleFrame.minY + 32))
        XCTAssertTrue(fixture.visibleFrame.contains(panel.frame))
        controller.dismiss()
        try await waitUntil { !panel.isVisible }
        fixture.window.setFrameOrigin(fixture.visibleFrame.origin)
        // Retain the previously reproduced geometry even on OS versions that constrain child windows differently.
        moveSearchControlsOffscreen(panel, relativeTo: fixture.visibleFrame)

        controller.present()
        try await waitUntil { panel.isVisible && fixture.visibleFrame.contains(panel.frame) }

        XCTAssertTrue(panel.parent === fixture.window)
        XCTAssertTrue(fixture.visibleFrame.contains(try fieldFrame(in: panel)))
        XCTAssertEqual(controller.query, "needle")
        XCTAssertEqual(controller.matchCount, 2)
    }

    func testVisibleUserPlacementSurvivesRefocusingResizeAndDocumentRefresh() async throws {
        let fixture = try SearchPanelFixture()
        defer { fixture.close() }
        let controller = try await readyController(in: fixture)
        controller.query = "needle"
        let panel = try await present(controller, in: fixture)
        panel.setFrameOrigin(NSPoint(x: fixture.visibleFrame.minX + 32, y: fixture.visibleFrame.minY + 32))
        let chosenFrame = panel.frame

        controller.present()
        let field = try searchField(in: panel)
        try await waitUntil {
            (field.currentEditor() as? NSTextView)?.selectedRange().length == "needle".utf16.count
        }
        XCTAssertEqual(panel.frame, chosenFrame)

        var resizedFrame = fixture.window.frame
        resizedFrame.size.width += 80
        fixture.window.setFrame(resizedFrame, display: true)
        fixture.session.load(data: Data("# Search\n\nneedle first\n\nneedle second\n\nneedle third".utf8))
        try await waitUntil { controller.matchCount == 3 }
        XCTAssertEqual(panel.frame, chosenFrame)
        XCTAssertTrue(panel.isVisible)

        controller.dismiss()
        try await waitUntil { !panel.isVisible }
        controller.present()
        try await waitUntil { panel.isVisible && field.currentEditor() != nil }
        XCTAssertEqual(panel.frame, chosenFrame)
        XCTAssertEqual(controller.query, "needle")
        XCTAssertEqual(controller.matchCount, 3)
    }

    private func readyController(in fixture: SearchPanelFixture) async throws -> PDFSearchController {
        try await waitUntil { fixture.preview?.searchController?.canPresent == true }
        return try XCTUnwrap(fixture.preview?.searchController)
    }

    private func present(_ controller: PDFSearchController, in fixture: SearchPanelFixture) async throws -> NSWindow {
        controller.present()
        try await waitUntil { fixture.panel?.isVisible == true }
        let panel = try XCTUnwrap(fixture.panel)
        let field = try searchField(in: panel)
        try await waitUntil { field.currentEditor() != nil }
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    private func searchField(in panel: NSWindow) throws -> NSSearchField {
        try XCTUnwrap(panel.contentView.flatMap {
            searchPanelDescendants($0).compactMap { $0 as? NSSearchField }.first
        })
    }

    private func fieldFrame(in panel: NSWindow) throws -> NSRect {
        let field = try searchField(in: panel)
        return panel.convertToScreen(field.convert(field.bounds, to: nil))
    }

    private func moveSearchControlsOffscreen(_ panel: NSWindow, relativeTo visibleFrame: NSRect) {
        let displayBounds = NSScreen.screens.reduce(visibleFrame) { $0.union($1.visibleFrame) }
        let contentHeight = panel.contentRect(forFrameRect: panel.frame).height
        panel.setFrameOrigin(NSPoint(
            x: displayBounds.minX - panel.frame.width + 40,
            y: displayBounds.minY - contentHeight
        ))
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for native search UI", file: file, line: line)
    }
}

@MainActor
private final class SearchPanelFixture {
    let session = DocumentSession()
    let window: NSWindow
    let visibleFrame: NSRect

    var preview: BufferedPDFPreviewView? {
        window.contentView.flatMap {
            searchPanelDescendants($0).compactMap { $0 as? BufferedPDFPreviewView }.first
        }
    }

    var panel: NSWindow? {
        window.childWindows?.first { $0.title == "Find" }
    }

    init() throws {
        visibleFrame = try XCTUnwrap(NSScreen.main).visibleFrame
        guard visibleFrame.width >= 760, visibleFrame.height >= 612 else {
            throw XCTSkip("Native document-window tests require a screen at least 760 by 612 points")
        }
        session.load(data: Data("# Search\n\nneedle first\n\nneedle second\n\nGamma".utf8))
        let host = NSHostingController(rootView: MarkdownPrinterView(
            session: session,
            exportPreferences: ExportPreferences(),
            activityCoordinator: ApplicationActivityCoordinator(),
            openFiles: { _ in }
        ))
        let frame = NSRect(x: visibleFrame.midX - 340, y: visibleFrame.maxY - 612, width: 680, height: 612)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        for child in window.childWindows ?? [] {
            window.removeChildWindow(child)
            child.orderOut(nil)
        }
        window.contentViewController = nil
        window.close()
    }
}

@MainActor
private func searchPanelDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(searchPanelDescendants)
}

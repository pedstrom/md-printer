import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class DocumentWindowRestorationCoordinatorTests: XCTestCase {
    func testFramePolicyPreservesVisibleFramesAndClampsOffscreenGeometry() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let secondary = CGRect(x: 1_440, y: 120, width: 1_000, height: 700)
        let visible = CGRect(x: 120, y: 80, width: 760, height: 700)

        XCTAssertEqual(
            DocumentWindowFrameRestorationPolicy.adjustedFrame(
                visible,
                visibleFrames: [primary, secondary]
            ),
            visible
        )
        XCTAssertEqual(
            DocumentWindowFrameRestorationPolicy.adjustedFrame(
                CGRect(x: 2_900, y: -500, width: 1_200, height: 1_100),
                visibleFrames: [primary, secondary]
            ),
            secondary
        )
        XCTAssertEqual(
            DocumentWindowFrameRestorationPolicy.adjustedFrame(
                visible,
                visibleFrames: []
            ),
            visible
        )
        XCTAssertNil(
            DocumentWindowFrameRestorationPolicy.adjustedFrame(
                CGRect(x: 0, y: 0, width: 0, height: 100),
                visibleFrames: [primary]
            )
        )
    }

    func testCoordinatorCapturesAndRestoresFrameZoomAndViewportForUpdateRelaunch() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Window-Restoration.md")
        let document = try makeDocument()
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let savedFrame = CGRect(
            x: visibleFrame.minX + 80,
            y: visibleFrame.minY + 60,
            width: min(820, visibleFrame.width - 100),
            height: min(760, visibleFrame.height - 100)
        )

        let originalWindow = NSWindow(
            contentRect: savedFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        originalWindow.setFrame(savedFrame, display: false)
        let originalPreview = BufferedPDFPreviewView(
            frame: CGRect(x: 0, y: 0, width: savedFrame.width, height: savedFrame.height)
        )
        originalPreview.display(document, data: Data("original".utf8), revision: 1)
        originalPreview.layoutSubtreeIfNeeded()
        originalPreview.activeView.scaleFactor = 0.83
        let targetPage = try XCTUnwrap(document.page(at: min(2, document.pageCount - 1)))
        let targetBounds = targetPage.bounds(for: .cropBox)
        let targetDestination = PDFDestination(
            page: targetPage,
            at: CGPoint(x: targetBounds.minX, y: targetBounds.maxY)
        )
        targetDestination.zoom = 0.83
        originalPreview.activeView.go(to: targetDestination)
        let originalViewport = try XCTUnwrap(originalPreview.capturePersistedViewport())

        let originalCoordinator = DocumentWindowRestorationCoordinator(
            sourceURL: url,
            restorationController: controller
        )
        originalCoordinator.attach(window: originalWindow)
        originalCoordinator.attach(preview: originalPreview)
        originalCoordinator.activate()

        controller.prepareForRelaunch(targetBuild: "11")
        XCTAssertEqual(controller.consumeDocumentsForRelaunch(currentBuild: "11"), [url])
        originalCoordinator.deactivate()

        let restoredWindow = NSWindow(
            contentRect: CGRect(x: 10, y: 10, width: 420, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let restoredPreview = BufferedPDFPreviewView(
            frame: CGRect(x: 0, y: 0, width: savedFrame.width, height: savedFrame.height)
        )
        restoredPreview.display(document, data: Data("restored".utf8), revision: 1)
        restoredPreview.layoutSubtreeIfNeeded()
        let restoredCoordinator = DocumentWindowRestorationCoordinator(
            sourceURL: url,
            restorationController: controller
        )
        restoredCoordinator.attach(window: restoredWindow)
        restoredCoordinator.attach(preview: restoredPreview)
        restoredCoordinator.previewDidDisplayDocument()
        restoredCoordinator.activate()

        for _ in 0..<6 {
            await Task.yield()
        }

        let expectedFrame = try XCTUnwrap(
            DocumentWindowFrameRestorationPolicy.adjustedFrame(
                savedFrame,
                visibleFrames: NSScreen.screens.map(\.visibleFrame)
            )
        )
        XCTAssertEqual(restoredWindow.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(restoredWindow.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(restoredWindow.frame.width, expectedFrame.width, accuracy: 0.5)
        XCTAssertEqual(restoredWindow.frame.height, expectedFrame.height, accuracy: 0.5)
        XCTAssertEqual(restoredPreview.activeView.scaleFactor, 0.83, accuracy: 0.01)
        let restoredViewport = try XCTUnwrap(restoredPreview.capturePersistedViewport())
        XCTAssertEqual(restoredViewport.pageIndex, originalViewport.pageIndex)
        XCTAssertEqual(
            restoredViewport.documentProgress,
            originalViewport.documentProgress,
            accuracy: 0.03
        )

        restoredCoordinator.deactivate()
    }

    private func makeDocument() throws -> PDFDocument {
        let markdown = (0..<100)
            .map { "Paragraph \($0): enough text to produce a stable multipage restoration fixture." }
            .joined(separator: "\n\n")
        let attributed = MarkdownRenderer().render(
            document: MarkdownDocument(title: "Restore", markdown: markdown)
        )
        let data = try PDFExporter().pdfData(from: attributed)
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "DocumentWindowRestorationCoordinatorTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

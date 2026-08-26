import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class PDFThumbnailSidebarControllerTests: XCTestCase {
    func testSidebarStartsHiddenAndTogglesWithStandardBounds() {
        let controller = PDFThumbnailSidebarController()
        let container = PDFPreviewContainerView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 890)
        )
        container.attach(sidebarController: controller)

        XCTAssertFalse(container.isThumbnailSidebarVisible)
        XCTAssertEqual(container.sidebarDividerThickness, 0)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(controller.commandTitle, "Show Thumbnails")
        XCTAssertTrue(controller.canToggle)

        controller.toggle()
        container.layoutSubtreeIfNeeded()

        XCTAssertTrue(container.isThumbnailSidebarVisible)
        XCTAssertGreaterThan(container.sidebarDividerThickness, 0)
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.commandTitle, "Hide Thumbnails")
        XCTAssertEqual(
            container.thumbnailSidebarWidth,
            PDFPreviewContainerView.defaultSidebarWidth,
            accuracy: 0.5
        )

        container.setThumbnailSidebarWidth(20)
        XCTAssertEqual(
            container.thumbnailSidebarWidth,
            PDFPreviewContainerView.minimumSidebarWidth,
            accuracy: 0.5
        )
        container.setThumbnailSidebarWidth(500)
        XCTAssertEqual(
            container.thumbnailSidebarWidth,
            PDFPreviewContainerView.maximumSidebarWidth,
            accuracy: 0.5
        )

        controller.toggle()
        XCTAssertFalse(container.isThumbnailSidebarVisible)
        XCTAssertEqual(container.sidebarDividerThickness, 0)
        container.prepareForDismantling()
        XCTAssertFalse(controller.canToggle)
    }

    func testThumbnailViewTracksTheActiveBufferedPreviewAcrossRefresh() throws {
        let container = PDFPreviewContainerView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 890)
        )
        container.previewView.stagingDelay = 0
        container.previewView.retirementDelay = 0
        let first = try makePDF("# First\n\nFirst document")
        let second = try makePDF("# Second\n\nSecond document")

        container.previewView.display(first.document, data: first.data, revision: 1)
        XCTAssertTrue(container.thumbnailView.pdfView === container.previewView.activeView)
        XCTAssertTrue(container.thumbnailView.pdfView?.document === first.document)

        container.previewView.display(second.document, data: second.data, revision: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        XCTAssertTrue(container.thumbnailView.pdfView === container.previewView.activeView)
        XCTAssertTrue(container.thumbnailView.pdfView?.document === second.document)
    }

    func testSplitPositionIsClampedToSidebarRange() {
        let container = PDFPreviewContainerView()
        let splitView = NSSplitView()

        XCTAssertEqual(
            container.splitView(splitView, constrainSplitPosition: 12, ofSubviewAt: 0),
            PDFPreviewContainerView.minimumSidebarWidth
        )
        XCTAssertEqual(
            container.splitView(splitView, constrainSplitPosition: 400, ofSubviewAt: 0),
            PDFPreviewContainerView.maximumSidebarWidth
        )
        XCTAssertEqual(
            container.splitView(splitView, constrainSplitPosition: 190, ofSubviewAt: 1),
            190
        )
    }

    func testThumbnailSizeTracksResizableSidebarWidth() {
        let controller = PDFThumbnailSidebarController()
        let container = PDFPreviewContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 700)
        )
        container.attach(sidebarController: controller)
        container.setThumbnailSidebarVisible(true)
        container.setThumbnailSidebarWidth(120)
        container.layoutSubtreeIfNeeded()
        let narrowSize = container.thumbnailView.thumbnailSize

        container.setThumbnailSidebarWidth(260)
        container.layoutSubtreeIfNeeded()
        let wideSize = container.thumbnailView.thumbnailSize

        XCTAssertEqual(narrowSize.width, 96, accuracy: 1)
        XCTAssertEqual(wideSize.width, 236, accuracy: 1)
        XCTAssertGreaterThan(wideSize.height, narrowSize.height)
    }

    private func makePDF(_ markdown: String) throws -> (data: Data, document: PDFDocument) {
        let text = MarkdownRenderer().render(markdown: markdown)
        let data = try PDFExporter().pdfData(from: text)
        return (data, try XCTUnwrap(PDFDocument(data: data)))
    }
}

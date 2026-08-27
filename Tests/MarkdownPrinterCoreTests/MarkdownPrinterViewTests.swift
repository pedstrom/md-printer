import AppKit
import Foundation
import MarkdownPrinterCore
import SwiftUI
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class MarkdownPrinterViewTests: XCTestCase {
    func testWindowContentExpandsBeyondItsMinimumSize() {
        let hostingController = NSHostingController(rootView: makeWelcomeView())
        let availableSize = NSSize(width: 920, height: 720)

        XCTAssertEqual(hostingController.sizeThatFits(in: availableSize), availableSize)
    }

    func testWelcomeLeavesTheNativeWindowSurfaceUnpainted() throws {
        let hostingView = NSHostingView(rootView: makeWelcomeView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 920, height: 720)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))

        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        let cornerColor = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4))
        XCTAssertEqual(cornerColor.alphaComponent, 0, accuracy: 0.01)
    }

    func testWelcomeArtworkUsesTheDoubledDisplaySize() {
        XCTAssertEqual(
            MarkdownPrinterWelcomeArtwork.displaySize,
            NSSize(width: 128, height: 140)
        )
    }

    func testWelcomeArtworkLoadsTheApprovedDocumentIconSource() throws {
        let sourceURL = repositoryRoot
            .appendingPathComponent("Resources/MarkdownDocumentIcon.png")
        let image = try XCTUnwrap(MarkdownPrinterWelcomeArtwork.image(at: sourceURL))

        XCTAssertEqual(MarkdownPrinterWelcomeArtwork.resourceName, "MarkdownDocumentIcon")
        XCTAssertEqual(MarkdownPrinterWelcomeArtwork.resourceExtension, "icns")
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    func testWelcomeArtworkReturnsNilForAMissingResource() {
        let missingURL = URL(fileURLWithPath: "/private/tmp/missing-markdown-document-icon")

        XCTAssertNil(MarkdownPrinterWelcomeArtwork.image(at: missingURL))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeWelcomeView() -> MarkdownPrinterView {
        MarkdownPrinterView(
            session: DocumentSession(),
            exportPreferences: ExportPreferences(),
            activityCoordinator: ApplicationActivityCoordinator(),
            openFiles: { _ in }
        )
    }
}

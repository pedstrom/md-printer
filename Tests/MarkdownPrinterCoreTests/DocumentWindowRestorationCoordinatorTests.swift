import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class DocumentWindowRestorationCoordinatorTests: XCTestCase {
    func testPreviewWindowCapturesAndRestoresWhenSwiftUIBackgroundAttachmentIsMissing() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Preview-Window.md")
        let frame = CGRect(x: 70, y: 50, width: 620, height: 600)
        let originalWindow = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                                      backing: .buffered, defer: false)
        originalWindow.setFrame(frame, display: false)
        let preview = BufferedPDFPreviewView(frame: CGRect(origin: .zero, size: frame.size))
        originalWindow.contentView = preview
        preview.display(try makeDocument(), data: Data("window".utf8), revision: 1)
        await settleRestoration()
        preview.showActualSize()
        preview.zoomIn()
        let original = DocumentWindowRestorationCoordinator(sourceURL: url, restorationController: controller)
        original.attach(preview: preview)
        original.activate()
        original.attach(window: nil)
        let saved = try XCTUnwrap(controller.currentWindowState(for: url))
        XCTAssertEqual(saved.frame, frame)
        let viewport = try XCTUnwrap(saved.viewport)
        original.deactivate()

        controller.prepareWindowStates(for: WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(identifier: "preview", tabs: [.document(url, state: saved)],
                                 selectedTabIndex: 0, isTabBarVisible: false)
        ]))
        let restored = DocumentWindowRestorationCoordinator(sourceURL: url, restorationController: controller)
        let restoredWindow = NSWindow(contentRect: CGRect(x: 10, y: 10, width: 400, height: 400),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let restoredPreview = BufferedPDFPreviewView(frame: .zero)
        restored.attach(preview: restoredPreview)
        restored.activate()
        restoredPreview.display(try makeDocument(), data: Data("restored".utf8), revision: 1)
        restoredWindow.contentView = restoredPreview
        await settleRestoration()
        XCTAssertEqual(restoredWindow.frame, frame)
        XCTAssertEqual(restoredPreview.activeView.scaleFactor, viewport.scaleFactor, accuracy: 0.01)
        restored.deactivate()
    }

    func testRestorationWinsOverInitialWindowPlacementAndWaitsForPreviewLayout() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Delayed-Layout.md")
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let frame = CGRect(x: screen.minX + 70, y: screen.minY + 50,
                           width: 620, height: 600)
        let viewport = PersistedPreviewViewport(scaleFactor: 1.35, pageIndex: 2,
                                               normalizedPageX: 0, normalizedPageY: 0.65,
                                               documentProgress: 0.3)
        controller.prepareWindowStates(for: WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(identifier: "delayed", tabs: [
                .document(url, state: DocumentWindowRestorationState(frame: frame, viewport: viewport))
            ], selectedTabIndex: 0, isTabBarVisible: false)
        ]))
        let coordinator = DocumentWindowRestorationCoordinator(sourceURL: url, restorationController: controller)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let preview = BufferedPDFPreviewView(frame: .zero)
        coordinator.attach(window: window)
        coordinator.attach(preview: preview)
        coordinator.activate()
        preview.display(try makeDocument(), data: Data("delayed".utf8), revision: 1)
        coordinator.previewDidDisplayDocument()
        // SwiftUI/AppKit assigns its initial geometry after the attachment callback.
        window.setFrame(CGRect(x: 10, y: 10, width: 400, height: 400), display: false)
        await settleRestoration()
        XCTAssertEqual(window.frame, frame)

        // The PDF may load before its native view joins the window or has a usable size.
        window.contentView = preview
        preview.layoutSubtreeIfNeeded()
        await settleRestoration()
        XCTAssertEqual(preview.activeView.scaleFactor, 1.35, accuracy: 0.01)
        let restored = try XCTUnwrap(preview.capturePersistedViewport())
        XCTAssertEqual(restored.pageIndex, 2)
        XCTAssertEqual(restored.normalizedPageY, 0.65, accuracy: 0.01)

        // Restoration runs once; later user moves and zoom commands stay in effect.
        let movedFrame = frame.offsetBy(dx: 15, dy: 10)
        window.setFrame(movedFrame, display: false)
        preview.showActualSize()
        coordinator.attach(window: window)
        coordinator.previewDidDisplayDocument()
        await settleRestoration()
        XCTAssertEqual(window.frame, movedFrame)
        XCTAssertEqual(preview.activeView.scaleFactor, 1, accuracy: 0.01)
        coordinator.deactivate()
    }

    func testPersistedViewportPreservesBothScrollAxesAndAPageGap() async throws {
        let document = try makeDocument()
        let original = BufferedPDFPreviewView(frame: CGRect(x: 0, y: 0, width: 620, height: 600))
        original.display(document, data: Data("original".utf8), revision: 1)
        await settleRestoration()
        original.showActualSize()
        original.zoomIn()
        original.layoutSubtreeIfNeeded()
        let documentView = try XCTUnwrap(original.activeView.documentView)
        let scrollView = try XCTUnwrap(documentView.enclosingScrollView)
        let clip = scrollView.contentView
        let page = try XCTUnwrap(document.page(at: 2))
        let pageBounds = original.activeView.convert(page.bounds(for: .cropBox), from: page)
        let pageTop = original.activeView.isFlipped ? pageBounds.minY : pageBounds.maxY
        let viewportTop = original.activeView.isFlipped ? original.bounds.minY : original.bounds.maxY
        let delta = original.activeView.isFlipped ? pageTop - viewportTop : viewportTop - pageTop
        clip.scroll(to: CGPoint(x: 73, y: clip.bounds.minY + delta - 3))
        scrollView.reflectScrolledClipView(clip)
        let savedOrigin = clip.bounds.origin
        let saved = try XCTUnwrap(original.capturePersistedViewport())

        let restored = BufferedPDFPreviewView(frame: original.frame)
        restored.display(document, data: Data("restored".utf8), revision: 1)
        restored.layoutSubtreeIfNeeded()
        restored.restorePersistedViewport(saved)
        await settleRestoration()
        let restoredScroll = try XCTUnwrap(restored.activeView.documentView?.enclosingScrollView)
        XCTAssertEqual(restored.activeView.scaleFactor, original.activeView.scaleFactor, accuracy: 0.001)
        XCTAssertEqual(restoredScroll.contentView.bounds.minX, savedOrigin.x, accuracy: 0.5)
        XCTAssertEqual(restoredScroll.contentView.bounds.minY, savedOrigin.y, accuracy: 0.5)
    }

    func testDeactivationCancelsQueuedRestorationAndReactivationResumesIt() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Cancelled-Restoration.md")
        let frame = CGRect(x: 70, y: 50, width: 620, height: 600)
        controller.prepareWindowStates(for: WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(identifier: "cancel", tabs: [
                .document(url, state: DocumentWindowRestorationState(frame: frame, viewport: nil))
            ], selectedTabIndex: 0, isTabBarVisible: false)
        ]))
        let coordinator = DocumentWindowRestorationCoordinator(sourceURL: url, restorationController: controller)
        let window = NSWindow(contentRect: CGRect(x: 10, y: 10, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let initialFrame = window.frame
        coordinator.attach(window: window)
        coordinator.activate()
        coordinator.deactivate()
        await settleRestoration()
        XCTAssertEqual(window.frame, initialFrame)
        coordinator.activate()
        await settleRestoration()
        XCTAssertEqual(window.frame, frame)
        coordinator.deactivate()
    }

    func testChangedDocumentGeometryFallsBackToSavedPageAndZoom() async throws {
        let preview = BufferedPDFPreviewView(frame: CGRect(x: 0, y: 0, width: 620, height: 600))
        preview.display(try makeDocument(), data: Data("changed".utf8), revision: 1)
        preview.layoutSubtreeIfNeeded()
        let saved = PersistedPreviewViewport(
            scaleFactor: 1.35, pageIndex: 2, normalizedPageX: 0,
            normalizedPageY: 0.65, documentProgress: 0.3,
            scrollPosition: PersistedPreviewScrollPosition(
                offset: CGPoint(x: 9000, y: 9000),
                documentSize: CGSize(width: 10, height: 10),
                viewportSize: CGSize(width: 10, height: 10)
            )
        )
        preview.restorePersistedViewport(saved)
        await settleRestoration()
        let restored = try XCTUnwrap(preview.capturePersistedViewport())
        XCTAssertEqual(restored.scaleFactor, 1.35, accuracy: 0.01)
        XCTAssertEqual(restored.pageIndex, 2)
        XCTAssertEqual(restored.normalizedPageY, 0.65, accuracy: 0.01)
    }

    func testRestorationWaitsForBufferedDocumentReplacementToCommit() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Buffered-Restoration.md")
        controller.prepareWindowStates(for: WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(identifier: "buffered", tabs: [
                .document(url, state: DocumentWindowRestorationState(
                    frame: nil, viewport: PersistedPreviewViewport(
                        scaleFactor: 1.35, pageIndex: 2, normalizedPageX: 0,
                        normalizedPageY: 0.65, documentProgress: 0.3
                    )
                ))
            ], selectedTabIndex: 0, isTabBarVisible: false)
        ]))
        let window = NSWindow(contentRect: CGRect(x: 70, y: 50, width: 620, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let preview = BufferedPDFPreviewView(frame: CGRect(x: 0, y: 0, width: 620, height: 600))
        window.contentView = preview
        preview.display(try makeDocument(), data: Data("before".utf8), revision: 1)
        await settleRestoration()
        preview.showActualSize()
        preview.stagingDelay = 0.05
        let committed = expectation(description: "Buffered document committed")
        preview.activeViewDidChange = { _ in committed.fulfill() }
        preview.display(try makeDocument(), data: Data("after".utf8), revision: 2)
        let coordinator = DocumentWindowRestorationCoordinator(sourceURL: url, restorationController: controller)
        coordinator.attach(window: window)
        coordinator.attach(preview: preview)
        coordinator.activate()
        coordinator.previewDidDisplayDocument()
        await settleRestoration()
        XCTAssertEqual(preview.activeView.scaleFactor, 1, accuracy: 0.01)
        await fulfillment(of: [committed], timeout: 2)
        await settleRestoration()
        let restored = try XCTUnwrap(preview.capturePersistedViewport())
        XCTAssertEqual(restored.scaleFactor, 1.35, accuracy: 0.01)
        XCTAssertEqual(restored.pageIndex, 2)
        XCTAssertEqual(restored.normalizedPageY, 0.65, accuracy: 0.01)
        coordinator.deactivate()
    }

    func testSourceMoveUpdatesNativeDocumentAndRestorationIdentity() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let oldURL = URL(fileURLWithPath: "/tmp/Original.md")
        let newURL = URL(fileURLWithPath: "/tmp/Renamed.md")
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 760, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let nativeDocument = NSDocument()
        nativeDocument.fileURL = oldURL
        nativeDocument.addWindowController(NSWindowController(window: window))
        NSDocumentController.shared.addDocument(nativeDocument)
        defer { NSDocumentController.shared.removeDocument(nativeDocument) }
        let coordinator = DocumentWindowRestorationCoordinator(sourceURL: oldURL, restorationController: controller)
        coordinator.attach(window: window)
        coordinator.activate()
        XCTAssertTrue(controller.isDocumentOpen(at: oldURL))
        coordinator.updateSourceURL(newURL)
        coordinator.updateSourceURL(newURL)
        XCTAssertFalse(controller.isDocumentOpen(at: oldURL))
        XCTAssertTrue(controller.isDocumentOpen(at: newURL))
        XCTAssertEqual(window.representedURL, newURL)
        XCTAssertEqual(nativeDocument.fileURL, newURL)
        XCTAssertNil(controller.currentWindowState(for: oldURL))
        XCTAssertNotNil(controller.currentWindowState(for: newURL))
        coordinator.deactivate()
        XCTAssertFalse(controller.isDocumentOpen(at: newURL))
        coordinator.updateSourceURL(nil)
        XCTAssertNil(nativeDocument.fileURL)
    }

    func testSourceMoveBeforeActivationRegistersOnlyNewLocation() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let oldURL = URL(fileURLWithPath: "/tmp/Before.md")
        let newURL = URL(fileURLWithPath: "/tmp/After.md")
        let coordinator = DocumentWindowRestorationCoordinator(sourceURL: oldURL, restorationController: controller)
        coordinator.updateSourceURL(newURL)
        coordinator.activate()
        XCTAssertFalse(controller.isDocumentOpen(at: oldURL))
        XCTAssertTrue(controller.isDocumentOpen(at: newURL))
        coordinator.deactivate()
    }

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
        originalWindow.contentView = originalPreview
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
        restoredWindow.contentView = restoredPreview
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

        await settleRestoration()

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

    func testCoordinatorCapturesAndRestoresThumbnailVisibilityAndWidth() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Sidebar-Restoration.md")
        let originalContainer = PDFPreviewContainerView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 700)
        )
        originalContainer.setThumbnailSidebarWidth(212)
        originalContainer.setThumbnailSidebarVisible(true)
        let originalCoordinator = DocumentWindowRestorationCoordinator(
            sourceURL: url,
            restorationController: controller
        )
        originalCoordinator.attach(previewContainer: originalContainer)
        originalCoordinator.activate()
        let captured = try XCTUnwrap(controller.currentWindowState(for: url))
        XCTAssertEqual(captured.thumbnails, PersistedThumbnailSidebar(
            isVisible: true,
            width: 212,
            scrollOffset: 0
        ))
        originalCoordinator.deactivate()

        let workspace = WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(
                identifier: "sidebar",
                tabs: [.document(url, state: captured)],
                selectedTabIndex: 0,
                isTabBarVisible: false
            )
        ])
        controller.prepareWindowStates(for: workspace)
        let restoredCoordinator = DocumentWindowRestorationCoordinator(
            sourceURL: url,
            restorationController: controller
        )
        let restoredContainer = PDFPreviewContainerView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 700)
        )
        restoredCoordinator.attach(previewContainer: restoredContainer)

        XCTAssertTrue(restoredContainer.isThumbnailSidebarVisible)
        XCTAssertEqual(restoredContainer.thumbnailSidebarWidth, 212, accuracy: 0.5)
    }

    func testCoordinatorCapturesAndRestoresExplicitDocumentPageSetup() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = OpenDocumentRestorationController(defaults: defaults)
        let url = URL(fileURLWithPath: "/tmp/Page-Setup-Restoration.md")
        let setup = DocumentPageSetup(
            paperName: "iso-a4",
            paperSize: CGSize(width: 595, height: 842),
            orientation: .landscape,
            scale: 0.85
        )
        let originalSession = DocumentSession()
        try originalSession.apply(MarkdownDocument(title: "Original", markdown: "# Original"))
        try originalSession.applyExplicitPageSetup(setup)
        let originalCoordinator = DocumentWindowRestorationCoordinator(
            sourceURL: url,
            restorationController: controller,
            session: originalSession
        )
        originalCoordinator.activate()
        let captured = try XCTUnwrap(controller.currentWindowState(for: url))
        XCTAssertEqual(captured.explicitPageSetup, setup)

        try originalSession.clearPageSetupOverride()
        XCTAssertNil(controller.currentWindowState(for: url)?.explicitPageSetup)
        originalCoordinator.deactivate()

        controller.prepareWindowStates(for: WorkspaceSnapshot(groups: [
            WorkspaceWindowGroup(
                identifier: "page",
                tabs: [.document(url, state: captured)],
                selectedTabIndex: 0,
                isTabBarVisible: false
            )
        ]))
        let restoredSession = DocumentSession()
        try restoredSession.apply(MarkdownDocument(title: "Restored", markdown: "# Restored"))
        let restoredCoordinator = DocumentWindowRestorationCoordinator(
            sourceURL: url,
            restorationController: controller,
            session: restoredSession
        )
        restoredCoordinator.activate()

        XCTAssertTrue(restoredSession.hasExplicitPageSetup)
        XCTAssertEqual(restoredSession.activePageSetup, setup)
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

    private func settleRestoration() async {
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "DocumentWindowRestorationCoordinatorTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

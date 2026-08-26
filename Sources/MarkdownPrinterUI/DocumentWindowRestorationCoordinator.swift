import AppKit
import Combine
import MarkdownPrinterCore

@MainActor
package final class DocumentWindowRestorationCoordinator: ObservableObject {
    private let sourceURL: URL?
    private let restorationController: OpenDocumentRestorationController
    private let providerID = UUID()
    private weak var window: NSWindow?
    private weak var preview: BufferedPDFPreviewView?
    private weak var previewContainer: PDFPreviewContainerView?
    private weak var session: DocumentSession?
    private var pendingFrame: CGRect?
    private var pendingViewport: PersistedPreviewViewport?
    private var pendingThumbnails: PersistedThumbnailSidebar?
    private var pendingPageSetup: DocumentPageSetup?
    private var isActive = false
    private var restoreSequence: UInt64 = 0

    package init(
        sourceURL: URL?,
        restorationController: OpenDocumentRestorationController,
        session: DocumentSession? = nil
    ) {
        self.sourceURL = sourceURL
        self.restorationController = restorationController
        self.session = session
        let pendingState = restorationController.takeWindowState(for: sourceURL)
        pendingFrame = pendingState?.frame
        pendingViewport = pendingState?.viewport
        pendingThumbnails = pendingState?.thumbnails
        pendingPageSetup = pendingState?.explicitPageSetup
    }

    package func activate() {
        guard !isActive else { return }
        isActive = true
        restorationController.documentDidOpen(at: sourceURL)
        restorationController.registerStateProvider(
            at: sourceURL,
            id: providerID
        ) { [weak self] in
            self?.captureState()
        }
        applyPendingPageSetupIfPossible()
        applyPendingFrameIfPossible()
        scheduleViewportRestorationIfPossible()
    }

    package func deactivate() {
        guard isActive else { return }
        isActive = false
        restoreSequence &+= 1
        restorationController.unregisterStateProvider(at: sourceURL, id: providerID)
        restorationController.documentDidClose(at: sourceURL)
    }

    package func attach(window: NSWindow?) {
        self.window = window
        applyPendingFrameIfPossible()
        scheduleViewportRestorationIfPossible()
    }

    package func attach(preview: BufferedPDFPreviewView) {
        self.preview = preview
        scheduleViewportRestorationIfPossible()
    }

    package func attach(previewContainer: PDFPreviewContainerView) {
        self.previewContainer = previewContainer
        self.preview = previewContainer.previewView
        if let pendingThumbnails {
            self.pendingThumbnails = nil
            previewContainer.restoreThumbnailRestorationState(pendingThumbnails)
        }
        scheduleViewportRestorationIfPossible()
    }

    package func previewDidDisplayDocument() {
        scheduleViewportRestorationIfPossible()
    }

    private func captureState() -> DocumentWindowRestorationState? {
        let frame = window?.frame
        let viewport = preview?.capturePersistedViewport()
        let thumbnails = previewContainer?.captureThumbnailRestorationState()
        let pageSetup = session?.hasExplicitPageSetup == true
            ? session?.activePageSetup
            : nil
        guard frame != nil || viewport != nil || thumbnails != nil || pageSetup != nil else {
            return nil
        }
        return DocumentWindowRestorationState(
            frame: frame,
            viewport: viewport,
            thumbnails: thumbnails,
            explicitPageSetup: pageSetup
        )
    }

    private func applyPendingPageSetupIfPossible() {
        guard let pendingPageSetup, let session else { return }
        self.pendingPageSetup = nil
        do {
            try session.applyExplicitPageSetup(pendingPageSetup)
        } catch {
            session.report(error: error)
        }
    }

    private func applyPendingFrameIfPossible() {
        guard let pendingFrame, let window else { return }
        self.pendingFrame = nil
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard let adjustedFrame = DocumentWindowFrameRestorationPolicy.adjustedFrame(
            pendingFrame,
            visibleFrames: visibleFrames
        ) else { return }
        window.setFrame(adjustedFrame, display: true)
    }

    private func scheduleViewportRestorationIfPossible() {
        guard isActive,
              window != nil,
              pendingFrame == nil,
              pendingViewport != nil,
              preview?.activeView.document != nil
        else { return }

        restoreSequence &+= 1
        let requestedSequence = restoreSequence
        Task { @MainActor [weak self] in
            await Task.yield()
            await Task.yield()
            guard let self,
                  self.isActive,
                  self.restoreSequence == requestedSequence,
                  let viewport = self.pendingViewport,
                  let preview = self.preview
            else { return }
            self.pendingViewport = nil
            preview.restorePersistedViewport(viewport)
        }
    }
}

package enum DocumentWindowFrameRestorationPolicy {
    package static func adjustedFrame(
        _ frame: CGRect,
        visibleFrames: [CGRect]
    ) -> CGRect? {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0
        else { return nil }
        guard let visibleFrame = bestVisibleFrame(for: frame, in: visibleFrames) else {
            return frame
        }

        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let x = min(
            max(frame.minX, visibleFrame.minX),
            visibleFrame.maxX - width
        )
        let y = min(
            max(frame.minY, visibleFrame.minY),
            visibleFrame.maxY - height
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func bestVisibleFrame(
        for frame: CGRect,
        in visibleFrames: [CGRect]
    ) -> CGRect? {
        guard !visibleFrames.isEmpty else { return nil }
        return visibleFrames.max { first, second in
            let firstIntersection = intersectionArea(frame, first)
            let secondIntersection = intersectionArea(frame, second)
            if firstIntersection != secondIntersection {
                return firstIntersection < secondIntersection
            }
            return squaredDistance(from: frame, to: first)
                > squaredDistance(from: frame, to: second)
        }
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func squaredDistance(from first: CGRect, to second: CGRect) -> CGFloat {
        let deltaX = first.midX - second.midX
        let deltaY = first.midY - second.midY
        return deltaX * deltaX + deltaY * deltaY
    }
}

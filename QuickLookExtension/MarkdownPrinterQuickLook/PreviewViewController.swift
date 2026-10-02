import AppKit
import MarkdownPrinterQuickLookSupport
import QuickLookUI

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let loader = ContinuousPreviewLoader()
    private let renderer = ContinuousPreviewRenderer()

    private var previewView: ContinuousPreviewView {
        view as! ContinuousPreviewView
    }

    override func loadView() {
        view = ContinuousPreviewView(frame: NSRect(x: 0, y: 0, width: 780, height: 900))
        previewView.openURL = { [weak self] url in
            // The host controls app launches from its isolated preview session.
            guard let context = self?.extensionContext else {
                self?.previewView.reportNavigationUnavailable()
                return
            }
            context.open(url) { [weak self] success in
                if !success {
                    Task { @MainActor in self?.previewView.reportNavigationUnavailable() }
                }
            }
        }
        preferredContentSize = NSSize(width: 780, height: 900)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        do {
            let prepared = try await loader.load(at: url)
            try Task.checkCancellation()
            previewView.display(renderer.render(prepared))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ContinuousPreviewError {
            previewView.display(error: error)
        } catch {
            previewView.display(error: .unreadableDocument)
        }
    }
}

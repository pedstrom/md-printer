import AppKit
import MarkdownPrinterCore

/// Keeps the file advertised to the drop destination in sync with the drag badge.
@MainActor
final class ExportDragSession {
    private let payload: ExportDragPayload
    private let store: ExportDragFileStore
    private var artifacts: [ExportFormat: ExportDragArtifact] = [:]
    private(set) var format: ExportFormat
    private var requestedFormat: ExportFormat
    let pasteboardItem = NSPasteboardItem()

    init(payload: ExportDragPayload, modifierFlags: NSEvent.ModifierFlags, store: ExportDragFileStore) throws {
        self.payload = payload
        self.store = store
        let selected = payload.forAction(modifierFlags: modifierFlags)
        format = selected.format
        requestedFormat = selected.format
        let artifact = try selected.materialize(in: store)
        artifacts[format] = artifact
        pasteboardItem.setString(artifact.fileURL.absoluteString, forType: .fileURL)
    }

    /// Mutate the existing pasteboard item; replacing the pasteboard would detach
    /// AppKit's dragging item and can leave destinations with an obsolete file URL.
    func update(modifierFlags: NSEvent.ModifierFlags, pasteboard: NSPasteboard) throws -> Bool {
        let selected = payload.forAction(modifierFlags: modifierFlags)
        guard selected.format != requestedFormat else { return false }
        requestedFormat = selected.format
        guard selected.format != format else { return false }
        let artifact: ExportDragArtifact
        if let cached = artifacts[selected.format] {
            artifact = cached
        } else {
            artifact = try selected.materialize(in: store)
            artifacts[selected.format] = artifact
        }
        guard let item = pasteboard.pasteboardItems?.first,
              item.setString(artifact.fileURL.absoluteString, forType: .fileURL)
        else { throw ExportDragSessionError.unavailablePasteboard }
        format = selected.format
        return true
    }

    func finish(operation: NSDragOperation) {
        for (artifactFormat, artifact) in artifacts {
            store.finish(artifact, operation: artifactFormat == format ? operation : [])
        }
        artifacts.removeAll()
    }
}

enum ExportDragSessionError: LocalizedError {
    case unavailablePasteboard

    var errorDescription: String? {
        "The drag's export format could not be changed. Please try dragging the document again."
    }
}

/// AppKit's drag loop can consume flagsChanged events, including outside the
/// source window. Poll in tracking mode as well as observing local events so a
/// stationary drag updates without requiring Accessibility or Input Monitoring.
@MainActor
final class ExportDragModifierMonitor {
    private var eventMonitor: Any?
    private var timer: Timer?

    func start(
        modifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
        onChange: @escaping (NSEvent.ModifierFlags) -> Void
    ) {
        stop()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseUp]) { event in
            onChange(event.modifierFlags)
            return event
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { onChange(modifierFlags()) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    deinit {
        timer?.invalidate()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }
}

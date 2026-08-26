@preconcurrency import AppKit
import Combine
import MarkdownPrinterCore

@MainActor
package final class DocumentActionController: NSObject, ObservableObject {
    typealias SharePickerPresenter = (NSSharingServicePicker, NSView, NSRect) -> Void

    @Published package private(set) var shareCommandTitle = "Share PDF…"

    private weak var session: DocumentSession?
    private weak var exportPreferences: ExportPreferences?
    private let activityCoordinator: ApplicationActivityCoordinator
    private let fileStore: ExportDragFileStore
    private let revealFiles: ([URL]) -> Void
    private let presentSharePicker: SharePickerPresenter
    private var activeArtifact: ExportDragArtifact?
    private var sharingPicker: NSSharingServicePicker?
    private var selectedSharingService: NSSharingService?
    private weak var toolbarShareAnchor: NSView?
    private var isSharing = false
    private var cancellables: Set<AnyCancellable> = []

    init(
        session: DocumentSession,
        exportPreferences: ExportPreferences,
        activityCoordinator: ApplicationActivityCoordinator,
        fileStore: ExportDragFileStore = ExportDragFileStore(),
        revealFiles: @escaping ([URL]) -> Void = { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        },
        presentSharePicker: @escaping SharePickerPresenter = { picker, view, rect in
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    ) {
        self.session = session
        self.exportPreferences = exportPreferences
        self.activityCoordinator = activityCoordinator
        self.fileStore = fileStore
        self.revealFiles = revealFiles
        self.presentSharePicker = presentSharePicker
        super.init()
        refreshShareTitle()
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        exportPreferences.$defaultFormat
            .sink { [weak self] format in
                self?.shareCommandTitle = "Share \(format.displayName)…"
            }
            .store(in: &cancellables)
    }

    package var canShowInFinder: Bool {
        session?.document?.sourceURL != nil
    }

    package var canShare: Bool {
        session?.hasDocument == true && !isSharing
    }

    package func refreshShareTitle() {
        let name = exportPreferences?.defaultFormat.displayName ?? ExportFormat.pdf.displayName
        shareCommandTitle = "Share \(name)…"
    }

    package func showInFinder() {
        guard let sourceURL = session?.document?.sourceURL else { return }
        revealFiles([sourceURL])
    }

    package func attachToolbarShareAnchor(_ view: NSView?) {
        toolbarShareAnchor = view
    }

    package func share(anchorView: NSView? = nil) {
        guard !isSharing,
              let session,
              let format = exportPreferences?.defaultFormat
        else { return }

        do {
            let artifact = try fileStore.materialize(
                data: session.exportData(as: format),
                fileName: session.suggestedFileName(for: format)
            )
            guard let anchor = anchorView ?? toolbarShareAnchor ?? NSApp.keyWindow?.contentView else {
                fileStore.remove(artifact)
                return
            }

            activityCoordinator.beginBlockingOperation()
            isSharing = true
            activeArtifact = artifact
            let picker = NSSharingServicePicker(items: [artifact.fileURL])
            picker.delegate = self
            sharingPicker = picker
            let anchorRect = anchor === toolbarShareAnchor || anchorView != nil
                ? anchor.bounds
                : NSRect(
                    x: max(anchor.bounds.midX - 16, anchor.bounds.minX),
                    y: max(anchor.bounds.maxY - 32, anchor.bounds.minY),
                    width: 32,
                    height: 32
                )
            presentSharePicker(picker, anchor, anchorRect)
        } catch {
            session.report(error: error)
        }
    }

    package var activeShareFileURL: URL? {
        activeArtifact?.fileURL
    }

    package var isPresentingSharePicker: Bool {
        isSharing
    }

    private func finishSharing(succeeded: Bool, error: Error? = nil) {
        guard isSharing else { return }
        if let activeArtifact {
            if succeeded {
                fileStore.finish(activeArtifact, operation: .copy)
            } else {
                fileStore.remove(activeArtifact)
            }
        }
        activeArtifact = nil
        sharingPicker = nil
        selectedSharingService = nil
        isSharing = false
        activityCoordinator.endBlockingOperation()
        if let error {
            session?.report(error: error)
        }
    }
}

extension DocumentActionController: NSSharingServicePickerDelegate {
    nonisolated package func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        MainActor.assumeIsolated {
            guard let service else {
                finishSharing(succeeded: false)
                return
            }
            selectedSharingService = service
            service.delegate = self
        }
    }
}

extension DocumentActionController: NSSharingServiceDelegate {
    nonisolated package func sharingService(
        _ sharingService: NSSharingService,
        didShareItems items: [Any]
    ) {
        MainActor.assumeIsolated {
            finishSharing(succeeded: true)
        }
    }

    nonisolated package func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: Error
    ) {
        MainActor.assumeIsolated {
            finishSharing(succeeded: false, error: error)
        }
    }
}

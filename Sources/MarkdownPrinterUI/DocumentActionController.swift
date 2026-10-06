@preconcurrency import AppKit
import Combine
import MarkdownPrinterCore

@MainActor
package final class DocumentActionController: NSObject, ObservableObject {
    typealias SavePanelPresenter = @MainActor (ExportFormat, String) -> ExportSaveSelection?
    typealias SharePickerPresenter = (NSSharingServicePicker, NSView, NSRect) -> Void

    @Published package private(set) var shareCommandTitle = "Share PDF…"
    @Published package private(set) var gitPicker: GitRevisionPickerController?
    @Published package private(set) var isGitComparisonActive = false

    private weak var session: DocumentSession?
    private weak var exportPreferences: ExportPreferences?
    private let activityCoordinator: ApplicationActivityCoordinator
    private let presentOriginalPanel: @MainActor () -> URL?
    private let presentSavePanel: SavePanelPresenter
    private let fileStore: ExportDragFileStore
    private let revealFiles: ([URL]) -> Void
    private let presentSharePicker: SharePickerPresenter
    private let gitHistoryService: any GitDocumentHistoryProviding
    private let originalCoordinator: DocumentOriginalCoordinator
    private var gitComparisonSourceURL: URL?
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
        presentSavePanel: @escaping SavePanelPresenter,
        fileStore: ExportDragFileStore = ExportDragFileStore(),
        revealFiles: @escaping ([URL]) -> Void = { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        },
        presentOriginalPanel: @escaping @MainActor () -> URL? = {
            let panel = NSOpenPanel()
            panel.title = "Choose Original Markdown Document"
            panel.allowedContentTypes = [MarkdownFileDocument.markdownContentType]
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        },
        presentSharePicker: @escaping SharePickerPresenter = { picker, view, rect in
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        },
        gitHistoryService: any GitDocumentHistoryProviding = GitDocumentHistoryService(),
        originalCoordinator: DocumentOriginalCoordinator? = nil
    ) {
        self.session = session
        self.exportPreferences = exportPreferences
        self.activityCoordinator = activityCoordinator
        self.presentOriginalPanel = presentOriginalPanel
        self.presentSavePanel = presentSavePanel
        self.fileStore = fileStore
        self.revealFiles = revealFiles
        self.presentSharePicker = presentSharePicker
        self.gitHistoryService = gitHistoryService
        self.originalCoordinator = originalCoordinator ?? .shared
        super.init()
        refreshShareTitle()
        session.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        session.$renderedSnapshot
            .sink { [weak self] snapshot in
                guard let self, let source = self.gitComparisonSourceURL,
                      snapshot?.document.sourceURL?.standardizedFileURL != source else { return }
                self.cancelGitComparison()
            }
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

    package var canSaveAs: Bool {
        session?.hasDocument == true
    }

    package var canShare: Bool {
        session?.hasDocument == true && !isSharing
    }

    package var shareToolTip: String {
        let format = exportPreferences?.defaultFormat ?? .pdf
        return "Share \(format.displayName). Hold Option to share \(format.alternate.displayName)."
    }

    package func refreshShareTitle() {
        let name = exportPreferences?.defaultFormat.displayName ?? ExportFormat.pdf.displayName
        shareCommandTitle = "Share \(name)…"
    }

    package func showInFinder() {
        guard let sourceURL = session?.document?.sourceURL else { return }
        revealFiles([sourceURL])
    }

    package func saveAs() {
        guard let session,
              session.hasDocument,
              let defaultFormat = exportPreferences?.defaultFormat
        else { return }

        activityCoordinator.performBlockingOperation {
            guard let selection = presentSavePanel(
                defaultFormat,
                session.suggestedFileName(for: defaultFormat)
            ) else { return }
            do {
                try session.save(to: selection.url, as: selection.format)
            } catch {
                session.report(error: error)
            }
        }
    }

    package var canCompare: Bool { session?.hasDocument == true }
    package var canClearOriginal: Bool { session?.hasOriginal == true }
    package var canCompareWithGit: Bool { canShowInFinder && !isGitComparisonActive }

    package func compareWithGitVersion() {
        guard canCompareWithGit, let document = session?.document, let url = document.sourceURL else { return }
        let comparisonID = UUID()
        gitComparisonSourceURL = url.standardizedFileURL
        isGitComparisonActive = true
        activityCoordinator.beginBlockingOperation()
        let picker = GitRevisionPickerController(
            id: comparisonID,
            sourceURL: url,
            currentMarkdown: document.markdown,
            service: gitHistoryService,
            applyDocument: { [weak self] original, revision in
                guard let self, let session = self.session,
                      session.document?.sourceURL?.standardizedFileURL == url.standardizedFileURL
                else { throw CancellationError() }
                try Task.checkCancellation()
                let snapshot = OriginalDocumentSnapshot(document: original, gitRevision: revision.commitID)
                try self.originalCoordinator.store.save(snapshot, pending: true)
                do {
                    try await session.setOriginalSnapshot(snapshot, expectedSourceURL: url)
                    self.originalCoordinator.store.consume(snapshot.id)
                } catch {
                    self.originalCoordinator.store.remove(snapshot.id)
                    throw error
                }
            },
            finished: { [weak self, activityCoordinator] in
                if let self {
                    if self.gitPicker?.id == comparisonID { self.gitPicker = nil }
                    self.gitComparisonSourceURL = nil
                    self.isGitComparisonActive = false
                }
                activityCoordinator.endBlockingOperation()
            }
        )
        gitPicker = picker
        picker.load()
    }

    package func cancelGitComparison() {
        let picker = gitPicker
        gitPicker = nil
        picker?.cancel()
    }

    package func compareWithOlderVersion() {
        guard let session, session.hasDocument else { return }
        guard let url = activityCoordinator.performBlockingOperation(presentOriginalPanel) else { return }
        applyOriginal(url: url)
    }

    package func applyOriginal(url: URL) {
        guard let session else { return }
        do {
            let snapshot = OriginalDocumentSnapshot(document: try MarkdownDocument.load(from: url))
            try DocumentOriginalCoordinator.shared.store.save(snapshot, pending: true)
            Task {
                do {
                    try await session.setOriginalSnapshot(snapshot)
                    DocumentOriginalCoordinator.shared.store.consume(snapshot.id)
                } catch {
                    DocumentOriginalCoordinator.shared.store.remove(snapshot.id)
                    session.report(error: error)
                }
            }
        } catch { session.report(error: error) }
    }

    package func clearOriginal() {
        guard let session else { return }
        Task {
            do { try await session.setOriginalSnapshot(nil) }
            catch { session.report(error: error) }
        }
    }

    package func attachToolbarShareAnchor(_ view: NSView?) {
        toolbarShareAnchor = view
    }

    package func share(
        anchorView: NSView? = nil,
        modifierFlags: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        guard !isSharing,
              let session,
              let defaultFormat = exportPreferences?.defaultFormat
        else { return }

        let format = defaultFormat.forAction(modifierFlags: modifierFlags)
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

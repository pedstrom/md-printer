import AppKit
import Combine
import Foundation
import MarkdownPrinterCore

/// Owns Git work and picker state independently of the native sheet.
@MainActor
package final class GitRevisionPickerController: ObservableObject, Identifiable {
    package let id: UUID
    @Published package private(set) var history: GitDocumentHistory?
    @Published package var selectedRevisionID: String?
    @Published package private(set) var isLoading = true
    @Published package private(set) var isComparing = false
    @Published package private(set) var errorMessage: String?

    private let sourceURL: URL
    private let currentMarkdown: String
    private let service: any GitDocumentHistoryProviding
    private let applyDocument: @MainActor (MarkdownDocument, GitDocumentRevision) async throws -> Void
    private var finished: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?
    private var isDismissed = false
    private var windowCloseObservation: AnyCancellable?

    package init(
        id: UUID = UUID(),
        sourceURL: URL,
        currentMarkdown: String,
        service: any GitDocumentHistoryProviding,
        applyDocument: @escaping @MainActor (MarkdownDocument, GitDocumentRevision) async throws -> Void,
        finished: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.currentMarkdown = currentMarkdown
        self.service = service
        self.applyDocument = applyDocument
        self.finished = finished
    }

    package var revisions: [GitDocumentRevision] { history?.revisions ?? [] }
    package var selectedRevision: GitDocumentRevision? {
        revisions.first { $0.id == selectedRevisionID }
    }
    package var canCompare: Bool {
        !isLoading && !isComparing && !isDismissed && selectedRevision != nil
    }

    package func load() {
        guard task == nil, !isDismissed else { return }
        isLoading = true
        errorMessage = nil
        task = Task {
            defer { workFinished() }
            do {
                let history = try await service.history(for: sourceURL)
                let suggested = try await service.suggestedRevision(in: history, currentMarkdown: currentMarkdown)
                try Task.checkCancellation()
                self.history = history
                selectedRevisionID = suggested?.id
            } catch is CancellationError {
                isDismissed = true
            } catch {
                if !isDismissed { errorMessage = error.localizedDescription }
            }
            isLoading = false
        }
    }

    package func compare(revisionID: String) {
        guard !isLoading, !isComparing, !isDismissed,
              revisions.contains(where: { $0.id == revisionID }) else { return }
        selectedRevisionID = revisionID
        compare()
    }

    package func compare() {
        guard canCompare, let history, let revision = selectedRevision else { return }
        isComparing = true
        errorMessage = nil
        task = Task {
            defer { workFinished() }
            do {
                let document = try await service.document(for: revision, in: history)
                try Task.checkCancellation()
                try await applyDocument(document, revision)
                try Task.checkCancellation()
                isDismissed = true
            } catch is CancellationError {
                isDismissed = true
            } catch {
                if !isDismissed { errorMessage = error.localizedDescription }
            }
            isComparing = false
        }
    }

    package func cancel() {
        isDismissed = true
        task?.cancel()
        if task == nil { finish() }
    }

    package func attachWindow(_ window: NSWindow?) {
        windowCloseObservation = window.map { window in
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak self] _ in self?.cancel() }
        }
    }

    private func workFinished() {
        task = nil
        if isDismissed { finish() }
    }

    private func finish() {
        let callback = finished
        finished = nil
        windowCloseObservation = nil
        callback?()
    }
}

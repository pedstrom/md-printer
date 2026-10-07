import AppKit
import SwiftUI
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class GitRevisionPickerTests: XCTestCase {
    private let sourceURL = URL(fileURLWithPath: "/private/tmp/Git picker current.md")

    func testLoadingSelectionAndSuccessfulComparison() async throws {
        let service = service()
        var applied: MarkdownDocument?
        var selected: GitDocumentRevision?
        var finishes = 0
        let picker = picker(service: service, current: "Latest") { document, revision in
            applied = document; selected = revision
        } finished: { finishes += 1 }
        XCTAssertTrue(picker.isLoading)
        XCTAssertFalse(picker.canCompare)
        XCTAssertNil(picker.selectedRevision)
        picker.compare()
        picker.load()
        picker.load()
        try await wait { !picker.isLoading }
        XCTAssertEqual(picker.revisions.count, 2)
        XCTAssertEqual(picker.selectedRevisionID, "old-commit")
        XCTAssertTrue(picker.canCompare)
        picker.selectedRevisionID = "missing"
        XCTAssertFalse(picker.canCompare)
        picker.selectedRevisionID = "latest-commit"
        picker.compare()
        picker.compare()
        try await wait { finishes == 1 }
        XCTAssertEqual(applied?.markdown, "Latest")
        XCTAssertEqual(applied?.sourceModificationDate, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(selected?.id, "latest-commit")
        XCTAssertFalse(picker.isComparing)
        XCTAssertFalse(picker.canCompare)
        picker.cancel(); picker.load()
        XCTAssertEqual(finishes, 1)
    }

    func testDoubleClickConfirmsBothSelectedAndOtherRevisions() async throws {
        for revisionID in ["old-commit", "latest-commit"] {
            var applied: GitDocumentRevision?
            var applications = 0
            var finishes = 0
            let picker = picker(service: service(), current: "Latest", apply: { _, revision in
                applied = revision
                applications += 1
            }, finished: { finishes += 1 })
            picker.load()
            try await wait { !picker.isLoading }
            XCTAssertEqual(picker.selectedRevisionID, "old-commit")
            picker.compare(revisionID: revisionID)
            XCTAssertEqual(picker.selectedRevisionID, revisionID)
            try await wait { finishes == 1 }
            XCTAssertEqual(applied?.id, revisionID)
            XCTAssertEqual(applications, 1)
            XCTAssertFalse(picker.canCompare)
            picker.compare(revisionID: "latest-commit")
            XCTAssertEqual(applications, 1)
            XCTAssertEqual(finishes, 1)
            XCTAssertEqual(picker.selectedRevisionID, revisionID)
        }
    }

    func testGitComparisonCompletesWhenDeletionCalloutsCannotFit() async throws {
        let defaults = makeDefaults()
        defer { defaults.value.removePersistentDomain(forName: defaults.name) }
        let pages = PagePreferences(defaults: defaults.value)
        pages.defaultPageSetup = DocumentPageSetup(paperName: "tiny", paperSize: CGSize(width: 108, height: 108),
            orientation: .portrait, scale: 1)
        let session = DocumentSession(pagePreferences: pages)
        try session.apply(MarkdownDocument(sourceURL: sourceURL, title: "Current", markdown: "Latest"))
        var finishes = 0
        let picker = picker(service: service(), current: "Latest", apply: { document, _ in
            try await session.setOriginalSnapshot(OriginalDocumentSnapshot(document: document))
        }, finished: { finishes += 1 })
        picker.load()
        try await wait { !picker.isLoading }
        picker.compare()
        try await wait { finishes == 1 || picker.errorMessage != nil }
        XCTAssertEqual(finishes, 1)
        XCTAssertNil(picker.errorMessage)
        XCTAssertTrue(session.hasDocument)
        XCTAssertTrue(session.hasOriginal)
        XCTAssertFalse(try XCTUnwrap(session.renderedSnapshot).decorations.deletions.isEmpty)
    }

    func testDoubleClickIgnoresLoadingUnknownAndCancelledRevisions() async throws {
        var applications = 0
        var finishes = 0
        let picker = picker(service: service(), current: "Latest", apply: { _, _ in
            applications += 1
        }, finished: { finishes += 1 })
        picker.compare(revisionID: "latest-commit")
        XCTAssertNil(picker.selectedRevisionID)
        XCTAssertEqual(applications, 0)
        picker.load()
        try await wait { !picker.isLoading }
        picker.compare(revisionID: "unknown")
        XCTAssertEqual(picker.selectedRevisionID, "old-commit")
        XCTAssertTrue(picker.canCompare)
        XCTAssertEqual(applications, 0)
        picker.cancel()
        picker.compare(revisionID: "latest-commit")
        XCTAssertEqual(picker.selectedRevisionID, "old-commit")
        XCTAssertEqual(applications, 0)
        XCTAssertEqual(finishes, 1)
    }

    func testDoubleClickCannotReplaceAnInFlightComparison() async throws {
        let service = service()
        var applications = 0
        var finishes = 0
        let picker = picker(service: service, current: "Latest", apply: { _, _ in
            applications += 1
        }, finished: { finishes += 1 })
        picker.load()
        try await wait { !picker.isLoading }
        await service.configure(delay: .document)
        picker.compare(revisionID: "old-commit")
        try await waitAsync { await service.startedPhase == .document }
        picker.compare(revisionID: "latest-commit")
        XCTAssertEqual(picker.selectedRevisionID, "old-commit")
        XCTAssertTrue(picker.isComparing)
        picker.cancel()
        try await wait { finishes == 1 }
        XCTAssertEqual(applications, 0)
    }

    func testEmptyHistoryAndLoadingFailureCanBeCancelled() async throws {
        for fails in [false, true] {
            let service = service(revisions: [])
            await service.configure(historyFails: fails)
            var finishes = 0
            let picker = picker(service: service, finished: { finishes += 1 })
            picker.load()
            try await wait { !picker.isLoading }
            XCTAssertTrue(picker.revisions.isEmpty)
            XCTAssertFalse(picker.canCompare)
            XCTAssertEqual(picker.errorMessage != nil, fails)
            picker.cancel(); picker.cancel()
            XCTAssertEqual(finishes, 1)
        }
    }

    func testLoadAndCompareErrorsRetainSelectionAndPermitRetry() async throws {
        let service = service()
        await service.configure(suggestionFails: true)
        var applied = false
        var failApplication = true
        var finishes = 0
        let picker = picker(service: service) { _, _ in
            if failApplication { throw PickerTestError.expected }
            applied = true
        } finished: { finishes += 1 }
        picker.load()
        try await wait { !picker.isLoading }
        XCTAssertNotNil(picker.errorMessage)
        await service.configure(suggestionFails: false, documentFails: true)
        picker.load()
        try await wait { !picker.isLoading }
        XCTAssertNil(picker.errorMessage)
        picker.compare()
        try await wait { !picker.isComparing }
        XCTAssertNotNil(picker.errorMessage)
        XCTAssertTrue(picker.canCompare)
        XCTAssertFalse(applied)
        await service.configure(documentFails: false)
        picker.compare()
        try await wait { !picker.isComparing }
        XCTAssertNotNil(picker.errorMessage)
        XCTAssertTrue(picker.canCompare)
        failApplication = false
        picker.compare()
        try await wait { finishes == 1 }
        XCTAssertTrue(applied)
    }

    func testCancellationStopsLoadingSelectionAndComparisonWork() async throws {
        for phase in [PickerTestService.Phase.history, .suggestion, .document] {
            let service = service()
            await service.configure(delay: phase)
            var applied = false
            var finishes = 0
            let picker = picker(service: service, apply: { _, _ in applied = true }, finished: { finishes += 1 })
            picker.load()
            if phase == .document {
                try await wait { !picker.isLoading }
                picker.compare()
            }
            try await waitAsync { await service.startedPhase == phase }
            picker.cancel()
            try await wait { finishes == 1 }
            XCTAssertFalse(applied)
            XCTAssertFalse(picker.canCompare)
            XCTAssertNil(picker.errorMessage)
        }
        var finishes = 0
        let unstarted = picker(service: service(), finished: { finishes += 1 })
        unstarted.cancel(); unstarted.load(); unstarted.compare()
        XCTAssertEqual(finishes, 1)
    }

    func testCancellationDuringApplicationWaitsUntilItUnwinds() async throws {
        var started = false
        var finishes = 0
        let picker = picker(service: service(), apply: { _, _ in
            started = true
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }, finished: { finishes += 1 })
        picker.load()
        try await wait { !picker.isLoading }
        picker.compare()
        try await wait { started }
        picker.cancel()
        XCTAssertEqual(finishes, 0)
        try await wait { finishes == 1 }
        XCTAssertNil(picker.errorMessage)
    }

    func testClosingTheDocumentWindowCancelsPickerWork() async throws {
        let service = service()
        await service.configure(delay: .history)
        var finishes = 0
        let picker = picker(service: service, finished: { finishes += 1 })
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        picker.attachWindow(nil)
        picker.attachWindow(window)
        picker.load()
        try await waitAsync { await service.startedPhase == .history }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        try await wait { finishes == 1 }
        XCTAssertFalse(picker.canCompare)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(finishes, 1)
    }

    func testMenuComparisonPersistsGitMetadataAndProtectsRelaunchThroughApplication() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalCoordinator = DocumentOriginalCoordinator(store: OriginalSnapshotStore(directory: directory))
        let defaults = makeDefaults()
        defer { defaults.value.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.value)
        let session = DocumentSession()
        try session.apply(MarkdownDocument(sourceURL: sourceURL, title: "Current", markdown: "Unsaved changes"))
        let activity = ApplicationActivityCoordinator()
        let actions = DocumentActionController(session: session, exportPreferences: preferences,
            activityCoordinator: activity, presentSavePanel: { _, _ in nil },
            gitHistoryService: service(), originalCoordinator: originalCoordinator)
        XCTAssertTrue(actions.canCompareWithGit)
        actions.compareWithGitVersion()
        XCTAssertTrue(activity.hasActiveBlockingOperation)
        XCTAssertFalse(actions.canCompareWithGit)
        let picker = try XCTUnwrap(actions.gitPicker)
        actions.compareWithGitVersion()
        XCTAssertTrue(actions.gitPicker === picker)
        var relaunched = false
        XCTAssertTrue(activity.postponeRelaunch { relaunched = true })
        try await wait { !picker.isLoading }
        XCTAssertEqual(picker.selectedRevisionID, "latest-commit")
        picker.compare()
        try await wait { !actions.isGitComparisonActive }
        XCTAssertNil(actions.gitPicker)
        XCTAssertTrue(relaunched)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertTrue(actions.canCompareWithGit)
        XCTAssertEqual(session.document?.sourceURL, sourceURL)
        let snapshot = try XCTUnwrap(session.originalSnapshot)
        XCTAssertEqual(snapshot.gitRevision, "latest-commit")
        XCTAssertEqual(snapshot.sourceModificationDate, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try originalCoordinator.store.load(snapshot.id), snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(snapshot.id.uuidString + ".pending").path))
        actions.clearOriginal()
        try await wait { !session.hasOriginal }
    }

    func testMenuCancelAndFailurePreserveExistingOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = DocumentOriginalCoordinator(store: OriginalSnapshotStore(directory: directory))
        let defaults = makeDefaults()
        defer { defaults.value.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.value)
        let session = DocumentSession()
        try session.apply(MarkdownDocument(sourceURL: sourceURL, title: "Current", markdown: "Current"))
        let original = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Original", markdown: "Original"))
        try await session.setOriginalSnapshot(original)
        let service = service()
        await service.configure(documentFails: true)
        let activity = ApplicationActivityCoordinator()
        let actions = DocumentActionController(session: session, exportPreferences: preferences,
            activityCoordinator: activity, presentSavePanel: { _, _ in nil },
            gitHistoryService: service, originalCoordinator: originals)
        actions.compareWithGitVersion()
        let picker = try XCTUnwrap(actions.gitPicker)
        try await wait { !picker.isLoading }
        picker.compare()
        try await wait { !picker.isComparing }
        XCTAssertNotNil(picker.errorMessage)
        XCTAssertEqual(session.originalSnapshot, original)
        XCTAssertTrue(activity.hasActiveBlockingOperation)
        actions.cancelGitComparison()
        XCTAssertNil(actions.gitPicker)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertEqual(session.originalSnapshot, original)
        actions.cancelGitComparison()
    }

    func testLateDismissalOfFinishedPickerLeavesReopenedPickerActive() async throws {
        let defaults = makeDefaults()
        defer { defaults.value.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.value)
        let session = DocumentSession()
        try session.apply(MarkdownDocument(sourceURL: sourceURL, title: "Current", markdown: "Current"))
        let activity = ApplicationActivityCoordinator()
        let actions = DocumentActionController(session: session, exportPreferences: preferences,
            activityCoordinator: activity, presentSavePanel: { _, _ in nil }, gitHistoryService: service())
        actions.compareWithGitVersion()
        let prior = try XCTUnwrap(actions.gitPicker)
        try await wait { !prior.isLoading }
        actions.cancelGitComparison()
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        actions.compareWithGitVersion()
        let reopened = try XCTUnwrap(actions.gitPicker)
        XCTAssertFalse(prior === reopened)
        prior.cancel() // Late teardown belongs to the old controller.
        XCTAssertTrue(actions.gitPicker === reopened)
        XCTAssertTrue(actions.isGitComparisonActive)
        XCTAssertTrue(activity.hasActiveBlockingOperation)
        actions.cancelGitComparison()
        try await wait { !actions.isGitComparisonActive }
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

    func testMenuUnavailableWithoutFileAndSourceSwitchCancelsGitWork() async throws {
        let defaults = makeDefaults()
        defer { defaults.value.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.value)
        let session = DocumentSession()
        let activity = ApplicationActivityCoordinator()
        let service = service()
        await service.configure(delay: .history)
        let actions = DocumentActionController(session: session, exportPreferences: preferences,
            activityCoordinator: activity, presentSavePanel: { _, _ in nil }, gitHistoryService: service)
        XCTAssertFalse(actions.canCompareWithGit)
        actions.compareWithGitVersion()
        try session.apply(MarkdownDocument(title: "Untitled", markdown: "Untitled"))
        XCTAssertFalse(actions.canCompareWithGit)
        actions.compareWithGitVersion()
        try session.apply(MarkdownDocument(sourceURL: sourceURL, title: "File", markdown: "File"))
        actions.compareWithGitVersion()
        try await waitAsync { await service.startedPhase == .history }
        try session.apply(MarkdownDocument(sourceURL: sourceURL.appendingPathExtension("other"), title: "Other", markdown: "Other"))
        XCTAssertNil(actions.gitPicker)
        try await wait { !actions.isGitComparisonActive }
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertFalse(session.hasOriginal)
    }

    func testGitFetchCannotAttachOriginalToAnotherSourceAlreadyBeingPrepared() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originals = DocumentOriginalCoordinator(store: OriginalSnapshotStore(directory: directory))
        let defaults = makeDefaults()
        defer { defaults.value.removePersistentDomain(forName: defaults.name) }
        let session = DocumentSession()
        try session.apply(MarkdownDocument(sourceURL: sourceURL, title: "A", markdown: "Source A"))
        let other = MarkdownDocument(sourceURL: sourceURL.appendingPathExtension("other"), title: "B",
                                     markdown: "# Source B\n\n" + String(repeating: "The other document must retain its own original. ", count: 3_000))
        var preparation: Task<Void, Error>?
        var observedWrongOriginal = false
        let observation = session.$originalSnapshot.sink { snapshot in
            if snapshot?.gitRevision != nil { observedWrongOriginal = true }
        }
        defer { observation.cancel() }
        let service = service()
        await service.beforeReturningDocument {
            preparation = Task { try await session.applyAsync(other) }
            while !session.isPreparingDocument { await Task.yield() }
            XCTAssertEqual(session.document?.sourceURL, self.sourceURL)
        }
        let activity = ApplicationActivityCoordinator()
        let preferences = ExportPreferences(defaults: defaults.value)
        let actions = DocumentActionController(session: session, exportPreferences: preferences,
            activityCoordinator: activity, presentSavePanel: { _, _ in nil },
            gitHistoryService: service, originalCoordinator: originals)
        actions.compareWithGitVersion()
        let picker = try XCTUnwrap(actions.gitPicker)
        try await wait { !picker.isLoading }
        picker.compare()
        try await wait { !actions.isGitComparisonActive }
        try await XCTUnwrap(preparation).value
        XCTAssertEqual(session.document, other)
        XCTAssertFalse(observedWrongOriginal)
        XCTAssertFalse(session.hasOriginal)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

    func testSheetComposesNativeLoadingEmptyErrorAndRevisionStates() async throws {
        for empty in [true, false] {
            let service = service(revisions: empty ? [] : nil)
            var cancels = 0
            let picker = picker(service: service)
            let host = NSHostingView(rootView: GitRevisionPickerView(controller: picker, cancel: { cancels += 1 }))
            host.frame = NSRect(x: 0, y: 0, width: 580, height: 440)
            host.layoutSubtreeIfNeeded()
            picker.load()
            try await wait { !picker.isLoading }
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.frame.width, 580)
            XCTAssertEqual(cancels, 0)
            picker.cancel()
        }
    }

    private func service(revisions: [GitDocumentRevision]? = nil) -> PickerTestService {
        let values = revisions ?? [
            GitDocumentRevision(commitID: "latest-commit", historicalPath: "current.md", subject: "Newest document", committerDate: Date(timeIntervalSince1970: 2_000)),
            GitDocumentRevision(commitID: "old-commit", historicalPath: "old.md", subject: "Original document", committerDate: Date(timeIntervalSince1970: 1_000))
        ]
        return PickerTestService(history: GitDocumentHistory(repositoryURL: sourceURL.deletingLastPathComponent(), sourceURL: sourceURL, revisions: values))
    }

    private func picker(service: PickerTestService, current: String = "Current",
                        apply: @escaping @MainActor (MarkdownDocument, GitDocumentRevision) async throws -> Void = { _, _ in },
                        finished: @escaping @MainActor () -> Void = {}) -> GitRevisionPickerController {
        GitRevisionPickerController(sourceURL: sourceURL, currentMarkdown: current, service: service, applyDocument: apply, finished: finished)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for picker state")
    }

    private func waitAsync(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for Git work")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults() -> (value: UserDefaults, name: String) {
        let name = "GitRevisionPickerTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
}

private enum PickerTestError: LocalizedError {
    case expected
    var errorDescription: String? { "The historical document could not be read." }
}

private actor PickerTestService: GitDocumentHistoryProviding {
    enum Phase { case history, suggestion, document }
    let value: GitDocumentHistory
    var historyFails = false
    var suggestionFails = false
    var documentFails = false
    var delay: Phase?
    var startedPhase: Phase?
    var beforeDocumentReturn: (@MainActor () async throws -> Void)?
    init(history: GitDocumentHistory) { value = history }

    func beforeReturningDocument(_ operation: @escaping @MainActor () async throws -> Void) {
        beforeDocumentReturn = operation
    }

    func configure(historyFails: Bool? = nil, suggestionFails: Bool? = nil,
                   documentFails: Bool? = nil, delay: Phase? = nil) {
        if let historyFails { self.historyFails = historyFails }
        if let suggestionFails { self.suggestionFails = suggestionFails }
        if let documentFails { self.documentFails = documentFails }
        self.delay = delay
    }

    func history(for sourceURL: URL) async throws -> GitDocumentHistory {
        try await begin(.history)
        if historyFails { throw PickerTestError.expected }
        return value
    }

    func suggestedRevision(in history: GitDocumentHistory, currentMarkdown: String) async throws -> GitDocumentRevision? {
        try await begin(.suggestion)
        if suggestionFails { throw PickerTestError.expected }
        return currentMarkdown == "Latest" ? history.revisions.last : history.revisions.first
    }

    func document(for revision: GitDocumentRevision, in history: GitDocumentHistory) async throws -> MarkdownDocument {
        try await begin(.document)
        if documentFails { throw PickerTestError.expected }
        try await beforeDocumentReturn?()
        return MarkdownDocument(sourceURL: history.repositoryURL.appendingPathComponent(revision.historicalPath),
                                sourceModificationDate: revision.committerDate, title: "History",
                                markdown: revision.id == "latest-commit" ? "Latest" : "Original")
    }

    private func begin(_ phase: Phase) async throws {
        startedPhase = phase
        if delay == phase { try await Task.sleep(nanoseconds: 30_000_000_000) }
        try Task.checkCancellation()
    }
}

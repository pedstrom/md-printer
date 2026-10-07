import AppKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionSessionRaceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RevisionSessionRace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testQueuedOriginalIsRetainedUntilRunningSessionReceivesIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginalSnapshotStore(directory: directory.appendingPathComponent("Originals"))
        let coordinator = DocumentOriginalCoordinator(store: store)
        let current = MarkdownDocument(sourceURL: directory.appendingPathComponent("current.md"), title: "Current", markdown: "The date is Tuesday.")
        let session = DocumentSession()
        try session.apply(current)
        _ = try coordinator.register(session, for: current.sourceURL)
        let original = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "The date is Monday."))
        try store.save(original, pending: true)

        try coordinator.enqueue(MarkdownOpenRequest(fileURL: try XCTUnwrap(current.sourceURL), originalID: original.id))
        coordinator.collect(retaining: [])
        XCTAssertEqual(try store.load(original.id), original)
        for _ in 0..<100 where session.originalSnapshot != original || session.isPreparingDocument {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.originalSnapshot, original)
        coordinator.collect(retaining: [])
        XCTAssertEqual(try store.load(original.id), original)
    }

    func testChangingDocumentURLRemovesItsOldSessionRoute() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginalSnapshotStore(directory: directory.appendingPathComponent("Originals"))
        let coordinator = DocumentOriginalCoordinator(store: store)
        let session = DocumentSession()
        let before = directory.appendingPathComponent("before.md")
        let after = directory.appendingPathComponent("after.md")
        _ = try coordinator.register(session, for: before)
        _ = try coordinator.register(session, for: after)
        let original = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "Original"))
        try store.save(original)

        try coordinator.enqueue(MarkdownOpenRequest(fileURL: before, originalID: original.id))
        XCTAssertEqual(try coordinator.register(DocumentSession(), for: before), original)
        XCTAssertFalse(session.hasOriginal)
    }

    func testOriginalReplacementUsesNewestCurrentDocumentWhilePreparing() async throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Before", markdown: "Original current wording."))
        let updated = MarkdownDocument(title: "After", markdown: "# After\n\n" + String(repeating: "The revised content remains live. ", count: 300))
        let refresh = Task { try await session.applyAsync(updated) }
        while !session.isPreparingDocument { await Task.yield() }

        let original = OriginalDocumentSnapshot(document: updated)
        try await session.setOriginalSnapshot(original)
        try await refresh.value
        XCTAssertTrue(session.document == updated)
        XCTAssertEqual(session.originalSnapshot, original)
        XCTAssertEqual(session.renderedSnapshot?.decorations, RevisionDecorations())
    }

    func testCancelledReplacementReturnsToLastSuccessfulOriginal() async throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Current", markdown: "The date is Tuesday."))
        let firstOriginal = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: String(repeating: "A previous draft paragraph. ", count: 300)))
        let first = Task { try await session.setOriginalSnapshot(firstOriginal) }
        while !session.isPreparingDocument { await Task.yield() }
        let replacement = Task { try await session.setOriginalSnapshot(OriginalDocumentSnapshot(document: MarkdownDocument(title: "Other", markdown: "The date is Wednesday."))) }
        replacement.cancel()
        do {
            try await replacement.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        try await first.value

        XCTAssertFalse(session.hasOriginal)
        XCTAssertEqual(session.renderedSnapshot?.decorations, RevisionDecorations())
    }

    func testValidOriginalRequestSupersedesEarlierRestorationError() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginalSnapshotStore(directory: directory.appendingPathComponent("Originals"))
        let coordinator = DocumentOriginalCoordinator(store: store)
        let url = directory.appendingPathComponent("current.md")
        coordinator.reportRestorationError(MarkdownOpenError.invalidOriginal, for: url)
        let snapshot = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "Original"))
        try store.save(snapshot)
        try coordinator.enqueue(MarkdownOpenRequest(fileURL: url, originalID: snapshot.id))
        XCTAssertEqual(try coordinator.register(DocumentSession(), for: url), snapshot)
    }

    func testRevisionPageSetupActionsPrepareAsynchronouslyAndKeepTheOriginal() async throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Current", markdown: "The date is Tuesday."))
        let original = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "The date is Monday."))
        try await session.setOriginalSnapshot(original)
        let explicit = DocumentPageSetup(paperName: "iso-a4", paperSize: CGSize(width: 595, height: 842), orientation: .landscape, scale: 0.9)
        let activity = ApplicationActivityCoordinator()
        var completion: ((NativePageSetupResult) -> Void)?
        let controller = DocumentPageActionController(session: session, activityCoordinator: activity,
            pageSetupPresenter: NativePageSetupPresenter { _, _, _, handler in completion = handler })
        let window = NSWindow()

        controller.showPageSetup(window: window)
        completion?(.accepted(explicit))
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertEqual(session.activePageSetup, .letter)
        for _ in 0..<100 where session.activePageSetup != explicit || session.isPreparingDocument {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.activePageSetup, explicit)
        XCTAssertTrue(session.hasExplicitPageSetup)
        XCTAssertEqual(session.originalSnapshot, original)
        XCTAssertFalse(try XCTUnwrap(session.renderedSnapshot).decorations.deletions.isEmpty)

        controller.showPageSetup(window: window)
        completion?(.useDefault)
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertEqual(session.activePageSetup, explicit)
        for _ in 0..<100 where session.hasExplicitPageSetup || session.isPreparingDocument {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.activePageSetup, .letter)
        XCTAssertFalse(session.hasExplicitPageSetup)
        XCTAssertEqual(session.originalSnapshot, original)
        XCTAssertFalse(try XCTUnwrap(session.renderedSnapshot).decorations.deletions.isEmpty)
    }

    func testAsyncPageSetupCanBePreparedBeforeLoading() async throws {
        let session = DocumentSession()
        let setup = DocumentPageSetup(paperName: "iso-a4", paperSize: CGSize(width: 595, height: 842), orientation: .portrait, scale: 1)
        try await session.applyExplicitPageSetupAsync(setup)
        XCTAssertEqual(session.activePageSetup, setup)
        XCTAssertTrue(session.hasExplicitPageSetup)
        try await session.clearPageSetupOverrideAsync()
        XCTAssertEqual(session.activePageSetup, .letter)
        XCTAssertFalse(session.hasExplicitPageSetup)
    }

    func testAbandonedOriginalHandoffExpiresButReferencedSnapshotSurvives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OriginalSnapshotStore(directory: directory)
        let retained = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Retained", markdown: "Original"))
        let abandoned = OriginalDocumentSnapshot(document: retained.document)
        try store.save(retained, pending: true)
        try store.save(abandoned, pending: true)
        let later = Date().addingTimeInterval(25 * 60 * 60)
        try store.collect(retaining: [retained.id], now: later)
        XCTAssertEqual(try store.load(retained.id), retained)
        XCTAssertThrowsError(try store.load(abandoned.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(abandoned.id.uuidString + ".pending").path))

        let orphan = directory.appendingPathComponent(UUID().uuidString + ".pending")
        try Data().write(to: orphan)
        try store.collect(retaining: [], now: later)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertThrowsError(try store.load(retained.id))
    }

    func testTinyAsyncPageSetupStillPresentsComparisonForExplicitAndDefaultSettings() async throws {
        let suite = "RevisionSessionRace-Pages-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PagePreferences(defaults: defaults)
        let session = DocumentSession(pagePreferences: preferences)
        try session.apply(MarkdownDocument(title: "Current", markdown: "The date is Tuesday."))
        let original = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "The date is Monday."))
        try await session.setOriginalSnapshot(original)
        let snapshot = try XCTUnwrap(session.renderedSnapshot)
        let tiny = DocumentPageSetup(paperName: "tiny", paperSize: CGSize(width: 108, height: 108), orientation: .portrait, scale: 1)
        var completion: ((NativePageSetupResult) -> Void)?
        let controller = DocumentPageActionController(session: session, activityCoordinator: ApplicationActivityCoordinator(),
            pageSetupPresenter: NativePageSetupPresenter { _, _, _, handler in completion = handler })
        let window = NSWindow()
        controller.showPageSetup(window: window)
        completion?(.accepted(tiny))
        for _ in 0..<100 where session.activePageSetup != tiny || session.isPreparingDocument {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(session.activePageSetup, tiny)
        XCTAssertGreaterThan(try XCTUnwrap(session.renderedSnapshot?.revision), snapshot.revision)
        XCTAssertNotNil(session.renderedSnapshot?.pdfData)
        XCTAssertEqual(session.originalSnapshot, original)

        try await session.applyExplicitPageSetupAsync(.letter)
        preferences.defaultPageSetup = tiny
        controller.showPageSetup(window: window)
        completion?(.useDefault)
        for _ in 0..<100 where session.activePageSetup != tiny || session.isPreparingDocument {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.hasExplicitPageSetup)
        XCTAssertEqual(session.activePageSetup, tiny)
        XCTAssertEqual(session.originalSnapshot, original)
    }

    func testOriginalReplacementKeepsAPageSetupAlreadyBeingPrepared() async throws {
        let document = MarkdownDocument(title: "Current", markdown: "# Current\n\n" + String(repeating: "The current document remains live. ", count: 300))
        let session = DocumentSession()
        try session.apply(document)
        try await session.setOriginalSnapshot(OriginalDocumentSnapshot(document: document))
        let landscape = DocumentPageSetup(paperName: "na-letter", paperSize: CGSize(width: 612, height: 792), orientation: .landscape, scale: 1)
        let preparation = Task { try await session.applyExplicitPageSetupAsync(landscape) }
        while !session.isPreparingDocument { await Task.yield() }
        try await session.setOriginalSnapshot(nil)
        try await preparation.value

        XCTAssertEqual(session.activePageSetup, landscape)
        XCTAssertTrue(session.hasExplicitPageSetup)
        XCTAssertFalse(session.hasOriginal)
        XCTAssertTrue(session.document == document)
    }

    func testTinyPageComparisonKeepsLiveMonitoringThroughClearingOriginal() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("current.md")
        try Data("The date is Tuesday.".utf8).write(to: current)
        let suite = "RevisionSessionRace-Recovery-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PagePreferences(defaults: defaults)
        preferences.defaultPageSetup = DocumentPageSetup(paperName: "tiny", paperSize: CGSize(width: 108, height: 108), orientation: .portrait, scale: 1)
        var monitor: RevisionRecoveryMonitor?
        let session = DocumentSession(pagePreferences: preferences, sourceMonitorFactory: { url, changed in
            let created = RevisionRecoveryMonitor(sourceURL: url, changed: changed)
            monitor = created
            return created
        })
        defer { session.stopMonitoringSourceChanges() }
        try await session.setOriginalSnapshot(OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "The date is Monday.")))
        try await session.applyAsync(MarkdownDocument.load(from: current))
        XCTAssertTrue(session.hasDocument)
        XCTAssertTrue(session.hasOriginal)
        session.startMonitoringSourceChanges()
        let activeMonitor = try XCTUnwrap(monitor)
        XCTAssertTrue(activeMonitor.isMonitoring)

        try await session.setOriginalSnapshot(nil)
        XCTAssertTrue(session.hasDocument)
        let recoveredMonitor = try XCTUnwrap(monitor)
        XCTAssertTrue(recoveredMonitor === activeMonitor)
        XCTAssertTrue(recoveredMonitor.isMonitoring)
        try await session.applyExplicitPageSetupAsync(.letter)
        XCTAssertTrue(monitor === recoveredMonitor)
        try Data("The date is Wednesday.".utf8).write(to: current, options: .atomic)
        monitor?.fireChange()
        XCTAssertTrue(session.document?.markdown.contains("Wednesday") == true)
        XCTAssertFalse(session.hasOriginal)
    }
}

@MainActor
private final class RevisionRecoveryMonitor: SourceChangeMonitoring {
    let sourceURL: URL
    private let changed: () -> Void
    private(set) var isMonitoring = false
    init(sourceURL: URL, changed: @escaping () -> Void) { self.sourceURL = sourceURL; self.changed = changed }
    func start() { isMonitoring = true }
    func stop() { isMonitoring = false }
    func fireChange() { if isMonitoring { changed() } }
}

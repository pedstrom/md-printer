import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionMetadataSessionTests: XCTestCase {
    private let originalDate = Date(timeIntervalSince1970: 1_750_000_000)
    private let currentDate = Date(timeIntervalSince1970: 1_790_000_000)

    private func document(date: Date?, text: String = "# Dates\n\nThe document remains live.") -> MarkdownDocument {
        MarkdownDocument(sourceURL: URL(fileURLWithPath: "/private/tmp/revision-dates.md"),
                         sourceModificationDate: date, title: "Dates", markdown: text)
    }

    private func preferences() throws -> (PagePreferences, UserDefaults, String) {
        let suite = "RevisionMetadata-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = PagePreferences(defaults: defaults)
        preferences.leftFooter = .dateTimeWithTimeZone
        preferences.rightFooter = .date
        return (preferences, defaults, suite)
    }

    func testSnapshotPreservesTimestampAndGitIdentityAndDecodesLegacyMetadata() throws {
        let snapshot = OriginalDocumentSnapshot(document: document(date: originalDate), gitRevision: "abc123")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(OriginalDocumentSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.document.sourceModificationDate, originalDate)
        XCTAssertEqual(decoded.gitRevision, "abc123")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "sourceModificationDate")
        legacy.removeValue(forKey: "gitRevision")
        let older = try JSONDecoder().decode(OriginalDocumentSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(older.document.sourceModificationDate)
        XCTAssertNil(older.gitRevision)
        XCTAssertEqual(older.markdown, snapshot.markdown)
    }

    func testCLIOriginalDateSurvivesRemovalAndSnapshotStoreReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("current.md"), older = directory.appendingPathComponent("older.md")
        try Data("# Current".utf8).write(to: current)
        try Data("# Older".utf8).write(to: older)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: older.path)
        let store = OriginalSnapshotStore(directory: directory.appendingPathComponent("snapshots"))
        let request = try XCTUnwrap(MarkdownOpenArguments.parse(["open", current.path, "--original", older.path]).requests(store: store).first)
        try FileManager.default.removeItem(at: older)
        let snapshot = try store.load(XCTUnwrap(request.originalID))
        XCTAssertEqual(snapshot.sourceModificationDate, originalDate)
        XCTAssertEqual(snapshot.document.sourceModificationDate, originalDate)
    }

    func testComparisonFootersRefreshRestoreReplaceAndClearWithSession() async throws {
        let (preferences, defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = DocumentSession(pagePreferences: preferences)
        try session.apply(document(date: currentDate))
        let original = OriginalDocumentSnapshot(document: document(date: originalDate), gitRevision: "original-commit")
        try await session.setOriginalSnapshot(original)
        XCTAssertEqual(session.renderedSnapshot?.footers.leftLines.map(\.style), [.current, .original])
        XCTAssertEqual(session.renderedSnapshot?.footers.rightLines.count, 2)
        let oldFooter = try XCTUnwrap(session.renderedSnapshot?.footers.leftLines.last)
        let refreshed = document(date: currentDate.addingTimeInterval(86_400))
        try session.apply(refreshed)
        XCTAssertEqual(session.originalSnapshot?.sourceModificationDate, originalDate)
        XCTAssertEqual(session.renderedSnapshot?.footers.leftLines.last, oldFooter)
        XCTAssertEqual(session.renderedSnapshot?.footers.leftLines.first?.text, FooterValue.dateTimeWithTimeZone.resolved(for: refreshed))

        let restored = DocumentSession(pagePreferences: preferences)
        let restoredSnapshot = try JSONDecoder().decode(OriginalDocumentSnapshot.self, from: JSONEncoder().encode(original))
        try await restored.setOriginalSnapshot(restoredSnapshot)
        try await restored.applyAsync(refreshed)
        XCTAssertEqual(restored.renderedSnapshot?.footers, session.renderedSnapshot?.footers)

        preferences.leftFooter = .filename
        for _ in 0..<100 where session.isPreparingDocument || session.renderedSnapshot?.footers.left != "revision-dates.md" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.renderedSnapshot?.footers.leftLines.map(\.style), [.ordinary])
        preferences.leftFooter = .date
        let replacement = OriginalDocumentSnapshot(document: refreshed)
        try await session.setOriginalSnapshot(replacement)
        for _ in 0..<100 where session.isPreparingDocument { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.renderedSnapshot?.footers.leftLines, [.init(text: FooterValue.date.resolved(for: refreshed))])
        try await session.setOriginalSnapshot(nil)
        XCTAssertEqual(session.renderedSnapshot?.footers.rightLines.map(\.style), [.ordinary])
        XCTAssertEqual(session.renderedSnapshot?.footers.right, FooterValue.date.resolved(for: refreshed))
    }

    func testMissingOriginalDateAndCancelledReplacementRetainCommittedFooter() async throws {
        let (preferences, defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = DocumentSession(pagePreferences: preferences)
        try session.apply(document(date: currentDate))
        try await session.setOriginalSnapshot(OriginalDocumentSnapshot(document: document(date: nil)))
        XCTAssertEqual(session.renderedSnapshot?.footers.leftLines.map(\.style), [.ordinary])
        let known = OriginalDocumentSnapshot(document: document(date: originalDate))
        try await session.setOriginalSnapshot(known)
        let footer = try XCTUnwrap(session.renderedSnapshot?.footers)
        let replacement = Task { try await session.setOriginalSnapshot(OriginalDocumentSnapshot(document: self.document(date: self.currentDate))) }
        replacement.cancel()
        do { try await replacement.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(session.originalSnapshot, known)
        XCTAssertEqual(session.renderedSnapshot?.footers, footer)
    }
    func testGitSourceGuardRejectsPendingDifferentDocument() async throws {
        let session = DocumentSession()
        let before = document(date: currentDate)
        try session.apply(before)
        let after = MarkdownDocument(sourceURL: URL(fileURLWithPath: "/private/tmp/other-file.md"),
                                     sourceModificationDate: currentDate,
                                     title: "Other", markdown: String(repeating: "The other source is still loading.\n\n", count: 200))
        let preparation = Task { try await session.applyAsync(after) }
        while !session.isPreparingDocument { await Task.yield() }
        do {
            try await session.setOriginalSnapshot(OriginalDocumentSnapshot(document: document(date: originalDate)),
                                                  expectedSourceURL: try XCTUnwrap(before.sourceURL))
            XCTFail("Must not apply a Git original to a different pending source")
        } catch is CancellationError { }
        try await preparation.value
        XCTAssertEqual(session.document, after)
        XCTAssertFalse(session.hasOriginal)
    }

    func testCancelledOriginalIsRolledBackWhenRefreshSupersedesItsRender() async throws {
        let (preferences, defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = DocumentSession(pagePreferences: preferences)
        let before = document(date: currentDate)
        try session.apply(before)
        let prior = OriginalDocumentSnapshot(document: document(date: originalDate))
        try await session.setOriginalSnapshot(prior)
        let replacement = OriginalDocumentSnapshot(document: document(date: currentDate,
            text: before.markdown + "\n\n" + String(repeating: "A replacement is being prepared. ", count: 200)))
        let replacing = Task { try await session.setOriginalSnapshot(replacement) }
        while !session.isPreparingDocument { await Task.yield() }
        let refreshed = document(date: currentDate.addingTimeInterval(86_400))
        try session.apply(refreshed) // A refresh commits the pending replacement.
        XCTAssertEqual(session.originalSnapshot, replacement)
        replacing.cancel()
        do { try await replacing.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(session.document, refreshed)
        XCTAssertEqual(session.originalSnapshot, prior)
        XCTAssertEqual(session.renderedSnapshot?.footers, preferences.resolvedFooters(for: refreshed, original: prior.document))
        XCTAssertEqual(session.renderedSnapshot?.decorations, RevisionDecorations())
    }

}

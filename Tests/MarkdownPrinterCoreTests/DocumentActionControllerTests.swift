import AppKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class DocumentActionControllerTests: XCTestCase {
    func testFinderActionAndShareTitleFollowTheFocusedDocumentAndPreference() throws {
        let defaults = makeDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.defaults)
        let session = DocumentSession()
        let sourceURL = URL(fileURLWithPath: "/tmp/Quarterly Notes.md")
        try session.apply(MarkdownDocument(
            sourceURL: sourceURL,
            title: "Quarterly Notes",
            markdown: "# Quarterly Notes"
        ))
        var revealedURLs: [URL] = []
        let controller = DocumentActionController(
            session: session,
            exportPreferences: preferences,
            activityCoordinator: ApplicationActivityCoordinator(),
            revealFiles: { revealedURLs = $0 }
        )

        XCTAssertTrue(controller.canShowInFinder)
        XCTAssertTrue(controller.canShare)
        XCTAssertEqual(controller.shareCommandTitle, "Share PDF…")
        controller.showInFinder()
        XCTAssertEqual(revealedURLs, [sourceURL])

        preferences.defaultFormat = .word
        XCTAssertEqual(controller.shareCommandTitle, "Share Microsoft Word…")
    }

    func testShareMaterializesExactPreferredBytesAndCancellationCleansUp() throws {
        let defaults = makeDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.defaults)
        preferences.defaultFormat = .word
        let session = DocumentSession()
        try session.apply(MarkdownDocument(
            sourceURL: URL(fileURLWithPath: "/tmp/Share Me.md"),
            title: "Share Me",
            markdown: "# Share Me\n\nEditable"
        ))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let activity = ApplicationActivityCoordinator()
        var presentedPicker: NSSharingServicePicker?
        let controller = DocumentActionController(
            session: session,
            exportPreferences: preferences,
            activityCoordinator: activity,
            fileStore: ExportDragFileStore(temporaryDirectory: temporaryDirectory),
            presentSharePicker: { picker, _, _ in presentedPicker = picker }
        )

        controller.share(anchorView: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))

        let fileURL = try XCTUnwrap(controller.activeShareFileURL)
        XCTAssertEqual(fileURL.lastPathComponent, "Share Me.docx")
        XCTAssertEqual(try Data(contentsOf: fileURL), try session.exportData(as: .word))
        XCTAssertTrue(activity.hasActiveBlockingOperation)
        XCTAssertTrue(controller.isPresentingSharePicker)

        controller.sharingServicePicker(try XCTUnwrap(presentedPicker), didChoose: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertFalse(controller.isPresentingSharePicker)
    }

    func testSuccessfulShareRetainsThenSchedulesCleanup() throws {
        let defaults = makeDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.defaults)
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Shared", markdown: "# Shared"))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var cleanup: DispatchWorkItem?
        let store = ExportDragFileStore(
            temporaryDirectory: temporaryDirectory,
            scheduleCleanup: { _, workItem in cleanup = workItem }
        )
        let activity = ApplicationActivityCoordinator()
        let controller = DocumentActionController(
            session: session,
            exportPreferences: preferences,
            activityCoordinator: activity,
            fileStore: store,
            presentSharePicker: { _, _, _ in }
        )
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        controller.share(anchorView: anchor)
        let fileURL = try XCTUnwrap(controller.activeShareFileURL)
        let service = NSSharingService(
            title: "Test Share",
            image: NSImage(),
            alternateImage: nil,
            handler: { }
        )

        controller.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: service)
        controller.sharingService(service, didShareItems: [fileURL])

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        try XCTUnwrap(cleanup).perform()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUnavailableActionsAreNoOpsAndSessionChangesAreForwarded() throws {
        let defaults = makeDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.defaults)
        let session = DocumentSession()
        var revealedURLs: [URL] = []
        let controller = DocumentActionController(
            session: session,
            exportPreferences: preferences,
            activityCoordinator: ApplicationActivityCoordinator(),
            revealFiles: { revealedURLs = $0 },
            presentSharePicker: { _, _, _ in XCTFail("Share picker should not be presented") }
        )
        let changed = expectation(description: "controller forwards session changes")
        changed.assertForOverFulfill = false
        let observation = controller.objectWillChange.sink { changed.fulfill() }

        XCTAssertFalse(controller.canShowInFinder)
        XCTAssertFalse(controller.canShare)
        controller.showInFinder()
        controller.share(anchorView: NSView())
        XCTAssertTrue(revealedURLs.isEmpty)

        try session.apply(MarkdownDocument(title: "Ready", markdown: "# Ready"))
        wait(for: [changed], timeout: 1)
        XCTAssertTrue(controller.canShare)
        withExtendedLifetime(observation) {}
    }

    func testShareFailureReportsErrorAndCleansUp() throws {
        let defaults = makeDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.defaults)
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Failure", markdown: "# Failure"))
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let activity = ApplicationActivityCoordinator()
        let controller = DocumentActionController(
            session: session,
            exportPreferences: preferences,
            activityCoordinator: activity,
            fileStore: ExportDragFileStore(temporaryDirectory: temporaryDirectory),
            presentSharePicker: { _, _, _ in }
        )
        controller.share(anchorView: NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24)))
        let fileURL = try XCTUnwrap(controller.activeShareFileURL)
        let service = NSSharingService(
            title: "Test Share",
            image: NSImage(),
            alternateImage: nil,
            handler: { }
        )

        controller.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: service)
        controller.sharingService(
            service,
            didFailToShareItems: [fileURL],
            error: ShareTestError.example
        )

        XCTAssertEqual(session.errorMessage, "Example failure")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(activity.hasActiveBlockingOperation)
    }

    func testMaterializationFailureUsesDocumentErrorPresentation() throws {
        let defaults = makeDefaults()
        defer { defaults.defaults.removePersistentDomain(forName: defaults.name) }
        let preferences = ExportPreferences(defaults: defaults.defaults)
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Cannot Share", markdown: "# Cannot Share"))
        let controller = DocumentActionController(
            session: session,
            exportPreferences: preferences,
            activityCoordinator: ApplicationActivityCoordinator(),
            fileStore: ExportDragFileStore(temporaryDirectory: URL(fileURLWithPath: "/dev/null/share")),
            presentSharePicker: { _, _, _ in XCTFail("Share picker should not be presented") }
        )

        controller.share(anchorView: NSView())

        XCTAssertNotNil(session.errorMessage)
        XCTAssertFalse(controller.isPresentingSharePicker)
    }

    private func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "DocumentActionControllerTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

private enum ShareTestError: LocalizedError {
    case example

    var errorDescription: String? { "Example failure" }
}

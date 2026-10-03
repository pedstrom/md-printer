import AppKit
import Combine
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class SourceRecoveryTests: XCTestCase {
    func testMissingSourceKeepsPreviewAndShowsOnlyDelayedStatus() async throws {
        let url = try makeSource()
        let (session, monitor) = try makeSession(url: url)
        defer { session.stopMonitoringSourceChanges() }
        let snapshot = try XCTUnwrap(session.renderedSnapshot)
        try FileManager.default.removeItem(at: url)
        monitor.trigger()
        XCTAssertFalse(session.isSourceUnavailable)
        XCTAssertNil(session.errorMessage)
        await waitUntil { session.isSourceUnavailable }
        XCTAssertEqual(session.renderedSnapshot?.revision, snapshot.revision)
        XCTAssertEqual(try session.pdfData(), snapshot.pdfData)
        XCTAssertNil(session.errorMessage)
        XCTAssertEqual(DocumentSession.sourceUnavailableMessage,
                       "Source file unavailable. Showing the last rendered version.")
        monitor.trigger()
        XCTAssertTrue(session.isSourceUnavailable)
    }

    func testIdenticalContentReturnsWithoutNotificationAndClearsBannerWithoutRenderingAgain() async throws {
        let url = try makeSource()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let (session, monitor) = try makeSession(url: url)
        defer { session.stopMonitoringSourceChanges() }
        let document = try XCTUnwrap(session.document)
        let revision = session.renderedSnapshot?.revision
        try FileManager.default.removeItem(at: url)
        monitor.trigger()
        await waitUntil { session.isSourceUnavailable }
        try Data(document.markdown.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        XCTAssertEqual(try MarkdownDocument.load(from: url), document)
        await waitUntil { !session.isSourceUnavailable }
        XCTAssertEqual(session.renderedSnapshot?.revision, revision)
        XCTAssertNil(session.errorMessage)
    }

    func testShortAbsenceNeverShowsBannerAndChangedContentRefreshes() async throws {
        let url = try makeSource()
        let (session, monitor) = try makeSession(url: url, grace: 0.1)
        defer { session.stopMonitoringSourceChanges() }
        let unexpectedBanner = expectation(description: "no transient banner")
        unexpectedBanner.isInverted = true
        let observation = session.$isSourceUnavailable.filter { $0 }.sink { _ in unexpectedBanner.fulfill() }
        defer { observation.cancel() }
        try FileManager.default.removeItem(at: url)
        monitor.trigger()
        try Data("# Rewritten\n\nNew content.".utf8).write(to: url)
        monitor.trigger()
        XCTAssertEqual(session.title, "Rewritten")
        XCTAssertNil(session.errorMessage)
        await fulfillment(of: [unexpectedBanner], timeout: 0.15)
    }

    func testBackgroundDecodeFailureAndRecoveryDoNotDismissAnUnrelatedActionError() async throws {
        let url = try makeSource()
        let (session, monitor) = try makeSession(url: url)
        defer { session.stopMonitoringSourceChanges() }
        session.report(error: CocoaError(.fileWriteNoPermission))
        let actionError = session.errorMessage
        let pdf = session.renderedPDFData
        try Data([0xFF]).write(to: url)
        monitor.trigger()
        await waitUntil { session.isSourceUnavailable }
        XCTAssertEqual(session.errorMessage, actionError)
        XCTAssertEqual(session.renderedPDFData, pdf)
        // Changing output settings while the source is unavailable must keep recovery active.
        try session.applyExplicitPageSetup(.letter)
        XCTAssertTrue(session.isSourceUnavailable)
        session.report(error: CocoaError(.fileWriteNoPermission))
        try Data("# Recovered".utf8).write(to: url)
        await waitUntil { !session.isSourceUnavailable }
        XCTAssertEqual(session.title, "Recovered")
        XCTAssertEqual(session.errorMessage, actionError)
    }

    func testStoppingOrSwitchingDocumentsCancelsOldRecovery() async throws {
        let url = try makeSource()
        var monitors: [RecoverySourceMonitor] = []
        let session = DocumentSession(sourceMonitorFactory: { url, change in
            let monitor = RecoverySourceMonitor(sourceURL: url, onChange: change)
            monitors.append(monitor)
            return monitor
        }, sourceRecoveryGraceInterval: 0.02)
        session.load(url: url)
        session.startMonitoringSourceChanges()
        try FileManager.default.removeItem(at: url)
        monitors[0].trigger()
        await waitUntil { session.isSourceUnavailable }
        let otherURL = url.deletingLastPathComponent().appendingPathComponent("Other.md")
        try Data("# Other".utf8).write(to: otherURL)
        session.load(url: otherURL)
        XCTAssertEqual(monitors.count, 2)
        XCTAssertFalse(monitors[0].isMonitoring)
        XCTAssertFalse(session.isSourceUnavailable)
        monitors[0].trigger()
        XCTAssertEqual(session.title, "Other")
        try FileManager.default.removeItem(at: otherURL)
        monitors[1].trigger()
        await waitUntil { session.isSourceUnavailable }
        session.stopMonitoringSourceChanges()
        XCTAssertFalse(session.isSourceUnavailable)
        try Data("# Should not refresh".utf8).write(to: otherURL)
        monitors[1].trigger()
        XCTAssertEqual(session.title, "Other")
        // A fileless document also stops the old monitor.
        session.startMonitoringSourceChanges()
        try session.apply(MarkdownDocument(title: "Memory", markdown: "Memory body"))
        XCTAssertFalse(monitors.last!.isMonitoring)
        XCTAssertNil(session.document?.sourceURL)
    }

    func testMovedSourceRefreshesFilenameRelativeImagesAndLinksAndLaterWrites() async throws {
        let url = try makeSource(markdown: "[Sibling](sibling.md)\n\n![Photo](photo.png)")
        let directory = url.deletingLastPathComponent().appendingPathComponent("New Folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newURL = directory.appendingPathComponent("Renamed.md")
        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("photo.png"))
        let session = DocumentSession()
        session.load(url: url)
        session.startMonitoringSourceChanges()
        defer { session.stopMonitoringSourceChanges() }
        try FileManager.default.moveItem(at: url, to: newURL)
        await waitUntil { session.document?.sourceURL == newURL }
        XCTAssertEqual(session.title, "Renamed")
        XCTAssertEqual(session.suggestedPDFFileName, "Renamed.pdf")
        XCTAssertEqual(session.suggestedWordFileName, "Renamed.docx")
        XCTAssertEqual(session.renderedText.attribute(.link, at: 0, effectiveRange: nil) as? URL,
                       directory.appendingPathComponent("sibling.md"))
        var attachments = 0
        session.renderedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: session.renderedText.length)) { value, _, _ in
            if value is NSTextAttachment { attachments += 1 }
        }
        XCTAssertEqual(attachments, 1)
        try Data("# Later write".utf8).write(to: newURL, options: .atomic)
        await waitUntil { session.title == "Later write" }
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.isSourceUnavailable)
    }

    func testRenameToTemporarilyUnavailableLocationRecoversAutomatically() async throws {
        let url = try makeSource()
        let (session, monitor) = try makeSession(url: url)
        defer { session.stopMonitoringSourceChanges() }
        let newURL = url.deletingLastPathComponent().appendingPathComponent("Moved.md")
        try FileManager.default.removeItem(at: url)
        monitor.move(to: newURL)
        await waitUntil { session.isSourceUnavailable }
        XCTAssertEqual(session.document?.sourceURL, url)
        try Data("# Moved and restored".utf8).write(to: newURL)
        await waitUntil { session.document?.sourceURL == newURL }
        XCTAssertFalse(session.isSourceUnavailable)
        XCTAssertNil(session.errorMessage)
    }

    func testRecreatedParentFolderRestoresMonitoringAndFollowsItsNextMove() async throws {
        let url = try makeSource()
        let directory = url.deletingLastPathComponent()
        let newDirectory = directory.appendingPathExtension("moved")
        addTeardownBlock { try? FileManager.default.removeItem(at: newDirectory) }
        let session = DocumentSession(sourceMonitorFactory: { url, change in
            SourceFileMonitor(sourceURL: url, onChange: change)
        }, sourceRecoveryGraceInterval: 0.03)
        session.load(url: url)
        session.startMonitoringSourceChanges()
        defer { session.stopMonitoringSourceChanges() }
        try FileManager.default.removeItem(at: directory)
        await waitUntil { session.isSourceUnavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("# Recreated folder".utf8).write(to: url)
        await waitUntil { session.title == "Recreated folder" }
        XCTAssertFalse(session.isSourceUnavailable)
        try FileManager.default.moveItem(at: directory, to: newDirectory)
        let newURL = newDirectory.appendingPathComponent(url.lastPathComponent)
        await waitUntil { session.document?.sourceURL == newURL }
        try Data("# Still watching".utf8).write(to: newURL)
        await waitUntil { session.title == "Still watching" }
        XCTAssertNil(session.errorMessage)
    }

    private func makeSource(markdown: String = "# Source\n\nOriginal body.") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Source.md")
        try Data(markdown.utf8).write(to: url)
        return url
    }

    private func makeSession(url: URL, grace: TimeInterval = 0.03) throws -> (DocumentSession, RecoverySourceMonitor) {
        var monitor: RecoverySourceMonitor?
        let session = DocumentSession(sourceMonitorFactory: { url, change in
            let created = RecoverySourceMonitor(sourceURL: url, onChange: change)
            monitor = created
            return created
        }, sourceRecoveryGraceInterval: grace)
        session.load(url: url)
        session.startMonitoringSourceChanges()
        return (session, try XCTUnwrap(monitor))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for source recovery state")
    }
}

@MainActor
private final class RecoverySourceMonitor: SourceChangeMonitoring {
    private(set) var sourceURL: URL
    private(set) var isMonitoring = false
    private let onChange: () -> Void
    init(sourceURL: URL, onChange: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.onChange = onChange
    }
    func start() { isMonitoring = true }
    func stop() { isMonitoring = false }
    func trigger() { if isMonitoring { onChange() } }
    func move(to url: URL) { sourceURL = url; trigger() }
}

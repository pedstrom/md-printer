import AppKit
import PDFKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class RevisionOpeningTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RevisionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testOpeningArgumentsAreExplicitAndPreserveMultipleFiles() throws {
        let dir = URL(fileURLWithPath: "/private/tmp")
        let two = try MarkdownOpenArguments.parse(["open", "one.md", "two.markdown"], directory: dir)
        XCTAssertEqual(two.files.map(\.lastPathComponent), ["one.md", "two.markdown"])
        XCTAssertNil(two.original)
        let marked = try MarkdownOpenArguments.parse(["open", "--original", "old.md", "new.md"], directory: dir)
        XCTAssertEqual(marked.original?.lastPathComponent, "old.md")
        XCTAssertEqual(marked.files.first?.path, "/private/tmp/new.md")
        for args in [["open"], ["wrong", "one.md"], ["open", "one.md", "--original"],
                     ["open", "one.md", "two.md", "--original", "old.md"],
                     ["open", "one.md", "--original", "old.md", "--original", "other.md"],
                     ["open", "one.md", "--other"], ["open", "one.pdf"], ["open", "one.md", "--original", "--other"]] {
            XCTAssertThrowsError(try MarkdownOpenArguments.parse(args))
        }
        XCTAssertNotNil(MarkdownOpenError.arguments.errorDescription)
        XCTAssertNotNil(MarkdownOpenError.invalidOriginal.errorDescription)
    }
    func testRequestURLsAndOriginalSnapshotSurviveTemporaryFileRemoval() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = OriginalSnapshotStore(directory: dir.appendingPathComponent("Originals"))
        let old = dir.appendingPathComponent("older.md"), new = dir.appendingPathComponent("current # café.md")
        try Data("# Original\n\nMonday".utf8).write(to: old)
        try Data("# Current\n\nTuesday".utf8).write(to: new)
        let args = try MarkdownOpenArguments.parse(["open", new.path, "--original", old.path])
        let request = try XCTUnwrap(args.requests(store: store).first)
        XCTAssertEqual(try MarkdownOpenRequest.parse(request.url), request)
        try FileManager.default.removeItem(at: old)
        let snapshot = try store.load(XCTUnwrap(request.originalID))
        XCTAssertEqual(snapshot.document.markdown, "# Original\n\nMonday")
        XCTAssertEqual(snapshot.document.sourceURL, old)
        try store.collect(retaining: []) // Pending handoffs are protected.
        XCTAssertEqual(try store.load(snapshot.id), snapshot)
        store.consume(snapshot.id)
        try store.collect(retaining: [snapshot.id])
        XCTAssertEqual(try store.load(snapshot.id), snapshot)
        try store.collect(retaining: [])
        XCTAssertThrowsError(try store.load(snapshot.id))
        try store.collect(retaining: [])
        store.remove(snapshot.id)
        XCTAssertNil(try MarkdownOpenRequest.parse(URL(string: "https://example.com")!))
        var invalid = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        invalid.queryItems = invalid.queryItems!.filter { $0.name != "original" } + [URLQueryItem(name: "original", value: "bad")]
        XCTAssertThrowsError(try MarkdownOpenRequest.parse(invalid.url!))
        invalid.queryItems!.append(URLQueryItem(name: "original", value: "bad"))
        XCTAssertThrowsError(try MarkdownOpenRequest.parse(invalid.url!))
        let plain = MarkdownOpenRequest(fileURL: new)
        XCTAssertEqual(try MarkdownOpenRequest.parse(plain.url), plain)
        XCTAssertThrowsError(try args.requests(store: store))
        let absentStore = OriginalSnapshotStore(directory: dir.appendingPathComponent("Absent"))
        try absentStore.collect(retaining: [])
        let another = OriginalDocumentSnapshot(document: snapshot.document)
        try store.save(another)
        let mismatch = dir.appendingPathComponent("Originals/\(another.id.uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: mismatch)
        XCTAssertThrowsError(try store.load(another.id))
        store.remove(another.id)
    }
    func testSessionAppliesReplacesClearsAndPreservesOriginalOnRefresh() async throws {
        let session = DocumentSession()
        let url = URL(fileURLWithPath: "/private/tmp/current.md")
        try await session.applyAsync(MarkdownDocument(sourceURL: url, title: "Current", markdown: "# Title\n\nTuesday"))
        let plain = try session.pdfData()
        let original = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "# Title\n\nMonday"))
        try await session.setOriginalSnapshot(original)
        XCTAssertTrue(session.hasOriginal)
        XCTAssertEqual(session.title, "Title")
        XCTAssertEqual(session.suggestedPDFFileName, "current.pdf")
        XCTAssertFalse(try XCTUnwrap(session.renderedSnapshot).decorations.highlights.isEmpty)
        let marked = try session.exportData(as: .pdf)
        XCTAssertNotEqual(marked, plain)
        XCTAssertEqual(PDFDocument(data: marked)?.pageCount, PDFDocument(data: plain)?.pageCount)
        XCTAssertNotNil(try session.printOperation())
        try session.apply(MarkdownDocument(sourceURL: url, title: "Current", markdown: "# Title\n\nWednesday"))
        XCTAssertEqual(session.originalSnapshot, original)
        XCTAssertEqual(session.renderedSnapshot?.decorations.deletions.first?.text, "Monday")
        let replacement = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "# Title\n\nWednesday"))
        try await session.setOriginalSnapshot(replacement)
        XCTAssertEqual(session.renderedSnapshot?.decorations, RevisionDecorations())
        try await session.setOriginalSnapshot(nil)
        XCTAssertFalse(session.hasOriginal)
        XCTAssertEqual(session.renderedSnapshot?.decorations, RevisionDecorations())
        let unloaded = DocumentSession()
        try await unloaded.setOriginalSnapshot(original)
        XCTAssertTrue(unloaded.hasOriginal)
        let cancelled = Task { try await session.setOriginalSnapshot(original) }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(session.hasOriginal)
    }
    func testPendingAndRunningSessionRoutingAndRestorationErrors() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = OriginalSnapshotStore(directory: dir)
        let coordinator = DocumentOriginalCoordinator(store: store)
        let url = dir.appendingPathComponent("current.md")
        let session = DocumentSession()
        let snapshot = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "Before"))
        try store.save(snapshot, pending: true)
        try coordinator.enqueue(MarkdownOpenRequest(fileURL: url))
        try coordinator.enqueue(MarkdownOpenRequest(fileURL: url, originalID: snapshot.id))
        XCTAssertTrue(coordinator.retainedOriginalIDs.contains(snapshot.id))
        XCTAssertNil(try coordinator.register(session, for: nil))
        XCTAssertEqual(try coordinator.register(session, for: url), snapshot)
        try await session.applyAsync(MarkdownDocument(sourceURL: url, title: "Current", markdown: "After"))
        try coordinator.enqueue(MarkdownOpenRequest(fileURL: url, originalID: snapshot.id))
        for _ in 0..<100 where session.renderedSnapshot?.decorations.deletions.isEmpty != false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.originalSnapshot, snapshot)
        XCTAssertTrue(coordinator.retainedOriginalIDs.contains(snapshot.id))
        coordinator.collect(retaining: [])
        XCTAssertEqual(try store.load(snapshot.id), snapshot)
        coordinator.reportRestorationError(MarkdownOpenError.invalidOriginal, for: url)
        XCTAssertThrowsError(try coordinator.register(session, for: url))
        XCTAssertThrowsError(try coordinator.enqueue(MarkdownOpenRequest(fileURL: url, originalID: UUID())))
    }
    func testWordDecorationsAndFixtureExports() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 160, height: 80))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 160, height: 80)).fill(); image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("current.png"))
        let old = """
        # Revision Example

        The delivery date is Monday. This ordinary sentence stays unchanged.

        [Project website](https://example.com/old) and ordinary text.

        > A quoted original sentence.

        | Item | Status |
        | --- | --- |
        | Alpha | Waiting |

        ![Diagram](old.png)

        A paragraph that will be removed entirely.
        """
        let current = """
        # Revision Example

        The delivery date is Tuesday. This ordinary sentence stays unchanged.

        [Project website](https://example.com/new) and **ordinary** text.

        > A quoted updated sentence.

        | Item | Status |
        | --- | --- |
        | Alpha | Ready |

        ![Diagram](current.png)

        A newly added paragraph for the reader.
        """
        let document = MarkdownDocument(sourceURL: dir.appendingPathComponent("current.md"), title: "Current", markdown: current)
        let revision = MarkdownRenderer().render(document: document, original: MarkdownDocument(title: "Old", markdown: old))
        let data = try WordExporter().wordData(from: revision.text, decorations: revision.decorations)
        let file = dir.appendingPathComponent("marked.docx"); try data.write(to: file)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", file.path, "word/document.xml"]; process.standardOutput = pipe
        try process.run(); let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(xml.contains("mso-position-vertical-relative:line"))
        XCTAssertTrue(xml.contains("type=\"none\""))
        XCTAssertTrue(xml.contains("w:highlight"))
        XCTAssertTrue(xml.contains("EBBA00"))
        XCTAssertFalse(xml.contains("MDPRINTERREVISION"))
        let parsed = try XMLDocument(xmlString: xml)
        let callouts = try parsed.nodes(forXPath: "//*[local-name()='txbxContent']").map { node in
            try node.nodes(forXPath: ".//*[local-name()='t']").compactMap(\.stringValue).joined()
        }
        XCTAssertTrue(callouts.contains("^ Monday"))
        XCTAssertFalse(callouts.contains { $0.contains("deleted Monday") })
        let body = try parsed.nodes(forXPath: "//*[local-name()='t' and not(ancestor::*[local-name()='txbxContent'])]").compactMap(\.stringValue).joined()
        XCTAssertTrue(body.contains("Tuesday"))
        XCTAssertFalse(body.contains("Monday"))
        let yellowRuns = try parsed.nodes(forXPath: "//*[local-name()='r'][*[local-name()='rPr']/*[local-name()='highlight']]/*[local-name()='t']").compactMap(\.stringValue).joined()
        XCTAssertTrue(yellowRuns.contains("Tuesday"))
        XCTAssertTrue(yellowRuns.contains("ordinary"))
        XCTAssertTrue(yellowRuns.contains("updated"))
        XCTAssertTrue(yellowRuns.contains("A newly added paragraph for the reader."))
        let empty = MarkdownRenderer().render(document: MarkdownDocument(title: "Empty", markdown: ""), original: MarkdownDocument(title: "Old", markdown: "Removed"))
        XCTAssertFalse(try WordExporter().wordData(from: empty.text, decorations: empty.decorations).isEmpty)
        if let path = ProcessInfo.processInfo.environment["MDPRINTER_REVISION_FIXTURES"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("revisions.docx"))
            try PDFExporter().pdfData(from: revision.text, decorations: revision.decorations).write(to: output.appendingPathComponent("revisions.pdf"))
            try PDFExporter().pdfData(from: MarkdownRenderer().render(document: document)).write(to: output.appendingPathComponent("plain.pdf"))
            try Data(current.utf8).write(to: output.appendingPathComponent("current.md"))
            try Data(old.utf8).write(to: output.appendingPathComponent("original.md"))
            try png.write(to: output.appendingPathComponent("current.png"))
        }
    }

    func testLauncherSelectsBundledHostAndCleansFailedHandoffs() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("current.md"), old = dir.appendingPathComponent("old.md")
        try Data("Current".utf8).write(to: current); try Data("Original".utf8).write(to: old)
        let store = OriginalSnapshotStore(directory: dir.appendingPathComponent("Originals"))
        XCTAssertEqual(OriginalSnapshotStore.defaultDirectory(bundleIdentifier: nil), OriginalSnapshotStore.defaultDirectory(bundleIdentifier: "com.peteedstrom.markdown-printer"))
        XCTAssertNotEqual(OriginalSnapshotStore.defaultDirectory(bundleIdentifier: "com.peteedstrom.markdown-printer.qa"), OriginalSnapshotStore.defaultDirectory(bundleIdentifier: nil))
        let executable = URL(fileURLWithPath: "/Applications/Markdown Printer.app/Contents/MacOS/MarkdownPrinterCLI")
        XCTAssertEqual(MarkdownOpenLauncher.applicationURL(for: executable)?.path, "/Applications/Markdown Printer.app")
        XCTAssertNil(MarkdownOpenLauncher.applicationURL(for: URL(fileURLWithPath: "/private/tmp/CLI")))
        var received: [URL] = []
        try await MarkdownOpenLauncher.launch(["open", current.path, "--original", old.path], executable: executable, store: store) { urls, host in
            XCTAssertEqual(host?.pathExtension, "app"); received = urls
        }
        let request = try XCTUnwrap(MarkdownOpenRequest.parse(XCTUnwrap(received.first)))
        let id = try XCTUnwrap(request.originalID)
        XCTAssertEqual(try store.load(id).markdown, "Original")
        var failedID: UUID?
        do {
            try await MarkdownOpenLauncher.launch(["open", current.path, "--original", old.path], executable: executable, store: store) { urls, _ in
                failedID = try MarkdownOpenRequest.parse(urls[0])?.originalID
                throw MarkdownOpenError.applicationUnavailable
            }
            XCTFail("Expected launch failure")
        } catch { XCTAssertNotNil(error.localizedDescription) }
        XCTAssertThrowsError(try store.load(XCTUnwrap(failedID)))
        try await MarkdownOpenLauncher.launch(["open", current.path, old.path], executable: executable, store: store) { urls, _ in
            XCTAssertEqual(urls.count, 2)
            for url in urls { XCTAssertNil(try MarkdownOpenRequest.parse(url)?.originalID) }
        }
    }

    func testWordLinkedAndTableImagesKeepBordersAndRelationships() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 80, height: 40))
        image.lockFocus(); NSColor.orange.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 80, height: 40)).fill(); image.unlockFocus()
        try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
            .write(to: dir.appendingPathComponent("new.png"))
        let new = "[![Photo](new.png)](https://example.com)\n\n| Photo |\n| --- |\n| [![Inside](new.png)](https://example.com/table) |"
        let old = new.replacingOccurrences(of: "new.png", with: "old.png")
        let revision = MarkdownRenderer().render(document: MarkdownDocument(sourceURL: dir.appendingPathComponent("new.md"), title: "T", markdown: new),
                                                original: MarkdownDocument(title: "Old", markdown: old))
        let output = dir.appendingPathComponent("images.docx")
        try WordExporter().wordData(from: revision.text, decorations: revision.decorations).write(to: output)
        func unzip(_ name: String) throws -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", output.path, name]; process.standardOutput = pipe
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        let xml = try unzip("word/document.xml"), relationships = try unzip("word/_rels/document.xml.rels")
        XCTAssertNoThrow(try XMLDocument(xmlString: xml))
        XCTAssertEqual(xml.components(separatedBy: "EBBA00").count - 1, 2)
        XCTAssertTrue(relationships.contains("https://example.com/table"))
        XCTAssertTrue(relationships.contains("rIdMarkdownPrinterImageLink"))
        XCTAssertFalse(xml.contains("MDPRINTERIMAGE"))
        XCTAssertTrue(try unzip("word/media/markdown-printer-table-0-image-0.png").count > 0)
    }

    func testMenuActionsKeepTheSameSessionAndExportPreferences() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.md"), current = dir.appendingPathComponent("current.md")
        try Data("# Title\n\nThe date is Monday.".utf8).write(to: old)
        try Data("# Title\n\nThe date is Tuesday.".utf8).write(to: current)
        let suite = "RevisionActions-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ExportPreferences(defaults: defaults); preferences.defaultFormat = .word
        let session = DocumentSession(); session.load(url: current)
        var choose: URL? = old
        let activity = ApplicationActivityCoordinator()
        var postponedRelaunches = 0
        let actions = DocumentActionController(session: session, exportPreferences: preferences,
            activityCoordinator: activity, presentSavePanel: { _, _ in nil }, presentOriginalPanel: {
                XCTAssertTrue(activity.hasActiveBlockingOperation)
                let priorRelaunches = postponedRelaunches
                XCTAssertTrue(activity.postponeRelaunch { postponedRelaunches += 1 })
                XCTAssertEqual(postponedRelaunches, priorRelaunches)
                return choose
            })
        XCTAssertTrue(actions.canCompare); XCTAssertFalse(actions.canClearOriginal)
        actions.compareWithOlderVersion()
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertEqual(postponedRelaunches, 1)
        for _ in 0..<100 where session.renderedSnapshot?.decorations.highlights.isEmpty != false { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(actions.canClearOriginal)
        let id = try XCTUnwrap(session.originalSnapshot?.id)
        defer { DocumentOriginalCoordinator.shared.store.remove(id) }
        XCTAssertEqual(session.document?.sourceURL, current)
        XCTAssertEqual(session.title, "Title")
        XCTAssertEqual(preferences.defaultFormat, .word)
        XCTAssertTrue(actions.shareCommandTitle.contains("Word"))
        choose = nil; actions.compareWithOlderVersion()
        XCTAssertFalse(activity.hasActiveBlockingOperation)
        XCTAssertEqual(postponedRelaunches, 2)
        XCTAssertEqual(session.originalSnapshot?.id, id)
        actions.applyOriginal(url: dir.appendingPathComponent("missing.md"))
        XCTAssertNotNil(session.errorMessage); XCTAssertEqual(session.originalSnapshot?.id, id)
        actions.clearOriginal()
        for _ in 0..<100 where session.hasOriginal || session.isPreparingDocument { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(actions.canClearOriginal)
        XCTAssertEqual(session.document?.sourceURL, current)
        XCTAssertEqual(preferences.defaultFormat, .word)
        let empty = DocumentSession()
        let disabled = DocumentActionController(session: empty, exportPreferences: preferences,
            activityCoordinator: ApplicationActivityCoordinator(), presentSavePanel: { _, _ in nil }, presentOriginalPanel: { XCTFail("Should be disabled"); return nil })
        XCTAssertFalse(disabled.canCompare); disabled.compareWithOlderVersion()
    }

    func testLiveRefreshPagePreferencesAndLatestOriginalWin() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("current.md")
        try Data("# Title\n\nThe date is Tuesday.".utf8).write(to: current)
        let suite = "RevisionPages-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let pages = PagePreferences(defaults: defaults)
        let session = DocumentSession(pagePreferences: pages)
        session.load(url: current)
        let original = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "# Title\n\nThe date is Monday."))
        try await session.setOriginalSnapshot(original)
        session.startMonitoringSourceChanges(); defer { session.stopMonitoringSourceChanges() }
        try Data("# Title\n\nThe date is Wednesday.".utf8).write(to: current, options: .atomic)
        for _ in 0..<150 where session.document?.markdown.contains("Wednesday") != true { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(session.document?.markdown.contains("Wednesday") == true)
        XCTAssertEqual(session.originalSnapshot, original)
        XCTAssertTrue(session.renderedSnapshot?.decorations.deletions.contains { $0.text == "Monday" } == true)
        pages.leftFooter = .custom("Revision fixture")
        for _ in 0..<100 where session.renderedSnapshot?.footers.left != "Revision fixture" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session.renderedSnapshot?.footers.left, "Revision fixture")
        let first = Task { try await session.setOriginalSnapshot(original) }
        await Task.yield()
        let latest = OriginalDocumentSnapshot(document: try XCTUnwrap(session.document))
        try await session.setOriginalSnapshot(latest)
        try await first.value
        XCTAssertEqual(session.originalSnapshot, latest)
        XCTAssertEqual(session.renderedSnapshot?.decorations, RevisionDecorations())
    }

    func testOriginalSnapshotMetadataRestoresAndGarbageCollectionKeepsSavedReferences() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = OriginalSnapshotStore(directory: dir.appendingPathComponent("Originals"))
        let originals = DocumentOriginalCoordinator(store: store)
        let snapshot = OriginalDocumentSnapshot(document: MarkdownDocument(title: "Old", markdown: "Original body"))
        try store.save(snapshot)
        let unused = OriginalDocumentSnapshot(document: snapshot.document); try store.save(unused)
        let url = dir.appendingPathComponent("current.md")
        let session = DocumentSession(); try await session.setOriginalSnapshot(snapshot)
        try await session.applyAsync(MarkdownDocument(sourceURL: url, title: "Current", markdown: "Current body"))
        let suite = "RevisionRestore-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OpenDocumentRestorationController(defaults: defaults, originalCoordinator: originals)
        let window = DocumentWindowRestorationCoordinator(sourceURL: url, restorationController: controller, session: session)
        window.activate(); defer { window.deactivate() }
        let state = try XCTUnwrap(controller.currentWindowState(for: url))
        XCTAssertEqual(state.originalSnapshotID, snapshot.id)
        controller.workspaceCaptureProvider = {
            WorkspaceSnapshot(groups: [WorkspaceWindowGroup(identifier: "ordinary", tabs: [.document(url, state: state)], selectedTabIndex: 0, isTabBarVisible: false)])
        }
        controller.captureLastSession()
        XCTAssertEqual(controller.lastSessionWorkspace()?.groups.first?.tabs.first?.windowState?.originalSnapshotID, snapshot.id)
        XCTAssertThrowsError(try store.load(unused.id))
        XCTAssertEqual(try store.load(snapshot.id), snapshot)
        controller.prepareForRelaunch(targetBuild: "future")
        let restoredController = OpenDocumentRestorationController(defaults: defaults, originalCoordinator: originals)
        restoredController.captureLastSession() // Pending relaunch still retains the original.
        XCTAssertEqual(try store.load(snapshot.id), snapshot)
        let restored = try XCTUnwrap(restoredController.consumeWorkspaceForRelaunch(currentBuild: "future"))
        XCTAssertEqual(restored.groups.first?.tabs.first?.windowState?.originalSnapshotID, snapshot.id)
        let restoredSession = DocumentSession()
        XCTAssertEqual(try originals.register(restoredSession, for: url), snapshot)
        let missingState = DocumentWindowRestorationState(frame: nil, viewport: nil, originalSnapshotID: UUID())
        restoredController.prepareWindowStates(for: WorkspaceSnapshot(groups: [WorkspaceWindowGroup(identifier: "missing", tabs: [.document(url, state: missingState)], selectedTabIndex: 0, isTabBarVisible: false)]))
        XCTAssertThrowsError(try originals.register(restoredSession, for: url))
    }
}

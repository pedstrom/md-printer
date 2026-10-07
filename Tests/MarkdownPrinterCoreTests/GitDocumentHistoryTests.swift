#if os(macOS)
import Foundation
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

final class GitDocumentHistoryTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/private/tmp/repository")
    private let git = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
    private let firstID = String(repeating: "a", count: 40)
    private let secondID = String(repeating: "b", count: 40)

    func testRealHistoryFollowsRenameFiltersOtherFilesAndLeavesRepositoryUntouched() async throws {
        let repository = try GitTestRepository()
        defer { repository.remove() }
        let original = "draft [1].md", renamed = "--literal [#]:\t\ncafé.md"
        try repository.write("# Original\n\nFirst", to: original)
        let initial = try repository.commit("Initial document", date: "2023-01-02T12:00:00-0500")
        try repository.write("Unrelated", to: "other.md")
        _ = try repository.commit("Other file", date: "2023-01-03T12:00:00-0500")
        try repository.git(["mv", "--", original, renamed])
        let rename = try repository.commit("Rename document", date: "2023-01-04T12:00:00-0500")
        try repository.write("# Revised\n\nSecond", to: renamed)
        let latest = try repository.commit("Edit document", date: "2023-07-05T13:20:00-0400")
        try repository.write("# Current\n\nWorking changes", to: renamed)
        try repository.git(["config", "log.showRoot", "false"])
        let before = try repository.fingerprint()
        let service = GitDocumentHistoryService(executableURL: repository.executable)
        let history = try await service.history(for: repository.url.appendingPathComponent(renamed))
        XCTAssertEqual(history.repositoryURL, repository.url.resolvingSymlinksInPath())
        XCTAssertEqual(history.revisions.map(\.commitID), [latest, rename, initial])
        XCTAssertEqual(history.revisions.map(\.historicalPath), [renamed, renamed, original])
        XCTAssertEqual(history.revisions.map(\.subject), ["Edit document", "Rename document", "Initial document"])
        XCTAssertEqual(history.revisions[0].id, latest)
        XCTAssertEqual(history.revisions[0].abbreviatedID, String(latest.prefix(8)))
        let old = try await service.document(for: history.revisions[2], in: history)
        XCTAssertEqual(old.markdown, "# Original\n\nFirst")
        XCTAssertEqual(old.sourceURL, history.repositoryURL.appendingPathComponent(original))
        XCTAssertEqual(old.sourceModificationDate, ISO8601DateFormatter().date(from: "2023-01-02T17:00:00Z"))
        let suggested = try await service.suggestedRevision(in: history, currentMarkdown: "# Current\n\nWorking changes")
        XCTAssertEqual(suggested?.commitID, latest)
        let previous = try await service.suggestedRevision(in: history, currentMarkdown: "# Revised\n\nSecond")
        XCTAssertEqual(previous?.commitID, rename)
        XCTAssertEqual(try repository.fingerprint(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(".git/index.lock").path))
    }

    func testRealHistoryIncludesMergeThatChangesTheDocument() async throws {
        let repository = try GitTestRepository()
        defer { repository.remove() }
        try repository.write("Original\n", to: "file.md")
        _ = try repository.commit("Original")
        try repository.git(["checkout", "-qb", "side"])
        try repository.write("Side\n", to: "file.md")
        let side = try repository.commit("Side edit")
        try repository.git(["checkout", "-q", "main"])
        try repository.write("Main\n", to: "file.md")
        let main = try repository.commit("Main edit")
        XCTAssertNotEqual(try repository.git(["merge", "--no-edit", "side"], allowFailure: true).status, 0)
        try repository.write("Merged resolution\n", to: "file.md")
        let merge = try repository.commit("Merge resolution")
        let history = try await GitDocumentHistoryService(executableURL: repository.executable)
            .history(for: repository.url.appendingPathComponent("file.md"))
        XCTAssertEqual(history.revisions.first?.commitID, merge)
        XCTAssertTrue(history.revisions.contains { $0.commitID == main })
        XCTAssertTrue(history.revisions.contains { $0.commitID == side })
        let document = try await GitDocumentHistoryService(executableURL: repository.executable)
            .document(for: XCTUnwrap(history.revisions.first), in: history)
        XCTAssertEqual(document.markdown, "Merged resolution\n")
    }

    func testRealHistoryHandlesEmptyRepositoryUntrackedFileAndSoleRevision() async throws {
        let repository = try GitTestRepository(directoryName: "root with\na newline ")
        defer { repository.remove() }
        let service = GitDocumentHistoryService(executableURL: repository.executable)
        try repository.write("One", to: "one.md")
        let empty = try await service.history(for: repository.url.appendingPathComponent("one.md"))
        XCTAssertTrue(empty.revisions.isEmpty)
        let none = try await service.suggestedRevision(in: empty, currentMarkdown: "One")
        XCTAssertNil(none)
        let commit = try repository.commit("Single")
        let history = try await service.history(for: repository.url.appendingPathComponent("one.md"))
        XCTAssertEqual(history.repositoryURL, repository.url.resolvingSymlinksInPath())
        let selected = try await service.suggestedRevision(in: history, currentMarkdown: "One")
        XCTAssertEqual(selected?.commitID, commit)
        try repository.write("No history", to: "untracked.md")
        let untracked = try await service.history(for: repository.url.appendingPathComponent("untracked.md"))
        XCTAssertTrue(untracked.revisions.isEmpty)
    }

    func testMissingLocalBlobIsUnavailableAndDoesNotFetchFromPromisorRemote() async throws {
        let repository = try GitTestRepository()
        defer { repository.remove() }
        try repository.write("A locally committed document", to: "file.md")
        let commit = try repository.commit("Original")
        let service = GitDocumentHistoryService(executableURL: repository.executable)
        let history = try await service.history(for: repository.url.appendingPathComponent("file.md"))
        let blob = String(decoding: try repository.git(["rev-parse", commit + ":file.md"]).standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let blobURL = repository.url.appendingPathComponent(".git/objects/" + blob.prefix(2) + "/" + blob.dropFirst(2))
        try FileManager.default.removeItem(at: blobURL)
        try repository.git(["config", "remote.origin.url", "https://example.invalid/never-fetch.git"])
        try repository.git(["config", "remote.origin.promisor", "true"])
        try repository.git(["config", "remote.origin.partialclonefilter", "blob:none"])
        let before = try repository.fingerprint()
        let start = Date()
        await assertError(.unavailableVersion) { _ = try await service.document(for: history.revisions[0], in: history) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.appendingPathComponent(".git/FETCH_HEAD").path))
        XCTAssertEqual(try repository.fingerprint(), before)
    }

    func testDefaultSelectionSkipsRenameAndIdenticalContents() async throws {
        let runner = GitResultRunner([success("same"), success("same"), success("different")])
        let service = GitDocumentHistoryService(runner: runner, executableURL: git)
        let history = makeHistory([revision(firstID), revision(secondID), revision(String(repeating: "c", count: 40))])
        let suggested = try await service.suggestedRevision(in: history, currentMarkdown: "same")
        XCTAssertEqual(suggested, history.revisions[2])
        let identicalRunner = GitResultRunner([success("same"), success("same")])
        let identical = makeHistory([revision(firstID), revision(secondID)])
        let selection = try await GitDocumentHistoryService(runner: identicalRunner, executableURL: git)
            .suggestedRevision(in: identical, currentMarkdown: "same")
        XCTAssertEqual(selection, identical.revisions[0])
    }

    func testInstalledGitLocatorUsesSelectedDeveloperToolsAndCachesBinary() async throws {
        let runner = GitResultRunner([success("/Custom Xcode/Contents/Developer\n"), success("git version 2.54\n"),
                                     success(root.path + "\n"), success(firstID + "\n"), success(record(firstID, path: "file.md")), success("Old")])
        let service = GitDocumentHistoryService(runner: runner, isExecutable: { $0.path == "/Custom Xcode/Contents/Developer/usr/bin/git" })
        let history = try await service.history(for: root.appendingPathComponent("file.md"))
        _ = try await service.document(for: history.revisions[0], in: history)
        XCTAssertEqual(runner.calls[0].executableURL.path, "/usr/bin/xcode-select")
        XCTAssertEqual(runner.calls[0].arguments, ["-p"])
        XCTAssertEqual(runner.calls.dropFirst().map(\.executableURL.path), Array(repeating: "/Custom Xcode/Contents/Developer/usr/bin/git", count: 5))
        for call in runner.calls.dropFirst() {
            XCTAssertTrue(call.arguments.contains("--no-lazy-fetch"))
            XCTAssertTrue(call.arguments.contains("--no-optional-locks"))
            XCTAssertTrue(call.arguments.contains("--literal-pathspecs"))
            XCTAssertTrue(call.arguments.contains("--no-replace-objects"))
            XCTAssertEqual(call.environment["GIT_NO_LAZY_FETCH"], "1")
            XCTAssertEqual(call.environment["GIT_OPTIONAL_LOCKS"], "0")
            XCTAssertEqual(call.environment["GIT_TERMINAL_PROMPT"], "0")
        }
        XCTAssertEqual(runner.calls[4].arguments.suffix(2), ["--", "file.md"])
    }

    func testLocatorFallsBackToCommandLineToolsAndHomebrewAndReportsMissingOrIncompatibleGit() async throws {
        for binary in ["/Library/Developer/CommandLineTools/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            let runner = GitResultRunner([GitProcessResult(status: 2), success("git version\n"), success(root.path + "\n"),
                                         GitProcessResult(status: 1)])
            let service = GitDocumentHistoryService(runner: runner, isExecutable: { $0.path == binary })
            _ = try await service.history(for: root.appendingPathComponent("file.md"))
            XCTAssertEqual(runner.calls[1].executableURL.path, binary)
        }
        let missing = GitDocumentHistoryService(runner: GitResultRunner([success("relative/path\n")]), isExecutable: { _ in false })
        await assertError(.gitUnavailable) { _ = try await missing.history(for: self.root.appendingPathComponent("file.md")) }
        let incompatible = GitDocumentHistoryService(runner: GitResultRunner([success("/Developer\n"), GitProcessResult(status: 129)]),
                                                     isExecutable: { $0.path == "/Developer/usr/bin/git" })
        await assertError(.incompatibleGit) { _ = try await incompatible.history(for: self.root.appendingPathComponent("file.md")) }
    }

    func testLocatorSkipsAnIncompatibleDeveloperGitForCompatibleHomebrewGit() async throws {
        let runner = GitResultRunner([success("/Developer\n"), GitProcessResult(status: 129), success("git version 2.54\n"),
                                     success(root.path + "\n"), GitProcessResult(status: 1)])
        let service = GitDocumentHistoryService(runner: runner, isExecutable: {
            ["/Developer/usr/bin/git", "/opt/homebrew/bin/git"].contains($0.path)
        })
        _ = try await service.history(for: root.appendingPathComponent("file.md"))
        XCTAssertEqual(runner.calls[1].executableURL.path, "/Developer/usr/bin/git")
        XCTAssertEqual(runner.calls[2].executableURL.path, "/opt/homebrew/bin/git")
        XCTAssertEqual(runner.calls[3].executableURL.path, "/opt/homebrew/bin/git")
    }

    func testLocatorFallsBackAfterLaunchFailureAndPropagatesCancellation() async throws {
        let runner = GitResultRunner([success("/Developer\n"), success("git version 2.54\n"),
                                     success(root.path + "\n"), GitProcessResult(status: 1)],
                                    errorsByCall: [1: CocoaError(.executableArchitectureMismatch)])
        let service = GitDocumentHistoryService(runner: runner, isExecutable: {
            ["/Developer/usr/bin/git", "/opt/homebrew/bin/git"].contains($0.path)
        })
        _ = try await service.history(for: root.appendingPathComponent("file.md"))
        XCTAssertEqual(runner.calls[1].executableURL.path, "/Developer/usr/bin/git")
        XCTAssertEqual(runner.calls[2].executableURL.path, "/opt/homebrew/bin/git")

        let noUsableGit = GitDocumentHistoryService(
            runner: GitResultRunner([success("/Developer\n")], errorsByCall: [1: CocoaError(.executableNotLoadable)]),
            isExecutable: { $0.path == "/Developer/usr/bin/git" })
        await assertError(.incompatibleGit) { _ = try await noUsableGit.history(for: self.root.appendingPathComponent("file.md")) }

        let cancellation = GitResultRunner([success("/Developer\n")], errorsByCall: [1: CancellationError()])
        let cancelledService = GitDocumentHistoryService(runner: cancellation, isExecutable: {
            ["/Developer/usr/bin/git", "/opt/homebrew/bin/git"].contains($0.path)
        })
        do {
            _ = try await cancelledService.history(for: root.appendingPathComponent("file.md"))
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancellation.calls.count, 2, "Cancellation must not probe the next Git installation")
    }

    func testServiceReportsInvalidSourcesHistoryAndCommandErrors() async {
        await assertError(.notRepository) { _ = try await GitDocumentHistoryService().history(for: URL(string: "https://example.com/file.md")!) }
        for output in ["relative/root\n", root.path, ""] {
            let service = GitDocumentHistoryService(runner: GitResultRunner([success(output)]), executableURL: git)
            await assertError(.invalidHistory) { _ = try await service.history(for: self.root.appendingPathComponent("file.md")) }
        }
        let outside = GitDocumentHistoryService(runner: GitResultRunner([success("/unrelated\n")]), executableURL: git)
        await assertError(.notRepository) { _ = try await outside.history(for: self.root.appendingPathComponent("file.md")) }
        let absent = GitDocumentHistoryService(runner: GitResultRunner([GitProcessResult(status: 128)]), executableURL: git)
        await assertError(.notRepository) { _ = try await absent.history(for: self.root.appendingPathComponent("file.md")) }
        let invalidHead = GitDocumentHistoryService(runner: GitResultRunner([success(root.path + "\n"), success("bad\n")]), executableURL: git)
        await assertError(.invalidHistory) { _ = try await invalidHead.history(for: self.root.appendingPathComponent("file.md")) }
        for error in ["", "broken local object"] {
            let service = GitDocumentHistoryService(runner: GitResultRunner([success(root.path + "\n"),
                GitProcessResult(status: 128, standardError: Data(error.utf8))]), executableURL: git)
            await assertError(.commandFailed(error)) { _ = try await service.history(for: self.root.appendingPathComponent("file.md")) }
        }
        let failedLog = GitDocumentHistoryService(runner: GitResultRunner([success(root.path + "\n"), success(firstID + "\n"),
            GitProcessResult(status: 128, standardError: Data("missing object".utf8))]), executableURL: git)
        await assertError(.commandFailed("missing object")) { _ = try await failedLog.history(for: self.root.appendingPathComponent("file.md")) }
        for error in [GitDocumentHistoryError.gitUnavailable, .incompatibleGit, .notRepository, .invalidHistory, .unavailableVersion,
                      .commandFailed(""), .commandFailed("Details")] {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testUnavailableHistoricalObjectsInvalidRevisionAndUnreadableText() async throws {
        let revision = revision(firstID)
        let history = makeHistory([revision])
        let missing = GitDocumentHistoryService(runner: GitResultRunner([GitProcessResult(status: 128)]), executableURL: git)
        await assertError(.unavailableVersion) { _ = try await missing.document(for: revision, in: history) }
        let guarded = GitDocumentHistoryService(runner: GitResultRunner([]), executableURL: git)
        await assertError(.unavailableVersion) { _ = try await guarded.document(for: self.revision(self.secondID), in: history) }
        for invalid in [self.revision("bad"), self.revision(firstID, path: ""), self.revision(firstID, path: "/absolute.md"),
                        self.revision(firstID, path: "../outside.md"), self.revision(firstID, path: "bad\0name")] {
            await assertError(.unavailableVersion) { _ = try await guarded.document(for: invalid, in: self.makeHistory([invalid])) }
        }
        let unsupported = GitDocumentHistoryService(runner: GitResultRunner([GitProcessResult(status: 0, standardOutput: Data([0xFF]))]), executableURL: git)
        do { _ = try await unsupported.document(for: revision, in: history); XCTFail("Expected encoding failure") }
        catch { XCTAssertEqual(error as? MarkdownDocumentError, .unsupportedTextEncoding) }
        let utf16 = Data([0xFF, 0xFE]) + "# UTF16".data(using: .utf16LittleEndian)!
        let document = try await GitDocumentHistoryService(runner: GitResultRunner([GitProcessResult(status: 0, standardOutput: utf16)]), executableURL: git)
            .document(for: revision, in: history)
        XCTAssertEqual(document.title, "UTF16")
    }

    func testNULParserHandlesRenamesCopiesDeletionEmptySubjectAndSHA256() throws {
        let sha256 = String(repeating: "c", count: 64)
        let log = "\0\(firstID)\0100\0\0\nR100\0old\t\n.md\0current.md\0"
            + record(secondID, path: "old\t\n.md", subject: "Previous", status: "M")
            + record(secondID, path: "old\t\n.md", subject: "Duplicate", status: "M")
            + "\0\(sha256)\0200\0Copy\0\nC100\0origin.md\0old\t\n.md\0"
            + record(String(repeating: "d", count: 40), path: "origin.md", status: "D")
            + record(String(repeating: "e", count: 40), path: "unrelated.md")
        let revisions = try GitDocumentHistoryService.parseHistory(Data(log.utf8), currentPath: "current.md")
        XCTAssertEqual(revisions.map(\.commitID), [firstID, secondID, sha256])
        XCTAssertEqual(revisions.map(\.historicalPath), ["current.md", "old\t\n.md", "old\t\n.md"])
        XCTAssertEqual(revisions[0].subject, "")
        XCTAssertEqual(revisions[0].committerDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try GitDocumentHistoryService.parseHistory(Data(), currentPath: "none.md"), [])
        for malformed in ["invalid", "\0\(firstID)\0", "\0\(firstID)\0nan\0Subject\0", "\0\(firstID)\0100\0Subject\0\n\0file.md\0",
                          "\0\(firstID)\0100\0Subject\0\nM\0", "\0\(firstID)\0100\0Subject\0\nR100\0old.md\0"] {
            XCTAssertThrowsError(try GitDocumentHistoryService.parseHistory(Data(malformed.utf8), currentPath: "file.md"))
        }
        XCTAssertThrowsError(try GitDocumentHistoryService.parseHistory(Data([0xFF]), currentPath: "file.md"))
    }

    func testProcessRunnerDrainsLargeIndependentPipesAndPropagatesStatus() async throws {
        let command = "i=0; while [ $i -lt 12000 ]; do printf 'stdout line\\n'; printf 'stderr line\\n' >&2; i=$((i+1)); done; exit 7"
        let result = try await GitProcessRunner().run(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], environment: [:])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.standardOutput.count, 12_000 * 12)
        XCTAssertEqual(result.standardError.count, 12_000 * 12)
        do {
            _ = try await GitProcessRunner().run(executableURL: URL(fileURLWithPath: "/missing/executable"), arguments: [], environment: [:])
            XCTFail("Expected launch failure")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testProcessWaitDoesNotServicePendingWorkerRunLoopCallbacks() async throws {
        let (result, callbackFired) = try await withCheckedThrowingContinuation { continuation in
            // PDFKit can leave delayed annotation notifications on a reused worker.
            // Reproduce that pending work without risking an AppKit exception.
            Thread {
                let probe = GitWorkerRunLoopProbe()
                let timer = Timer(timeInterval: 0.01, repeats: false) { _ in probe.fire() }
                RunLoop.current.add(timer, forMode: .default)
                defer { timer.invalidate() }
                continuation.resume(with: Result {
                    let execution = GitProcessExecution(executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "/bin/sleep 0.2; printf complete; exit 7"], environment: [:])
                    let result = try execution.run()
                    return (result, probe.didFire)
                })
            }.start()
        }
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "complete")
        XCTAssertFalse(callbackFired, "Waiting for Git must not dispatch delayed PDFKit/UI work on a worker thread")
    }

    func testCancellationBeforeLaunchAndDuringProcessTerminatesPromptly() async throws {
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GitProcessRunner().run(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], environment: [:])
        }
        do { _ = try await before.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let serviceBefore = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GitDocumentHistoryService(runner: GitResultRunner([]), executableURL: self.git)
                .history(for: self.root.appendingPathComponent("file.md"))
        }
        do { _ = try await serviceBefore.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let start = Date()
        let running = Task {
            try await GitProcessRunner().run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "trap '' TERM; while :; do :; done"], environment: [:])
        }
        try await Task.sleep(for: .milliseconds(100))
        running.cancel()
        do { _ = try await running.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    private func success(_ output: String) -> GitProcessResult { GitProcessResult(status: 0, standardOutput: Data(output.utf8)) }
    private func revision(_ id: String, path: String = "file.md") -> GitDocumentRevision {
        GitDocumentRevision(commitID: id, historicalPath: path, subject: "Subject", committerDate: Date(timeIntervalSince1970: 100))
    }
    private func makeHistory(_ revisions: [GitDocumentRevision]) -> GitDocumentHistory {
        GitDocumentHistory(repositoryURL: root, sourceURL: root.appendingPathComponent("file.md"), revisions: revisions)
    }
    private func record(_ id: String, path: String, subject: String = "Subject", status: String = "M") -> String {
        "\0\(id)\0100\0\(subject)\0\n\(status)\0\(path)\0"
    }
    private func assertError(_ expected: GitDocumentHistoryError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? GitDocumentHistoryError, expected, file: file, line: line) }
    }
}

private final class GitWorkerRunLoopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var didFire: Bool { lock.withLock { fired } }
    func fire() { lock.withLock { fired = true } }
}

private final class GitResultRunner: GitProcessRunning, @unchecked Sendable {
    struct Call {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]
    }
    private let lock = NSLock()
    private var results: [GitProcessResult]
    private let errorsByCall: [Int: Error]
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    init(_ results: [GitProcessResult], errorsByCall: [Int: Error] = [:]) {
        self.results = results
        self.errorsByCall = errorsByCall
    }
    func run(executableURL: URL, arguments: [String], environment: [String: String]) async throws -> GitProcessResult {
        try Task.checkCancellation()
        return try lock.withLock {
            let callIndex = recorded.count
            recorded.append(Call(executableURL: executableURL, arguments: arguments, environment: environment))
            if let error = errorsByCall[callIndex] { throw error }
            guard !results.isEmpty else { XCTFail("Unexpected Git command: \(arguments)"); return GitProcessResult(status: 99) }
            return results.removeFirst()
        }
    }
}

private final class GitTestRepository {
    let url: URL
    let executable: URL
    private let directory: URL

    init(directoryName: String = "repository") throws {
        let binaries = ["/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
                        "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let binary = binaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("Installed Git is required") }
        executable = URL(fileURLWithPath: binary)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitDocumentTests-\(UUID().uuidString)")
        url = directory.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "Markdown Printer Tests"])
        try git(["config", "user.email", "tests@example.invalid"])
        try git(["config", "commit.gpgSign", "false"])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func write(_ text: String, to path: String) throws { try Data(text.utf8).write(to: url.appendingPathComponent(path)) }
    func commit(_ subject: String, date: String = "2023-01-02T12:00:00-0500") throws -> String {
        try git(["add", "--all"])
        try git(["commit", "-qm", subject], environment: ["GIT_COMMITTER_DATE": date, "GIT_AUTHOR_DATE": date])
        return String(decoding: try git(["rev-parse", "HEAD"]).standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    func fingerprint() throws -> Data {
        var result = try git(["status", "--porcelain=v1", "-z"]).standardOutput
        result.append(try Data(contentsOf: url.appendingPathComponent(".git/index")))
        result.append(try Data(contentsOf: url.appendingPathComponent(".git/HEAD")))
        result.append(try Data(contentsOf: url.appendingPathComponent(".git/refs/heads/main")))
        result.append(try Data(contentsOf: url.appendingPathComponent(".git/config")))
        return result
    }
    @discardableResult
    func git(_ arguments: [String], environment: [String: String] = [:], allowFailure: Bool = false) throws -> GitProcessResult {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = executable
        process.arguments = ["-C", url.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !allowFailure && process.terminationStatus != 0 {
            XCTFail("Git fixture command failed: \(arguments): \(String(decoding: stderr, as: UTF8.self))")
            throw GitDocumentHistoryError.commandFailed(String(decoding: stderr, as: UTF8.self))
        }
        return GitProcessResult(status: process.terminationStatus, standardOutput: stdout, standardError: stderr)
    }
}
#endif

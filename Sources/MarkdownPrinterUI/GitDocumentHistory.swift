#if os(macOS)
import Foundation
import Darwin
import MarkdownPrinterCore

package struct GitDocumentRevision: Identifiable, Equatable, Sendable {
    package let commitID: String
    package let historicalPath: String
    package let subject: String
    package let committerDate: Date
    package var id: String { commitID }
    package var abbreviatedID: String { String(commitID.prefix(8)) }

    package init(commitID: String, historicalPath: String, subject: String, committerDate: Date) {
        self.commitID = commitID
        self.historicalPath = historicalPath
        self.subject = subject
        self.committerDate = committerDate
    }
}

package struct GitDocumentHistory: Equatable, Sendable {
    package let repositoryURL: URL
    package let sourceURL: URL
    package let revisions: [GitDocumentRevision]

    package init(repositoryURL: URL, sourceURL: URL, revisions: [GitDocumentRevision]) {
        self.repositoryURL = repositoryURL
        self.sourceURL = sourceURL
        self.revisions = revisions
    }
}

package protocol GitDocumentHistoryProviding: Sendable {
    func history(for sourceURL: URL) async throws -> GitDocumentHistory
    func document(for revision: GitDocumentRevision, in history: GitDocumentHistory) async throws -> MarkdownDocument
    func suggestedRevision(in history: GitDocumentHistory, currentMarkdown: String) async throws -> GitDocumentRevision?
}

package struct GitProcessResult: Equatable, Sendable {
    package let status: Int32
    package let standardOutput: Data
    package let standardError: Data

    package init(status: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

package protocol GitProcessRunning: Sendable {
    func run(executableURL: URL, arguments: [String], environment: [String: String]) async throws -> GitProcessResult
}

/// Drains both pipes concurrently; cancellation is observed before and after launch.
package struct GitProcessRunner: GitProcessRunning {
    package init() {}

    package func run(executableURL: URL, arguments: [String], environment: [String: String]) async throws -> GitProcessResult {
        let execution = GitProcessExecution(executableURL: executableURL, arguments: arguments, environment: environment)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execution.run() })
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class GitProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    init(executableURL: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
    }

    func run() throws -> GitProcessResult {
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        let readers = DispatchGroup()
        let stdout = GitPipeContents(), stderr = GitPipeContents()
        for (pipe, contents) in [(output, stdout), (error, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                contents.result = Result { try pipe.fileHandleForReading.readToEnd() ?? Data() }
                try? pipe.fileHandleForReading.close()
                readers.leave()
            }
        }
        process.waitUntilExit()
        readers.wait()
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
        }
        return try GitProcessResult(status: process.terminationStatus,
                                    standardOutput: stdout.result.get(), standardError: stderr.result.get())
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
        // Git normally handles SIGTERM immediately. Bound cancellation even if a
        // installed executable does not, without ever touching another process.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.withLock {
                if cancelled && process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

private final class GitPipeContents: @unchecked Sendable {
    // The dispatch group synchronizes the sole writer and reader.
    var result: Result<Data, Error> = .success(Data())
}

package enum GitDocumentHistoryError: LocalizedError, Equatable {
    case gitUnavailable
    case incompatibleGit
    case notRepository
    case invalidHistory
    case unavailableVersion
    case commandFailed(String)

    package var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            return "Git is not installed. Install Git or Apple's Command Line Tools to compare with Git versions."
        case .incompatibleGit:
            return "This Git installation cannot read history without fetching remote objects. Update Git to compare with Git versions."
        case .notRepository:
            return "This document is not inside a Git working folder."
        case .invalidHistory:
            return "Git returned history that Markdown Printer could not read."
        case .unavailableVersion:
            return "That version is not available in the local Git repository."
        case let .commandFailed(detail):
            return detail.isEmpty ? "The local Git history could not be read." : "The local Git history could not be read: \(detail)"
        }
    }
}

package struct GitDocumentHistoryService: GitDocumentHistoryProviding {
    private let runner: any GitProcessRunning
    private let executableURL: URL?
    private let isExecutable: @Sendable (URL) -> Bool
    private let executableCache = GitExecutableCache()

    package init(runner: any GitProcessRunning = GitProcessRunner(), executableURL: URL? = nil,
                 isExecutable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) {
        self.runner = runner
        self.executableURL = executableURL
        self.isExecutable = isExecutable
    }

    package func history(for sourceURL: URL) async throws -> GitDocumentHistory {
        guard sourceURL.isFileURL else { throw GitDocumentHistoryError.notRepository }
        let executable = try await gitExecutable()
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let folder = source.deletingLastPathComponent()
        let rootResult = try await command(executable, folder: folder, ["rev-parse", "--show-toplevel"])
        guard rootResult.status == 0 else { throw GitDocumentHistoryError.notRepository }
        let rootPath = try terminatedLine(rootResult.standardOutput)
        guard rootPath.hasPrefix("/") else { throw GitDocumentHistoryError.invalidHistory }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL
        guard source.pathComponents.starts(with: root.pathComponents), source.pathComponents.count > root.pathComponents.count else {
            throw GitDocumentHistoryError.notRepository
        }
        let relativePath = source.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        let head = try await command(executable, folder: root, ["rev-parse", "--quiet", "--verify", "HEAD^{commit}"])
        if head.status == 1 && head.standardError.isEmpty {
            return GitDocumentHistory(repositoryURL: root, sourceURL: sourceURL, revisions: [])
        }
        let headID = try terminatedLine(checked(head).standardOutput)
        guard Self.isObjectID(headID) else { throw GitDocumentHistoryError.invalidHistory }
        let log = try checked(await command(executable, folder: root, [
            "log", "--follow", "--full-history", "--root", "--diff-merges=first-parent", "--date-order", "--find-renames",
            "--no-ext-diff", "--no-textconv", "--no-notes", "--no-show-signature", "--no-color", "--encoding=UTF-8",
            "--format=%x00%H%x00%ct%x00%s", "--name-status", "-z", headID, "--", relativePath
        ]))
        let revisions = try Self.parseHistory(log.standardOutput, currentPath: relativePath)
        return GitDocumentHistory(repositoryURL: root, sourceURL: sourceURL, revisions: revisions)
    }

    package func document(for revision: GitDocumentRevision, in history: GitDocumentHistory) async throws -> MarkdownDocument {
        guard history.revisions.contains(revision), Self.isObjectID(revision.commitID),
              !revision.historicalPath.isEmpty, !revision.historicalPath.hasPrefix("/"),
              !revision.historicalPath.split(separator: "/").contains(".."), !revision.historicalPath.contains("\0") else {
            throw GitDocumentHistoryError.unavailableVersion
        }
        let executable = try await gitExecutable()
        let result = try await command(executable, folder: history.repositoryURL,
                                       ["cat-file", "blob", revision.commitID + ":" + revision.historicalPath])
        guard result.status == 0 else { throw GitDocumentHistoryError.unavailableVersion }
        return try MarkdownDocument.decode(data: result.standardOutput,
                                           sourceURL: history.repositoryURL.appendingPathComponent(revision.historicalPath),
                                           sourceModificationDate: revision.committerDate)
    }

    package func suggestedRevision(in history: GitDocumentHistory, currentMarkdown: String) async throws -> GitDocumentRevision? {
        guard let newest = history.revisions.first else { return nil }
        let latestMarkdown = try await document(for: newest, in: history).markdown
        if currentMarkdown != latestMarkdown { return newest }
        for revision in history.revisions.dropFirst() {
            try Task.checkCancellation()
            if try await document(for: revision, in: history).markdown != latestMarkdown { return revision }
        }
        return newest
    }

    private func gitExecutable() async throws -> URL {
        try Task.checkCancellation()
        if let executableURL { return executableURL }
        if let cached = executableCache.get() { return cached }
        let selection = try await runner.run(executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                                             arguments: ["-p"], environment: Self.environment)
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], override.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: override).appendingPathComponent("usr/bin/git"))
        }
        if selection.status == 0, let selectedPath = try? terminatedLine(selection.standardOutput), selectedPath.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: selectedPath).appendingPathComponent("usr/bin/git"))
        }
        candidates += ["/Library/Developer/CommandLineTools/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .map { URL(fileURLWithPath: $0) }
        var installed = false
        var tried = Set<URL>()
        for candidate in candidates where tried.insert(candidate).inserted && isExecutable(candidate)
            && candidate.resolvingSymlinksInPath().path != "/usr/bin/git" {
            installed = true
            do {
                let probe = try await command(candidate, folder: FileManager.default.temporaryDirectory, ["--version"])
                if probe.status == 0 {
                    executableCache.set(candidate)
                    return candidate
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // An executable may still be unusable (for example, a different
                // architecture). A later installed Git can remain compatible.
                try Task.checkCancellation()
            }
        }
        throw installed ? GitDocumentHistoryError.incompatibleGit : GitDocumentHistoryError.gitUnavailable
    }

    private static var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        values["GIT_NO_LAZY_FETCH"] = "1"
        values["GIT_OPTIONAL_LOCKS"] = "0"
        values["GIT_TERMINAL_PROMPT"] = "0"
        values["LC_ALL"] = "C"
        return values
    }

    private func command(_ executable: URL, folder: URL, _ arguments: [String]) async throws -> GitProcessResult {
        try Task.checkCancellation()
        return try await runner.run(executableURL: executable, arguments: [
            "--no-pager", "--no-optional-locks", "--no-lazy-fetch", "--literal-pathspecs", "--no-replace-objects",
            "-c", "core.fsmonitor=false", "-c", "log.showSignature=false", "-C", folder.path
        ] + arguments, environment: Self.environment)
    }

    private func checked(_ result: GitProcessResult) throws -> GitProcessResult {
        guard result.status == 0 else {
            throw GitDocumentHistoryError.commandFailed(String(decoding: result.standardError.prefix(2_000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private func terminatedLine(_ data: Data) throws -> String {
        guard var line = String(data: data, encoding: .utf8), line.hasSuffix("\n") else {
            throw GitDocumentHistoryError.invalidHistory
        }
        line.removeLast()
        return line
    }

    private static func isObjectID(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Paths are NUL-delimited, including names containing tabs and newlines.
    package static func parseHistory(_ data: Data, currentPath: String) throws -> [GitDocumentRevision] {
        guard let text = String(data: data, encoding: .utf8) else { throw GitDocumentHistoryError.invalidHistory }
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var index = 0, path = currentPath, revisions: [GitDocumentRevision] = []
        var seen = Set<String>()
        while index < fields.count {
            while index < fields.count && fields[index].isEmpty { index += 1 }
            if index == fields.count { break }
            guard index + 2 < fields.count, isObjectID(fields[index]), let seconds = TimeInterval(fields[index + 1]), seconds.isFinite else {
                throw GitDocumentHistoryError.invalidHistory
            }
            let commitID = fields[index], date = Date(timeIntervalSince1970: seconds), subject = fields[index + 2]
            index += 3
            var historicalPath: String?, earlierPath: String?
            while index < fields.count && !fields[index].isEmpty {
                let status = fields[index].trimmingCharacters(in: .newlines)
                index += 1
                guard !status.isEmpty, index < fields.count, !fields[index].isEmpty else { throw GitDocumentHistoryError.invalidHistory }
                let firstPath = fields[index]
                index += 1
                if status.hasPrefix("R") || status.hasPrefix("C") {
                    guard index < fields.count, !fields[index].isEmpty else { throw GitDocumentHistoryError.invalidHistory }
                    let destination = fields[index]
                    index += 1
                    if destination == path {
                        historicalPath = destination
                        earlierPath = firstPath
                    }
                } else if firstPath == path && status != "D" {
                    historicalPath = firstPath
                }
            }
            if let historicalPath, seen.insert(commitID).inserted {
                revisions.append(GitDocumentRevision(commitID: commitID, historicalPath: historicalPath,
                                                      subject: subject, committerDate: date))
            }
            if let earlierPath { path = earlierPath }
        }
        return revisions
    }
}

private final class GitExecutableCache: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    func get() -> URL? { lock.withLock { url } }
    func set(_ url: URL) { lock.withLock { self.url = url } }
}
#endif

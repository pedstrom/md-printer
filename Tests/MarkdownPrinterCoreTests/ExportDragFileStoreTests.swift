import AppKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class ExportDragFileStoreTests: XCTestCase {
    func testMaterializedExportsAdvertiseConcreteFileURLsWithExactNamesBytesAndPermissions() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = ExportDragFileStore(temporaryDirectory: temporaryDirectory)

        for (expectedFileName, expectedData, expectedContentType) in [
            ("Quarterly Notes.final.pdf", Data("exact PDF bytes".utf8), ExportFormat.pdf.contentType),
            ("Quarterly Notes.final.docx", Data("exact Word bytes".utf8), ExportFormat.word.contentType)
        ] {
            let artifact = try store.materialize(data: expectedData, fileName: expectedFileName)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            pasteboard.clearContents()

            XCTAssertTrue(pasteboard.writeObjects([artifact.fileURL as NSURL]))
            XCTAssertEqual(pasteboard.availableType(from: [.fileURL]), .fileURL)
            let fileURLs = try XCTUnwrap(pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL])
            XCTAssertEqual(fileURLs, [artifact.fileURL])
            XCTAssertEqual(artifact.fileURL.lastPathComponent, expectedFileName)
            XCTAssertEqual(try Data(contentsOf: artifact.fileURL), expectedData)
            XCTAssertEqual(
                try artifact.fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType,
                expectedContentType
            )
            XCTAssertEqual(try permissions(of: artifact.directoryURL), 0o700)
            XCTAssertEqual(try permissions(of: artifact.fileURL), 0o600)
        }
    }

    func testRepeatedFileNamesUseUniqueDirectoriesWithoutChangingVisibleName() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = ExportDragFileStore(temporaryDirectory: temporaryDirectory)

        let first = try store.materialize(data: Data("first".utf8), fileName: "Report.pdf")
        let second = try store.materialize(data: Data("second".utf8), fileName: "Report.pdf")

        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertEqual(first.fileURL.lastPathComponent, "Report.pdf")
        XCTAssertEqual(second.fileURL.lastPathComponent, "Report.pdf")
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.fileURL), Data("second".utf8))
    }

    func testCanceledDragRemovesArtifactImmediately() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = ExportDragFileStore(temporaryDirectory: temporaryDirectory)
        let artifact = try store.materialize(data: Data("PDF".utf8), fileName: "Canceled.pdf")

        store.finish(artifact, operation: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.directoryURL.path))
    }

    func testAcceptedDragRetainsArtifactUntilScheduledCleanup() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var scheduledDelay: TimeInterval?
        var scheduledCleanup: DispatchWorkItem?
        let store = ExportDragFileStore(
            temporaryDirectory: temporaryDirectory,
            scheduleCleanup: { delay, action in
                scheduledDelay = delay
                scheduledCleanup = action
            }
        )
        let artifact = try store.materialize(data: Data("PDF".utf8), fileName: "Accepted.pdf")

        store.finish(artifact, operation: .copy)

        XCTAssertEqual(scheduledDelay, ExportDragFileStore.acceptedDragRetention)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))
        try XCTUnwrap(scheduledCleanup).perform()
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.directoryURL.path))
    }

    func testAbandonedArtifactsOlderThanOneDayAreRemoved() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let currentDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = ExportDragFileStore(
            temporaryDirectory: temporaryDirectory,
            now: { currentDate }
        )
        try FileManager.default.createDirectory(
            at: store.rootDirectoryURL,
            withIntermediateDirectories: true
        )
        let staleDirectory = store.rootDirectoryURL.appendingPathComponent("stale", isDirectory: true)
        let freshDirectory = store.rootDirectoryURL.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: freshDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.modificationDate: currentDate.addingTimeInterval(-ExportDragFileStore.abandonedArtifactAge - 1)],
            ofItemAtPath: staleDirectory.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: currentDate],
            ofItemAtPath: freshDirectory.path
        )

        store.removeAbandonedArtifacts()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshDirectory.path))
    }

    func testInvalidNameAndUnavailableTemporaryDirectoryReportFailures() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = ExportDragFileStore(temporaryDirectory: temporaryDirectory)

        XCTAssertThrowsError(try store.materialize(
            data: Data("PDF".utf8),
            fileName: "Nested/Report.pdf"
        )) { error in
            XCTAssertEqual(error as? ExportDragFileStoreError, .invalidFileName)
            XCTAssertEqual(
                error.localizedDescription,
                "The document could not be prepared for dragging because its filename is invalid."
            )
        }

        let unavailableDirectory = temporaryDirectory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: unavailableDirectory)
        let unavailableStore = ExportDragFileStore(temporaryDirectory: unavailableDirectory)
        XCTAssertThrowsError(try unavailableStore.materialize(
            data: Data("PDF".utf8),
            fileName: "Report.pdf"
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

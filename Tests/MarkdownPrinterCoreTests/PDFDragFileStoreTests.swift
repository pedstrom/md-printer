import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class PDFDragFileStoreTests: XCTestCase {
    func testMaterializedPDFAdvertisesConcreteFileURLWithExactNameBytesAndPermissions() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let expectedData = Data("exact preview bytes".utf8)
        let expectedFileName = "Quarterly Notes.final.pdf"
        let store = PDFDragFileStore(temporaryDirectory: temporaryDirectory)

        let artifact = try store.materialize(pdfData: expectedData, fileName: expectedFileName)
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
        XCTAssertEqual(try permissions(of: artifact.directoryURL), 0o700)
        XCTAssertEqual(try permissions(of: artifact.fileURL), 0o600)
    }

    func testRepeatedFileNamesUseUniqueDirectoriesWithoutChangingVisibleName() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = PDFDragFileStore(temporaryDirectory: temporaryDirectory)

        let first = try store.materialize(pdfData: Data("first".utf8), fileName: "Report.pdf")
        let second = try store.materialize(pdfData: Data("second".utf8), fileName: "Report.pdf")

        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertEqual(first.fileURL.lastPathComponent, "Report.pdf")
        XCTAssertEqual(second.fileURL.lastPathComponent, "Report.pdf")
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second.fileURL), Data("second".utf8))
    }

    func testCanceledDragRemovesArtifactImmediately() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = PDFDragFileStore(temporaryDirectory: temporaryDirectory)
        let artifact = try store.materialize(pdfData: Data("PDF".utf8), fileName: "Canceled.pdf")

        store.finish(artifact, operation: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.directoryURL.path))
    }

    func testAcceptedDragRetainsArtifactUntilScheduledCleanup() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var scheduledDelay: TimeInterval?
        var scheduledCleanup: DispatchWorkItem?
        let store = PDFDragFileStore(
            temporaryDirectory: temporaryDirectory,
            scheduleCleanup: { delay, action in
                scheduledDelay = delay
                scheduledCleanup = action
            }
        )
        let artifact = try store.materialize(pdfData: Data("PDF".utf8), fileName: "Accepted.pdf")

        store.finish(artifact, operation: .copy)

        XCTAssertEqual(scheduledDelay, PDFDragFileStore.acceptedDragRetention)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))
        try XCTUnwrap(scheduledCleanup).perform()
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.directoryURL.path))
    }

    func testAbandonedArtifactsOlderThanOneDayAreRemoved() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let currentDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let store = PDFDragFileStore(
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
            [.modificationDate: currentDate.addingTimeInterval(-PDFDragFileStore.abandonedArtifactAge - 1)],
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
        let store = PDFDragFileStore(temporaryDirectory: temporaryDirectory)

        XCTAssertThrowsError(try store.materialize(
            pdfData: Data("PDF".utf8),
            fileName: "Nested/Report.pdf"
        )) { error in
            XCTAssertEqual(error as? PDFDragFileStoreError, .invalidFileName)
        }

        let unavailableDirectory = temporaryDirectory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: unavailableDirectory)
        let unavailableStore = PDFDragFileStore(temporaryDirectory: unavailableDirectory)
        XCTAssertThrowsError(try unavailableStore.materialize(
            pdfData: Data("PDF".utf8),
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

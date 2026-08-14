import Foundation
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class SourceFileMonitorTests: XCTestCase {
    func testPresenterChangesAreDebouncedAndStopCancelsPendingDelivery() async throws {
        let sourceURL = try makeSourceFile()
        var changeCount = 0
        let monitor = SourceFileMonitor(
            sourceURL: sourceURL,
            debounceInterval: 0.01
        ) {
            changeCount += 1
        }

        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isMonitoring)
        monitor.presentedItemDidChange()
        monitor.presentedItemDidChange()
        monitor.presentedItemDidChange()
        await wait(milliseconds: 40)

        XCTAssertEqual(changeCount, 1)

        monitor.presentedItemDidChange()
        monitor.stop()
        monitor.stop()
        await wait(milliseconds: 30)

        XCTAssertFalse(monitor.isMonitoring)
        XCTAssertEqual(changeCount, 1)
    }

    func testPresenterFiltersSubitemChangesAndRecognizesAtomicMoves() async throws {
        let sourceURL = try makeSourceFile()
        let siblingURL = sourceURL.deletingLastPathComponent().appendingPathComponent("Sibling.md")
        var changeCount = 0
        let monitor = SourceFileMonitor(
            sourceURL: sourceURL,
            debounceInterval: 0.005
        ) {
            changeCount += 1
        }
        monitor.start()
        defer { monitor.stop() }

        monitor.presentedSubitemDidChange(at: siblingURL)
        monitor.presentedSubitem(
            at: siblingURL,
            didMoveTo: siblingURL.deletingPathExtension().appendingPathExtension("txt")
        )
        monitor.accommodatePresentedSubitemDeletion(at: siblingURL) { error in
            XCTAssertNil(error)
        }
        await wait(milliseconds: 20)
        XCTAssertEqual(changeCount, 0)

        monitor.presentedSubitemDidChange(at: sourceURL)
        await wait(milliseconds: 20)
        XCTAssertEqual(changeCount, 1)

        monitor.presentedSubitem(at: siblingURL, didMoveTo: sourceURL)
        await wait(milliseconds: 20)
        XCTAssertEqual(changeCount, 2)

        monitor.presentedSubitem(at: sourceURL, didMoveTo: siblingURL)
        await wait(milliseconds: 20)
        XCTAssertEqual(changeCount, 3)

        monitor.accommodatePresentedSubitemDeletion(at: sourceURL) { error in
            XCTAssertNil(error)
        }
        await wait(milliseconds: 20)
        XCTAssertEqual(changeCount, 4)
    }

    func testPresenterDetectsAnAtomicWriteToTheSourceFile() async throws {
        let sourceURL = try makeSourceFile()
        let changed = expectation(description: "source change delivered")
        let monitor = SourceFileMonitor(
            sourceURL: sourceURL,
            debounceInterval: 0.01
        ) {
            changed.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        try Data("# Updated atomically".utf8).write(to: sourceURL, options: .atomic)

        await fulfillment(of: [changed], timeout: 1)
    }

    func testPresenterDetectsAnInPlaceWriteToTheSourceFile() async throws {
        let sourceURL = try makeSourceFile()
        let changed = expectation(description: "in-place source change delivered")
        let monitor = SourceFileMonitor(
            sourceURL: sourceURL,
            debounceInterval: 0.01
        ) {
            changed.fulfill()
        }
        monitor.start()
        defer { monitor.stop() }

        try Data("# Updated in place".utf8).write(to: sourceURL)

        await fulfillment(of: [changed], timeout: 1)
    }

    func testStoppedPresenterReleasesWhenItsOwnerGoesAway() throws {
        let sourceURL = try makeSourceFile()
        weak var releasedMonitor: SourceFileMonitor?

        autoreleasepool {
            let monitor = SourceFileMonitor(sourceURL: sourceURL) { }
            monitor.start()
            monitor.stop()
            releasedMonitor = monitor
        }

        XCTAssertNil(releasedMonitor)
    }

    private func makeSourceFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("Source.md")
        try Data("# Source".utf8).write(to: sourceURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return sourceURL
    }

    private func wait(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

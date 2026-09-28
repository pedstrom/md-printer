import AppKit
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class ExportDragSessionTests: XCTestCase {
    func testLiveToggleChangesThePublishedURLAndBytesInBothDirectionsAndCachesEachExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExportDragFileStore(temporaryDirectory: root)
        let document = DocumentSession()
        try document.apply(MarkdownDocument(title: "Live drag", markdown: "# Live drag\n\nEditable content."))
        let bytes: [ExportFormat: Data] = [
            .pdf: try document.exportData(as: .pdf),
            .word: try document.exportData(as: .word)
        ]

        for preferred in ExportFormat.allCases {
            for initialFlags: NSEvent.ModifierFlags in [[], .option] {
                var generated: [ExportFormat] = []
                let payload = ExportDragPayload(
                    format: preferred,
                    fileName: "Live drag.final.\(preferred.pathExtension)",
                    dataProvider: { generated.append(preferred); return bytes[preferred]! },
                    alternateDataProvider: { generated.append(preferred.alternate); return bytes[preferred.alternate]! }
                )
                let drag = try ExportDragSession(payload: payload, modifierFlags: initialFlags, store: store)
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                XCTAssertTrue(pasteboard.writeObjects([drag.pasteboardItem]))
                // Read before switching, as a destination does when the pointer enters.
                let firstURL = try readURL(pasteboard)
                XCTAssertEqual(try Data(contentsOf: firstURL), bytes[drag.format])
                var urls: Set<URL> = [firstURL]
                for flags: NSEvent.ModifierFlags in [.option, [.option, .shift], [], .command, .option, []] {
                    let previousFormat = drag.format
                    let expected = preferred.forAction(modifierFlags: flags)
                    XCTAssertEqual(try drag.update(modifierFlags: flags, pasteboard: pasteboard), previousFormat != expected)
                    XCTAssertEqual(drag.format, expected)
                    let url = try readURL(pasteboard)
                    XCTAssertEqual(url.lastPathComponent, "Live drag.final.\(expected.pathExtension)")
                    XCTAssertEqual(try Data(contentsOf: url), bytes[expected])
                    XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
                    urls.insert(url)
                }
                XCTAssertEqual(generated.count, 2)
                XCTAssertEqual(Set(generated), Set(ExportFormat.allCases))
                XCTAssertEqual(urls.count, 2)
                drag.finish(operation: [])
                for url in urls { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
            }
        }
    }

    func testAcceptedDropRetainsOnlyTheFinalFormatUntilCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var cleanups: [DispatchWorkItem] = []
        let store = ExportDragFileStore(temporaryDirectory: root, scheduleCleanup: { _, work in cleanups.append(work) })
        let drag = try ExportDragSession(payload: payload(), modifierFlags: [], store: store)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([drag.pasteboardItem]))
        let pdfURL = try readURL(pasteboard)
        XCTAssertTrue(try drag.update(modifierFlags: .option, pasteboard: pasteboard))
        let wordURL = try readURL(pasteboard)

        drag.finish(operation: .copy)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pdfURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wordURL.path))
        XCTAssertEqual(cleanups.count, 1)
        cleanups[0].perform()
        XCTAssertFalse(FileManager.default.fileExists(atPath: wordURL.path))
    }

    func testFailedAlternateExportKeepsThePreviousFileAndRetriesOnlyAfterAnotherToggle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let payload = ExportDragPayload(
            format: .pdf, fileName: "Document.pdf", dataProvider: { Data("PDF".utf8) },
            alternateDataProvider: {
                attempts += 1
                if attempts == 1 { throw ExportDragFileStoreError.invalidFileName }
                return Data("Word".utf8)
            }
        )
        let drag = try ExportDragSession(payload: payload, modifierFlags: [], store: ExportDragFileStore(temporaryDirectory: root))
        defer { drag.finish(operation: []) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([drag.pasteboardItem]))
        let originalURL = try readURL(pasteboard)

        XCTAssertThrowsError(try drag.update(modifierFlags: .option, pasteboard: pasteboard))
        XCTAssertFalse(try drag.update(modifierFlags: .option, pasteboard: pasteboard))
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(drag.format, .pdf)
        XCTAssertEqual(try readURL(pasteboard), originalURL)
        XCTAssertFalse(try drag.update(modifierFlags: [], pasteboard: pasteboard))
        XCTAssertTrue(try drag.update(modifierFlags: .option, pasteboard: pasteboard))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(drag.format, .word)
    }

    func testMissingAlternateAndLostPasteboardDoNotChangeTheAdvertisedFormat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExportDragFileStore(temporaryDirectory: root)
        let pdfOnly = try ExportDragSession(
            payload: ExportDragPayload(format: .pdf, fileName: "Document.pdf", dataProvider: { Data() }),
            modifierFlags: .option, store: store
        )
        let drag = try ExportDragSession(payload: payload(), modifierFlags: [], store: store)
        defer { pdfOnly.finish(operation: []); drag.finish(operation: []) }
        let emptyPasteboard = NSPasteboard.withUniqueName()
        defer { emptyPasteboard.releaseGlobally() }

        XCTAssertFalse(try pdfOnly.update(modifierFlags: [], pasteboard: emptyPasteboard))
        XCTAssertEqual(pdfOnly.format, .pdf)
        XCTAssertThrowsError(try drag.update(modifierFlags: .option, pasteboard: emptyPasteboard)) { error in
            XCTAssertEqual(error as? ExportDragSessionError, .unavailablePasteboard)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(drag.format, .pdf)
    }

    func testModifierMonitorRunsWhileStationaryInTheDragTrackingLoopAndStops() throws {
        let monitor = ExportDragModifierMonitor()
        var flags: NSEvent.ModifierFlags = []
        var observed: [NSEvent.ModifierFlags] = []
        monitor.start(modifierFlags: { flags }, onChange: { observed.append($0) })
        defer { monitor.stop() }
        runTrackingLoop()
        XCTAssertEqual(observed.last, [])
        flags = .option
        runTrackingLoop()
        XCTAssertEqual(observed.last, .option)
        flags = []
        runTrackingLoop()
        XCTAssertEqual(observed.last, [])

        // Restart must remove the previous observation, and real flagsChanged
        // events must update synchronously even between polling ticks.
        monitor.start(modifierFlags: { flags }, onChange: { observed.append($0) })
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 58
        ))
        let count = observed.count
        NSApplication.shared.sendEvent(event)
        XCTAssertEqual(observed.count, count + 1)
        XCTAssertEqual(observed.last, .option)

        monitor.stop()
        let stoppedCount = observed.count
        runTrackingLoop()
        NSApplication.shared.sendEvent(event)
        XCTAssertEqual(observed.count, stoppedCount)
    }

    private func payload() -> ExportDragPayload {
        ExportDragPayload(
            format: .pdf, fileName: "Document.pdf", dataProvider: { Data("PDF".utf8) },
            alternateDataProvider: { Data("Word".utf8) }
        )
    }

    private func readURL(_ pasteboard: NSPasteboard) throws -> URL {
        let urls = try XCTUnwrap(pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])
        XCTAssertEqual(urls.count, 1)
        return try XCTUnwrap(urls.first)
    }

    private func runTrackingLoop() {
        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
    }
}

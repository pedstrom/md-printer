import PDFKit
import Combine
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class DocumentSessionTests: XCTestCase {
    func testInitialStateAndNoDocumentErrors() throws {
        let session = DocumentSession()
        XCTAssertEqual(session.title, "Markdown Printer")
        XCTAssertFalse(session.hasDocument)
        XCTAssertEqual(session.suggestedPDFFileName, "Markdown Printer.pdf")
        XCTAssertEqual(session.suggestedWordFileName, "Markdown Printer.docx")
        XCTAssertThrowsError(try session.pdfData()) { XCTAssertEqual($0 as? DocumentSessionError, .noDocument) }
        XCTAssertThrowsError(try session.exportData(as: .word)) {
            XCTAssertEqual($0 as? DocumentSessionError, .noDocument)
        }
        XCTAssertThrowsError(try session.savePDF(to: FileManager.default.temporaryDirectory.appendingPathComponent("none.pdf")))
        XCTAssertThrowsError(try session.printOperation())
        XCTAssertEqual(DocumentSessionError.noDocument.localizedDescription, "Open a Markdown file before saving or printing.")
    }

    func testApplyCreatesPreviewPDFAndClearsError() throws {
        let session = DocumentSession()
        var snapshots: [RenderedDocumentSnapshot] = []
        let observation = session.$renderedSnapshot.compactMap { $0 }.sink {
            snapshots.append($0)
        }
        session.report(error: TestError.example)
        try session.apply(MarkdownDocument(title: "Sample", markdown: "# Sample"))
        XCTAssertEqual(session.title, "Sample")
        XCTAssertEqual(session.suggestedPDFFileName, "Sample.pdf")
        XCTAssertEqual(session.suggestedWordFileName, "Sample.docx")
        XCTAssertTrue(session.hasDocument)
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.renderedText.string.contains("Sample"))
        XCTAssertNotNil(PDFDocument(data: try session.pdfData()))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].revision, 1)
        XCTAssertEqual(snapshots[0].document.title, "Sample")
        XCTAssertTrue(snapshots[0].renderedText.string.contains("Sample"))
        XCTAssertEqual(snapshots[0].pdfData, session.renderedPDFData)
        session.report(error: TestError.example)
        XCTAssertEqual(session.errorMessage, "Example failure")
        session.clearError()
        XCTAssertNil(session.errorMessage)
        withExtendedLifetime(observation) { }
    }

    func testSynchronizeSkipsAnIdenticalDocumentAndPublishesAChangedDocument() throws {
        let session = DocumentSession()
        let original = MarkdownDocument(title: "Sample", markdown: "# Sample\n\nOriginal body.")
        try session.apply(original)
        let originalSnapshot = try XCTUnwrap(session.renderedSnapshot)

        XCTAssertFalse(try session.synchronize(with: original))
        XCTAssertEqual(session.renderedSnapshot?.revision, originalSnapshot.revision)
        XCTAssertEqual(session.renderedPDFData, originalSnapshot.pdfData)

        let changed = MarkdownDocument(title: "Sample", markdown: "# Sample\n\nChanged body.")
        XCTAssertTrue(try session.synchronize(with: changed))
        XCTAssertGreaterThan(try XCTUnwrap(session.renderedSnapshot).revision, originalSnapshot.revision)
        XCTAssertTrue(session.renderedText.string.contains("Changed body."))
    }

    func testLoadDataHandlesValidAndInvalidInput() {
        let session = DocumentSession()
        session.load(data: Data("# Markdown Title\n\nBody".utf8), suggestedTitle: "Filename")
        XCTAssertEqual(session.title, "Markdown Title")
        session.load(data: Data([0xFF]))
        XCTAssertEqual(session.errorMessage, "The file is not valid UTF-8 or UTF-16 text.")
        XCTAssertEqual(session.title, "Markdown Title")
    }

    func testLoadURLSaveAndPrint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Input.md")
        let output = directory.appendingPathComponent("Output.pdf")
        let wordOutput = directory.appendingPathComponent("Output.docx")
        try Data("# From File".utf8).write(to: input)

        let session = DocumentSession()
        session.load(url: input)
        XCTAssertEqual(session.title, "From File")
        XCTAssertEqual(session.suggestedPDFFileName, "Input.pdf")
        XCTAssertEqual(session.suggestedWordFileName, "Input.docx")
        try session.savePDF(to: output)
        try session.save(to: wordOutput, as: .word)
        XCTAssertNotNil(PDFDocument(url: output))
        XCTAssertEqual(try Data(contentsOf: output), try session.exportData(as: .pdf))
        XCTAssertTrue(try Data(contentsOf: wordOutput).starts(with: Data([0x50, 0x4B])))
        XCTAssertNotNil(try session.printOperation().view)

        session.load(url: directory.appendingPathComponent("missing.md"))
        XCTAssertNotNil(session.errorMessage)
    }

    func testSuggestedPDFFileNameUsesOriginalCompoundFileNameInsteadOfH1() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("Quarterly Notes.final.markdown")
        try Data("# Executive Summary".utf8).write(to: input)

        let session = DocumentSession()
        session.load(url: input)

        XCTAssertEqual(session.title, "Executive Summary")
        XCTAssertEqual(session.suggestedPDFFileName, "Quarterly Notes.final.pdf")
        XCTAssertEqual(session.suggestedWordFileName, "Quarterly Notes.final.docx")
    }

    func testSuggestedPDFFileNameSanitizesInMemoryTitle() throws {
        let session = DocumentSession()
        try session.apply(MarkdownDocument(title: "Plans: July/August", markdown: "Body"))
        XCTAssertEqual(session.suggestedPDFFileName, "Plans- July-August.pdf")

        try session.apply(MarkdownDocument(title: "already.PDF", markdown: "Body"))
        XCTAssertEqual(session.suggestedPDFFileName, "already.PDF")
        XCTAssertEqual(session.suggestedWordFileName, "already.docx")

        try session.apply(MarkdownDocument(title: "already.DOCX", markdown: "Body"))
        XCTAssertEqual(session.suggestedPDFFileName, "already.pdf")
        XCTAssertEqual(session.suggestedWordFileName, "already.DOCX")
    }

    func testSourceMonitoringRefreshesOnlyChangedSessionAndRecoversFromInvalidWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("First.md")
        let secondURL = directory.appendingPathComponent("Second.md")
        try Data("# First\n\nOriginal first body.".utf8).write(to: firstURL)
        try Data("# Second\n\nOriginal second body.".utf8).write(to: secondURL)

        var monitors: [TestSourceMonitor] = []
        let factory: (URL, @escaping () -> Void) -> SourceChangeMonitoring = { url, onChange in
            let monitor = TestSourceMonitor(sourceURL: url, onChange: onChange)
            monitors.append(monitor)
            return monitor
        }
        let firstSession = DocumentSession(sourceMonitorFactory: factory)
        let secondSession = DocumentSession(sourceMonitorFactory: factory)
        try firstSession.apply(MarkdownDocument.load(from: firstURL))
        try secondSession.apply(MarkdownDocument.load(from: secondURL))

        firstSession.startMonitoringSourceChanges()
        firstSession.startMonitoringSourceChanges()
        secondSession.startMonitoringSourceChanges()
        XCTAssertEqual(monitors.count, 2)
        XCTAssertTrue(monitors.allSatisfy(\.isMonitoring))

        let firstRevision = try XCTUnwrap(firstSession.renderedSnapshot).revision
        let secondRevision = try XCTUnwrap(secondSession.renderedSnapshot).revision
        try Data("# First Updated\n\nChanged first body.".utf8).write(to: firstURL, options: .atomic)
        monitors[0].trigger()

        XCTAssertEqual(firstSession.title, "First Updated")
        XCTAssertGreaterThan(try XCTUnwrap(firstSession.renderedSnapshot).revision, firstRevision)
        XCTAssertEqual(try XCTUnwrap(secondSession.renderedSnapshot).revision, secondRevision)

        let unchangedRevision = try XCTUnwrap(firstSession.renderedSnapshot).revision
        monitors[0].trigger()
        XCTAssertEqual(try XCTUnwrap(firstSession.renderedSnapshot).revision, unchangedRevision)

        let lastValidPDF = firstSession.renderedPDFData
        try Data([0xFF]).write(to: firstURL, options: .atomic)
        monitors[0].trigger()
        XCTAssertEqual(firstSession.renderedPDFData, lastValidPDF)
        XCTAssertEqual(try XCTUnwrap(firstSession.renderedSnapshot).revision, unchangedRevision)
        XCTAssertEqual(firstSession.errorMessage, "The file is not valid UTF-8 or UTF-16 text.")

        try Data("# Recovered\n\nValid again.".utf8).write(to: firstURL, options: .atomic)
        monitors[0].trigger()
        XCTAssertEqual(firstSession.title, "Recovered")
        XCTAssertNil(firstSession.errorMessage)
        XCTAssertGreaterThan(try XCTUnwrap(firstSession.renderedSnapshot).revision, unchangedRevision)

        firstSession.stopMonitoringSourceChanges()
        secondSession.stopMonitoringSourceChanges()
        XCTAssertTrue(monitors.allSatisfy { !$0.isMonitoring })
        XCTAssertEqual(monitors.map(\.stopCount), [1, 1])
    }

    func testMonitoringWithoutAFileBackedDocumentIsANoOp() {
        var factoryCallCount = 0
        let session = DocumentSession { url, onChange in
            factoryCallCount += 1
            return TestSourceMonitor(sourceURL: url, onChange: onChange)
        }

        session.startMonitoringSourceChanges()
        session.stopMonitoringSourceChanges()

        XCTAssertEqual(factoryCallCount, 0)
    }

    func testSessionLifetimeStopsSourceMonitoringAfterDeinitialization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Lifetime.md")
        try Data("# Lifetime".utf8).write(to: sourceURL)
        var monitor: TestSourceMonitor?
        weak var releasedSession: DocumentSession?

        autoreleasepool {
            let session = DocumentSession { url, onChange in
                let createdMonitor = TestSourceMonitor(sourceURL: url, onChange: onChange)
                monitor = createdMonitor
                return createdMonitor
            }
            try? session.apply(MarkdownDocument.load(from: sourceURL))
            session.startMonitoringSourceChanges()
            releasedSession = session
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertNil(releasedSession)
        XCTAssertFalse(try XCTUnwrap(monitor).isMonitoring)
        XCTAssertEqual(try XCTUnwrap(monitor).stopCount, 1)
    }

    func testStartingMonitoringCatchesUpAChangeThatPrecededRegistration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Catchup.md")
        try Data("# Original\n\nOld body.".utf8).write(to: sourceURL)
        let staleDocument = try MarkdownDocument.load(from: sourceURL)
        let session = DocumentSession { url, onChange in
            TestSourceMonitor(sourceURL: url, onChange: onChange)
        }
        try session.apply(staleDocument)
        try Data("# Catchup\n\nNewest body.".utf8).write(to: sourceURL, options: .atomic)

        session.startMonitoringSourceChanges()

        XCTAssertEqual(session.title, "Catchup")
        XCTAssertEqual(session.document?.markdown, "# Catchup\n\nNewest body.")
        session.startMonitoringSourceChanges()
        XCTAssertEqual(session.title, "Catchup")
        session.stopMonitoringSourceChanges()
    }

}

private enum TestError: LocalizedError {
    case example
    var errorDescription: String? { "Example failure" }
}

@MainActor
private final class TestSourceMonitor: SourceChangeMonitoring {
    let sourceURL: URL
    private let onChange: () -> Void
    private(set) var isMonitoring = false
    private(set) var stopCount = 0

    init(sourceURL: URL, onChange: @escaping () -> Void) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.onChange = onChange
    }

    func start() {
        isMonitoring = true
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        stopCount += 1
    }

    func trigger() {
        guard isMonitoring else { return }
        onChange()
    }
}

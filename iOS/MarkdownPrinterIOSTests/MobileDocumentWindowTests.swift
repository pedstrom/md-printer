import XCTest
import UIKit
import MarkdownPrinterCore
@testable import MarkdownPrinterMobileSupport

@MainActor
final class MobileDocumentWindowTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/one/Report.md")
    private let second = URL(fileURLWithPath: "/tmp/two/Report.md")

    func testIncomingDocumentsUseEmptyWindowThenSeparateWindowsAndDeduplicatePendingRequests() throws {
        let router = MobileDocumentWindowRouter()
        let current = UUID()
        router.register(current, urls: [], sessionID: "first")
        XCTAssertEqual(router.sessionID(for: current), "first")
        XCTAssertNil(router.sessionID(for: UUID()))
        XCTAssertEqual(router.route(first, from: current, multipleWindows: true), current)
        let request = try XCTUnwrap(router.requests[current])
        XCTAssertEqual(request.url, first)
        let other = try XCTUnwrap(router.route(second, from: current, multipleWindows: true))
        XCTAssertNotEqual(other, current)
        router.register(other, urls: []) // Scene attachment must retain the pending reservation.
        XCTAssertEqual(router.route(second, from: current, multipleWindows: true), other)
        XCTAssertEqual(router.route(first, from: other, multipleWindows: true), current)
        // A late completion must not remove a newer request for the same scene.
        router.complete(request, in: current)
        XCTAssertNotNil(router.requests[current])
        router.complete(try XCTUnwrap(router.requests[current]), in: current)
        XCTAssertNil(router.requests[current])
        router.register(other, urls: [second], sessionID: "second")
        router.discard(sessionID: "second")
        XCTAssertNil(router.sessionID(for: other))
        router.discard(sessionID: "unknown")
        XCTAssertNil(router.requests[other])
        XCTAssertNotEqual(router.route(second, from: current, multipleWindows: true), other)
    }

    func testPhoneReplacesAndUnsupportedDropsDoNotCreateRequests() {
        let router = MobileDocumentWindowRouter()
        let current = UUID()
        router.register(current, urls: [first])
        XCTAssertEqual(router.route(second, from: current, multipleWindows: false), current)
        XCTAssertEqual(router.requests[current]?.url, second)
        XCTAssertNil(router.route(URL(string: "https://example.com/file.md")!, from: current, multipleWindows: true))
        XCTAssertNil(router.route(URL(fileURLWithPath: "/tmp/file.pdf"), from: current, multipleWindows: true))
        XCTAssertTrue(MobileDocumentIdentity.accepts(URL(fileURLWithPath: "/tmp/file.MARKDOWN")))
        XCTAssertEqual(MobileDocumentIdentity.key(for: URL(fileURLWithPath: "/tmp/one/../one/Report.md")), MobileDocumentIdentity.key(for: first))
    }

    func testWindowStateRestoresNavigationSearchAndReadingWithoutCrossWindowState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("root.md")
        let link = directory.appendingPathComponent("link.md")
        try Data("# Root".utf8).write(to: root)
        try Data("# Link".utf8).write(to: link)
        let state = MobileDocumentWindowState()
        XCTAssertNil(state.rootURL)
        XCTAssertTrue(state.documentURLs.isEmpty)
        state.open(root)
        state.linkedDocuments = [link]
        var reader = MobileReaderRestoration()
        reader.query = "needle"
        reader.matchCase = true
        reader.wholeWord = true
        reader.selectedMatch = 2
        reader.visibleBlock = "block-5"
        reader.toolbarsVisible = false
        state.saveReader(reader, for: link)
        state.saveReader(reader, for: link)
        state.saveReader(reader, for: nil)
        let snapshot = state.restoration
        XCTAssertEqual(MobileWindowRestoration.decode(snapshot.encoded), snapshot)
        let restored = MobileDocumentWindowState()
        restored.restore(MobileWindowRestoration.decode(snapshot.encoded))
        XCTAssertEqual(restored.documentURLs, [root, link])
        XCTAssertEqual(restored.reader(for: link), reader)
        XCTAssertEqual(restored.reader(for: nil), MobileReaderRestoration())
        XCTAssertEqual(restored.reader(for: second), MobileReaderRestoration())
        restored.open(link)
        XCTAssertEqual(restored.linkedDocuments, [link])
        restored.open(root)
        XCTAssertTrue(restored.linkedDocuments.isEmpty)
        XCTAssertEqual(state.linkedDocuments, [link])
        restored.browse()
        XCTAssertNil(restored.rootURL)
        XCTAssertTrue(restored.readers.isEmpty)
        XCTAssertEqual(state.reader(for: link), reader)
        restored.open(URL(string: "https://example.com/file.md")!)
        XCTAssertNil(restored.rootURL)
        restored.open(second)
        XCTAssertEqual(restored.rootURL, second)
        XCTAssertEqual(MobileWindowRestoration.decode("invalid"), MobileWindowRestoration())
        XCTAssertEqual(MobileWindowRestoration.decode(Data("{}bad".utf8).base64EncodedString()), MobileWindowRestoration())
    }

    func testBookmarkRenewalUsesResolvedAddressAndFailedAccessRetainsRecoveryAddress() {
        let bookmark = MobileDocumentBookmark(url: first, create: { _ in Data([1]) })
        XCTAssertEqual(bookmark.resolve(using: { _ in self.second }), second)
        XCTAssertEqual(bookmark.resolve(using: { _ in throw CocoaError(.fileReadNoPermission) }), first)
        let failed = MobileDocumentBookmark(url: second, create: { _ in throw CocoaError(.fileReadNoPermission) })
        XCTAssertNil(failed.data)
        XCTAssertEqual(failed.resolve(), second)
    }

    func testMarkdownLinkWindowActionsOnlyIncludeLocalDocumentsAndDeduplicateNestedLinks() {
        let link: InlineNode = .link(children: [.text("Linked")], destination: "Report.md")
        let links = MobileMarkdownWindowLinks.links(in: [
            link, link, .strong([.emphasis([.underline([.strikethrough([link])])])]),
            .link(children: [], destination: "https://example.com/test.md"),
            .link(children: [], destination: "image.png"), .text("plain")
        ], relativeTo: first.deletingLastPathComponent())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.url, first)
        XCTAssertEqual(links.first?.label, "Report.md")
    }

    func testShareAnchoringResizeLifetimeAndRepeatedCompletion() throws {
        let host = UIViewController()
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let anchor = UIView(frame: CGRect(x: 700, y: 20, width: 44, height: 44))
        host.view.addSubview(anchor)
        var presented: UIViewController?
        let presenter = MobilePDFPresentationController(presentActivity: { controller, activity in
            XCTAssertTrue(controller === host)
            presented = activity
        })
        XCTAssertThrowsError(try presenter.share(data: Data(), filename: "test.pdf"))
        presenter.updateAnchor()
        presenter.anchor = anchor
        let bytes = Data("PDF bytes".utf8)
        try presenter.share(data: bytes, filename: "test.pdf")
        let activity = try XCTUnwrap(presenter.activityController)
        let url = try XCTUnwrap(presenter.sharedURL)
        XCTAssertTrue(presented === activity)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(activity.popoverPresentationController?.sourceView === anchor)
        anchor.bounds.size = CGSize(width: 50, height: 46)
        presenter.updateAnchor()
        XCTAssertEqual(activity.popoverPresentationController?.sourceRect, anchor.bounds)
        XCTAssertThrowsError(try presenter.share(data: bytes, filename: "test.pdf"))
        XCTAssertThrowsError(try presenter.printPDF(data: bytes, filename: "test.pdf", onError: { _ in }))
        activity.completionWithItemsHandler?(nil, true, nil, nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(presenter.activityController)
        presenter.finishSharing()
        try presenter.share(data: bytes, filename: "test.pdf")
        let secondURL = try XCTUnwrap(presenter.sharedURL)
        presenter.presentationControllerDidDismiss(UIPresentationController(presentedViewController: activity, presenting: host))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertNotNil(MobilePDFPresentationError.unavailable.errorDescription)
    }

    func testPrintUsesIdenticalPDFBytesAndReleasesOwnershipOnCompletionFailureOrRejection() throws {
        let host = UIViewController()
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let anchor = UIView(frame: CGRect(x: 20, y: 20, width: 44, height: 44))
        host.view.addSubview(anchor)
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Print fixture" as NSString).draw(at: CGPoint(x: 54, y: 54), withAttributes: nil)
        }
        var completion: ((UIPrintInteractionController, Bool, Error?) -> Void)?
        var printController: UIPrintInteractionController?
        var accepts = true
        let presenter = MobilePDFPresentationController(presentPrint: { controller, suppliedData, source, callback in
            XCTAssertEqual(suppliedData, bytes)
            XCTAssertEqual(controller.printInfo?.jobName, "test.pdf")
            XCTAssertTrue(source === anchor)
            printController = controller
            completion = callback
            return accepts
        })
        presenter.anchor = anchor
        var error: String?
        try presenter.printPDF(data: bytes, filename: "test.pdf") { error = $0 }
        XCTAssertThrowsError(try presenter.printPDF(data: bytes, filename: "test.pdf", onError: { _ in }))
        completion?(try XCTUnwrap(printController), false, nil)
        XCTAssertNil(error)
        XCTAssertNil(printController?.printingItem)
        try presenter.printPDF(data: bytes, filename: "test.pdf") { error = $0 }
        completion?(try XCTUnwrap(printController), false, CocoaError(.fileReadUnknown))
        XCTAssertNotNil(error)
        accepts = false
        XCTAssertThrowsError(try presenter.printPDF(data: bytes, filename: "test.pdf", onError: { _ in }))
        XCTAssertNil(printController?.printingItem)
    }

    func testNativeFindFieldReportsEditingSubmissionAndEscape() throws {
        let field = MobileFindTextField()
        var query = ""
        var focused = false
        var submits = 0
        var prints = 0
        var previous = 0
        field.onTextChange = { query = $0 }
        field.onFocusChange = { focused = $0 }
        field.onSearch = { submits += 1 }
        field.onPrint = { prints += 1 }
        field.onPreviousSearch = { previous += 1 }
        field.text = "needle"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(query, "needle")
        field.text = nil
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(query, "")
        field.textFieldDidBeginEditing(field)
        XCTAssertTrue(focused)
        XCTAssertFalse(field.textFieldShouldReturn(field))
        XCTAssertEqual(submits, 1)
        field.printContent(nil)
        XCTAssertEqual(prints, 1)
        field.find(nil)
        XCTAssertTrue(focused)
        field.findNext(nil)
        field.findPrevious(nil)
        XCTAssertEqual(submits, 2)
        XCTAssertEqual(previous, 1)
        XCTAssertTrue(field.canPerformAction(#selector(UIResponder.printContent(_:)), withSender: nil))
        XCTAssertTrue(field.canPerformAction(#selector(MobileFindTextField.cancelFind(_:)), withSender: nil))
        _ = field.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil)
        let escape = try XCTUnwrap(field.keyCommands?.first)
        XCTAssertEqual(escape.input, UIKeyCommand.inputEscape)
        XCTAssertTrue(escape.wantsPriorityOverSystemBehavior)
        field.cancelFind()
        XCTAssertFalse(focused)
        field.textFieldDidEndEditing(field)
        XCTAssertFalse(focused)
        XCTAssertTrue(field.adjustsFontForContentSizeCategory)
        XCTAssertEqual(field.autocorrectionType, .no)
    }

    func testAtomicSceneStorageIsIndependentAndClosingRemovesOnlyThatScene() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileWindowRestorationStore(directory: directory)
        XCTAssertNil(store.load(sessionID: "one"))
        var firstState = MobileWindowRestoration()
        firstState.documents = [MobileDocumentBookmark(url: first)]
        var reader = MobileReaderRestoration()
        reader.query = "restored search"
        firstState.readers[MobileDocumentIdentity.key(for: first)] = reader
        var secondState = MobileWindowRestoration()
        secondState.documents = [MobileDocumentBookmark(url: second)]
        try store.save(firstState, sessionID: "one")
        try store.save(secondState, sessionID: "two")
        XCTAssertEqual(store.load(sessionID: "one"), firstState)
        XCTAssertEqual(store.load(sessionID: "two"), secondState)
        store.discard(sessionID: "one")
        store.discard(sessionID: "one")
        XCTAssertNil(store.load(sessionID: "one"))
        XCTAssertEqual(store.load(sessionID: "two"), secondState)
        try Data("corrupt".utf8).write(to: store.fileURL(for: "two"))
        XCTAssertNil(store.load(sessionID: "two"))
        XCTAssertEqual(store.fileURL(for: "../../outside").deletingLastPathComponent().path, directory.path)
        let blocked = directory.appendingPathComponent("file")
        try Data().write(to: blocked)
        XCTAssertThrowsError(try MobileWindowRestorationStore(directory: blocked).save(firstState, sessionID: "three"))
    }

    func testCancellingOneWindowLeavesOtherPDFWorkAndContentsIntact() async throws {
        let first = MobileDocumentSession(document: MarkdownDocument(title: "One", markdown: "First"), pdfProvider: { _ in
            try await Task.sleep(for: .seconds(10))
            return Data()
        })
        let second = MobileDocumentSession(document: MarkdownDocument(title: "Two", markdown: "Second"), pdfProvider: { _ in Data("second PDF".utf8) })
        let pending = Task { try await first.pdfData() }
        await Task.yield()
        first.cancelPDFGeneration()
        do { _ = try await pending.value; XCTFail("The closed window must cancel its own work") }
        catch { XCTAssertTrue(error is CancellationError) }
        let data = try await second.pdfData()
        XCTAssertEqual(data, Data("second PDF".utf8))
        XCTAssertEqual(second.title, "Two")
        XCTAssertEqual(second.pdfState, .ready)
    }

    func testNativeDocumentResponderRoutesCommandsToItsOwnWindow() throws {
        let first = MobileDocumentKeyView()
        let second = MobileDocumentKeyView()
        var firstCommands: [String] = []
        var secondCommands: [String] = []
        first.onCommand = { firstCommands.append($0) }
        second.onCommand = { secondCommands.append($0) }
        for command in try XCTUnwrap(first.keyCommands) { first.performDocumentCommand(command) }
        XCTAssertEqual(firstCommands, ["f", "g", "previous", "s", "p"])
        XCTAssertTrue(secondCommands.isEmpty)
        XCTAssertTrue(first.canBecomeFirstResponder)
        XCTAssertTrue(first.canPerformAction(#selector(UIResponder.printContent(_:)), withSender: nil))
        first.find(nil)
        first.findNext(nil)
        first.findPrevious(nil)
        XCTAssertEqual(Array(firstCommands.suffix(3)), ["f", "g", "previous"])
        first.printContent(nil)
        second.printContent(nil)
        XCTAssertEqual(firstCommands.last, "p")
        XCTAssertEqual(secondCommands, ["p"])
        XCTAssertFalse(first.canPerformAction(#selector(UIResponder.cut(_:)), withSender: nil))
        first.didMoveToWindow()
        first.activateIfNeeded()
        let container = UIView()
        container.addSubview(first)
        XCTAssertFalse(MobileDocumentKeyView.containsTextInputResponder(container))
    }

    func testActivityPayloadAndShareFileNameAreCorrect() throws {
        let data = Data("pdf".utf8)
        XCTAssertThrowsError(try MobilePDFShareStore.write(data: data, filename: "/"))
        let url = try MobilePDFShareStore.write(data: data, filename: "../report.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.lastPathComponent, "report.pdf")
        let item = MobilePDFActivityItem(data: data, fileURL: url)
        let activity = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewControllerPlaceholderItem(activity) as? URL, url)
        XCTAssertEqual(item.activityViewController(activity, itemForActivityType: .print) as? Data, data)
        XCTAssertEqual(item.activityViewController(activity, itemForActivityType: .copyToPasteboard) as? URL, url)
        XCTAssertEqual(item.activityViewController(activity, dataTypeIdentifierForActivityType: nil), "com.adobe.pdf")
    }
}

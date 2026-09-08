import XCTest
import SwiftUI
import MarkdownPrinterCore
import UniformTypeIdentifiers
import UIKit
@testable import MarkdownPrinterIOS

final class MobileMarkdownFileDocumentTests: XCTestCase {
    func testDocumentDecodesDataAndUsesSourceFilenameAndHeading() throws {
        let data = Data("# Visible Heading\n\nBody".utf8)
        let file = try MobileMarkdownFileDocument(data: data)
        let sourceURL = URL(fileURLWithPath: "/tmp/Filename.mdown")

        let document = file.markdownDocument(sourceURL: sourceURL)

        XCTAssertEqual(document.title, "Visible Heading")
        XCTAssertEqual(document.sourceURL, sourceURL)
        XCTAssertEqual(document.markdown, "# Visible Heading\n\nBody")
        XCTAssertEqual(MobileMarkdownFileDocument.readableContentTypes.count, 1)
        XCTAssertEqual(
            MobileMarkdownFileDocument.markdownContentType.identifier,
            "net.daringfireball.markdown"
        )
    }

    func testDocumentWithoutHeadingUsesFilenameAndRejectsInvalidEncoding() throws {
        let file = try MobileMarkdownFileDocument(data: Data("Plain text".utf8))
        XCTAssertEqual(
            file.markdownDocument(sourceURL: URL(fileURLWithPath: "/tmp/Read Me.mkd")).title,
            "Read Me"
        )
        XCTAssertThrowsError(try MobileMarkdownFileDocument(data: Data([0x80, 0x81])))
    }

    @MainActor
    func testIncomingDocumentQueueProcessesEveryReceivedURLInOrder() throws {
        let queue = MobileIncomingDocumentQueue()
        let firstURL = URL(fileURLWithPath: "/tmp/First.md")
        let secondURL = URL(fileURLWithPath: "/tmp/Second.markdown")

        queue.receive(firstURL)
        let first = queue.current
        queue.receive(secondURL)

        XCTAssertEqual(first?.url, firstURL)
        XCTAssertEqual(queue.current, first)

        queue.complete(UUID())
        XCTAssertEqual(queue.current, first)

        queue.complete(try XCTUnwrap(first?.id))
        XCTAssertEqual(queue.current?.url, secondURL)

        queue.complete(try XCTUnwrap(queue.current?.id))
        XCTAssertNil(queue.current)
    }

    @MainActor
    func testIncomingDocumentIsImportedRevealedPresentedAndHandledOnce() {
        let incomingURL = URL(fileURLWithPath: "/tmp/ChatGPT Export.md")
        let revealedURL = URL(fileURLWithPath: "/tmp/Markdown Printer/ChatGPT Export.md")
        let document = MobileIncomingDocument(url: incomingURL)
        let browser = UIDocumentBrowserViewController(
            forOpening: [MobileMarkdownFileDocument.markdownContentType]
        )
        var revealCount = 0
        var didRequestImport = false
        var presentedURL: URL?
        var handledIDs: [UUID] = []
        var browserIsVisible = false
        var browserAppearanceCount = 0
        let coordinator = MarkdownDocumentBrowser.Coordinator(
            revealDocument: { _, url, importIfNeeded, completion in
                revealCount += 1
                XCTAssertEqual(url, incomingURL)
                didRequestImport = importIfNeeded
                completion(revealedURL, nil)
            },
            presentRevealedDocument: { url, _ in
                presentedURL = url
            },
            isReadyToReveal: { _ in browserIsVisible }
        )
        coordinator.onBrowserDidAppear = {
            browserAppearanceCount += 1
        }

        coordinator.openIncomingDocumentIfNeeded(document, from: browser) {
            handledIDs.append($0)
        }
        XCTAssertEqual(revealCount, 0)
        XCTAssertNil(presentedURL)

        browserIsVisible = true
        coordinator.documentBrowserDidAppear(browser)
        coordinator.openIncomingDocumentIfNeeded(document, from: browser) {
            handledIDs.append($0)
        }

        XCTAssertEqual(revealCount, 1)
        XCTAssertEqual(browserAppearanceCount, 1)
        XCTAssertTrue(didRequestImport)
        XCTAssertEqual(presentedURL, revealedURL)
        XCTAssertEqual(handledIDs, [document.id])
    }

    @MainActor
    func testIncomingDocumentRevealFailureFallsBackToReceivedURLAndQueueCanAdvance() {
        let incomingURL = URL(fileURLWithPath: "/tmp/Provider Export.md")
        let document = MobileIncomingDocument(url: incomingURL)
        let browser = UIDocumentBrowserViewController(
            forOpening: [MobileMarkdownFileDocument.markdownContentType]
        )
        let expectedError = CocoaError(.fileNoSuchFile)
        var presentedURL: URL?
        var handledID: UUID?
        let coordinator = MarkdownDocumentBrowser.Coordinator(
            revealDocument: { _, _, _, completion in
                completion(nil, expectedError)
            },
            presentRevealedDocument: { url, _ in
                presentedURL = url
            },
            isReadyToReveal: { _ in true }
        )

        coordinator.openIncomingDocumentIfNeeded(document, from: browser) {
            handledID = $0
        }

        XCTAssertEqual(presentedURL, incomingURL)
        XCTAssertEqual(handledID, document.id)
    }

    @MainActor
    func testIncomingDocumentDismissesOpenViewerBeforeRevealingReplacement() {
        let incomingURL = URL(fileURLWithPath: "/tmp/Replacement.md")
        let revealedURL = URL(fileURLWithPath: "/tmp/Imported/Replacement.md")
        let document = MobileIncomingDocument(url: incomingURL)
        let browser = UIDocumentBrowserViewController(
            forOpening: [MobileMarkdownFileDocument.markdownContentType]
        )
        var hasOpenViewer = true
        var dismissCount = 0
        var revealedCount = 0
        var presentedURL: URL?
        let coordinator = MarkdownDocumentBrowser.Coordinator(
            revealDocument: { _, url, importIfNeeded, completion in
                XCTAssertEqual(url, incomingURL)
                XCTAssertTrue(importIfNeeded)
                revealedCount += 1
                completion(revealedURL, nil)
            },
            presentRevealedDocument: { url, _ in
                presentedURL = url
            },
            isReadyToReveal: { _ in true },
            hasPresentedContent: { _ in hasOpenViewer },
            dismissPresentedContent: { _, completion in
                dismissCount += 1
                hasOpenViewer = false
                completion()
            }
        )

        coordinator.openIncomingDocumentIfNeeded(document, from: browser) { _ in }

        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(revealedCount, 1)
        XCTAssertEqual(presentedURL, revealedURL)
    }

    func testShareStoreWritesNamedTemporaryPDF() throws {
        let data = Data("%PDF-test".utf8)
        let url = try MobilePDFShareStore.write(data: data, filename: "Shared.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertEqual(url.lastPathComponent, "Shared.pdf")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testAppInformationUsesPublicHTTPSDestinations() {
        XCTAssertEqual(MarkdownPrinterAppInformation.privacyPolicyURL.scheme, "https")
        XCTAssertEqual(MarkdownPrinterAppInformation.supportURL.scheme, "https")
        XCTAssertEqual(MarkdownPrinterAppInformation.sourceURL.host, "github.com")
        XCTAssertTrue(
            MarkdownPrinterAppInformation.privacyPolicyURL.path.hasSuffix("docs/privacy-policy.md")
        )
        XCTAssertTrue(
            MarkdownPrinterAppInformation.supportURL.path.hasSuffix("docs/ios-support.md")
        )
    }

    func testPDFActivityItemRoutesBytesToPrintAndFileURLToOtherDestinations() {
        let data = Data("%PDF-test".utf8)
        let url = URL(fileURLWithPath: "/tmp/Shared.pdf")
        let item = MobilePDFActivityItem(data: data, fileURL: url)

        XCTAssertEqual(item.placeholderItem as? URL, url)
        XCTAssertEqual(item.item(for: .print) as? Data, data)
        XCTAssertEqual(item.item(for: .mail) as? URL, url)
        XCTAssertEqual(item.dataTypeIdentifier, UTType.pdf.identifier)
    }
}

import XCTest
import UIKit
import MarkdownPrinterCore
@testable import MarkdownPrinterMobileSupport

final class MobileDocumentAccessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileDocumentAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testSecurityScopedLeaseStopsOnlyWhenAccessStarted() {
        var stopCount = 0
        autoreleasepool {
            _ = SecurityScopedResourceLease(
                url: directory,
                startAccessing: { true },
                stopAccessing: { stopCount += 1 }
            )
        }
        XCTAssertEqual(stopCount, 1)

        autoreleasepool {
            _ = SecurityScopedResourceLease(
                url: directory,
                startAccessing: { false },
                stopAccessing: { stopCount += 1 }
            )
        }
        XCTAssertEqual(stopCount, 1)
    }

    func testLoaderDecodesUTF8AndUTF16AndMapsEncodingFailure() async throws {
        let utf8URL = directory.appendingPathComponent("utf8.md")
        try Data("# UTF-8 ✓".utf8).write(to: utf8URL)
        let utf8 = try await MobileDocumentLoader().load(at: utf8URL)
        XCTAssertEqual(utf8.title, "UTF-8 ✓")
        XCTAssertEqual(utf8.sourceURL, utf8URL)

        let utf16URL = directory.appendingPathComponent("utf16.markdown")
        let utf16 = try XCTUnwrap("# UTF-16".data(using: .utf16))
        try utf16.write(to: utf16URL)
        let utf16Document = try await MobileDocumentLoader().load(at: utf16URL)
        XCTAssertEqual(utf16Document.title, "UTF-16")

        let invalidURL = directory.appendingPathComponent("invalid.md")
        try Data([0x80, 0x81, 0x82]).write(to: invalidURL)
        do {
            _ = try await MobileDocumentLoader().load(at: invalidURL)
            XCTFail("Expected unsupported encoding")
        } catch {
            XCTAssertEqual(error as? MobileDocumentAccessError, .unsupportedTextEncoding)
        }
    }

    func testMissingLoaderInputReportsUnreadableDocument() async {
        do {
            _ = try await MobileDocumentLoader().load(at: directory.appendingPathComponent("missing.md"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testReadPermissionFailuresRequestTheSpecificLinkedFile() {
        let requestedURL = directory.appendingPathComponent("Linked Notes.md")
        XCTAssertEqual(
            MobileDocumentAccessError.readingFailure(
                for: CocoaError(.fileReadNoPermission),
                at: requestedURL
            ),
            .permissionRequired("Linked Notes.md")
        )

        let providerError = NSError(
            domain: "FileProviderTest",
            code: 41,
            userInfo: [NSUnderlyingErrorKey: CocoaError(.fileReadNoPermission)]
        )
        XCTAssertEqual(
            MobileDocumentAccessError.readingFailure(for: providerError, at: requestedURL),
            .permissionRequired("Linked Notes.md")
        )
        XCTAssertEqual(
            MobileDocumentAccessError.readingFailure(
                for: CocoaError(.fileReadNoSuchFile),
                at: requestedURL
            ),
            .unreadableDocument
        )
    }

    func testLinkedDocumentSelectionRequiresTheExpectedFilename() {
        let requestedURL = directory.appendingPathComponent("Research Map.md")
        XCTAssertTrue(
            MobileLinkedDocumentSelection.accepts(
                URL(fileURLWithPath: "/provider/RESEARCH MAP.MD"),
                for: requestedURL
            )
        )
        XCTAssertFalse(
            MobileLinkedDocumentSelection.accepts(
                URL(fileURLWithPath: "/provider/Different.md"),
                for: requestedURL
            )
        )
        XCTAssertEqual(
            MobileLinkedDocumentSelection.rejectionMessage(for: requestedURL),
            "Choose “Research Map.md” to follow this link."
        )
        XCTAssertEqual(
            MobileDocumentPermissionRequest(url: requestedURL).filename,
            "Research Map.md"
        )
    }

    func testFileActionsMetadataRenameAndDuplicate() throws {
        let source = directory.appendingPathComponent("Notes.md")
        let contents = Data("# Notes".utf8)
        try contents.write(to: source)

        let actions = MobileFileActionAvailability.resolve(for: source)
        XCTAssertTrue(actions.canRename)
        XCTAssertTrue(actions.canMove)
        XCTAssertTrue(actions.canDuplicate)
        XCTAssertNil(actions.unavailableReason)

        let metadata = try XCTUnwrap(MobileDocumentMetadata.load(from: source))
        XCTAssertEqual(metadata.filename, "Notes.md")
        XCTAssertEqual(metadata.kind, "Markdown Document")
        XCTAssertEqual(metadata.byteSize, contents.count)
        XCTAssertNotNil(metadata.locationName)

        let duplicate = try MobileFileOperator().duplicate(source)
        XCTAssertEqual(duplicate.lastPathComponent, "Notes copy.md")
        XCTAssertEqual(try Data(contentsOf: duplicate), contents)
        let secondDuplicate = try MobileFileOperator().duplicate(source)
        XCTAssertEqual(secondDuplicate.lastPathComponent, "Notes copy 2.md")

        let renamed = try MobileFileOperator().rename(source, to: "Renamed")
        XCTAssertEqual(renamed.lastPathComponent, "Renamed.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: renamed), contents)
        XCTAssertEqual(try MobileFileOperator().rename(renamed, to: "Renamed.md"), renamed)
    }

    func testFileActionUnavailableStatesAndInvalidNames() {
        let noLocation = MobileFileActionAvailability.resolve(for: nil)
        XCTAssertFalse(noLocation.canRename)
        XCTAssertFalse(noLocation.canMove)
        XCTAssertFalse(noLocation.canDuplicate)
        XCTAssertEqual(noLocation.unavailableReason, "This document doesn’t have a file location.")

        let directoryActions = MobileFileActionAvailability.resolve(for: directory)
        XCTAssertFalse(directoryActions.canRename)
        XCTAssertFalse(directoryActions.canMove)
        XCTAssertFalse(directoryActions.canDuplicate)

        let source = directory.appendingPathComponent("file.md")
        XCTAssertThrowsError(try MobileFileOperator().rename(source, to: "   "))
        XCTAssertThrowsError(try MobileFileOperator().rename(source, to: "bad/name"))
    }

    func testFileOperationsMapProviderFailuresToReadableErrors() {
        let missing = directory.appendingPathComponent("missing.md")
        XCTAssertThrowsError(try MobileFileOperator().duplicate(missing)) { error in
            guard case .fileOperationFailed = error as? MobileDocumentAccessError else {
                return XCTFail("Expected a mapped duplicate failure, got \(error)")
            }
        }
        XCTAssertThrowsError(try MobileFileOperator().rename(missing, to: "renamed.md")) { error in
            guard case .fileOperationFailed = error as? MobileDocumentAccessError else {
                return XCTFail("Expected a mapped rename failure, got \(error)")
            }
        }
    }

    func testImageResolverNeverFetchesRemoteContentAndClassifiesLocalFailures() throws {
        let resolver = MobileImageResolver()
        XCTAssertEqual(
            resolver.resolve(source: "https://example.com/image.png", relativeTo: directory),
            .placeholder(.remote)
        )
        XCTAssertEqual(
            resolver.resolve(source: "data:image/png;base64,AAAA", relativeTo: directory),
            .placeholder(.remote)
        )
        XCTAssertEqual(
            resolver.resolve(source: "missing.png", relativeTo: directory),
            .placeholder(.missing)
        )
        XCTAssertEqual(
            resolver.resolve(source: "relative.png", relativeTo: nil),
            .placeholder(.missing)
        )

        let corruptURL = directory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corruptURL)
        XCTAssertEqual(
            resolver.resolve(source: "corrupt.png", relativeTo: directory),
            .placeholder(.corrupt)
        )

        let inaccessibleURL = directory.appendingPathComponent("inaccessible.png", isDirectory: true)
        try FileManager.default.createDirectory(at: inaccessibleURL, withIntermediateDirectories: false)
        XCTAssertEqual(
            resolver.resolve(source: "inaccessible.png", relativeTo: directory),
            .placeholder(.inaccessible)
        )

        let validURL = directory.appendingPathComponent("valid.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 8)).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        }
        try XCTUnwrap(image.pngData()).write(to: validURL)
        XCTAssertEqual(
            resolver.resolve(source: validURL.absoluteString, relativeTo: nil),
            .local(validURL)
        )
    }

    func testErrorsHaveReadableMessages() {
        XCTAssertNotNil(MobileDocumentAccessError.unreadableDocument.errorDescription)
        XCTAssertNotNil(MobileDocumentAccessError.unsupportedTextEncoding.errorDescription)
        XCTAssertEqual(
            MobileDocumentAccessError.permissionRequired("Linked.md").errorDescription,
            "Choose “Linked.md” in Files to give Markdown Printer permission to open it."
        )
        XCTAssertNotNil(MobileDocumentAccessError.invalidFilename.errorDescription)
        XCTAssertEqual(
            MobileDocumentAccessError.fileOperationFailed("Provider denied the request").errorDescription,
            "Provider denied the request"
        )
        XCTAssertEqual(MobileImagePlaceholderReason.remote.message, "Remote image not loaded")
        XCTAssertEqual(MobileImagePlaceholderReason.missing.message, "Image not found")
        XCTAssertEqual(MobileImagePlaceholderReason.corrupt.message, "Image could not be displayed")
        XCTAssertEqual(MobileImagePlaceholderReason.inaccessible.message, "Image unavailable from this file provider")
    }
}

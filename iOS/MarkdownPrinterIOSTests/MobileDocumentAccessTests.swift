import XCTest
import UIKit
import MarkdownPrinterCore
@testable import MarkdownPrinterMobileSupport

private final class SaveTrackingFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    private let lock = NSLock()
    private let onSave: () -> Void
    private var saveRequestCountStorage = 0

    init(url: URL, onSave: @escaping () -> Void) {
        presentedItemURL = url
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        self.onSave = onSave
    }

    var saveRequestCount: Int {
        lock.withLock { saveRequestCountStorage }
    }

    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        lock.withLock { saveRequestCountStorage += 1 }
        onSave()
        completionHandler(nil)
    }
}

@MainActor
final class MobileDocumentAccessTests: XCTestCase {
    private enum TestError: Error {
        case failed
    }

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

    func testCloudBrowserStatusesUseHonestMessagesAndPresentation() {
        let checked = MobileCloudBrowserStatus.checked(Date(timeIntervalSinceReferenceDate: 0))

        XCTAssertEqual(MobileCloudBrowserStatus.checking.message, "Checking iCloud…")
        XCTAssertTrue(checked.message.hasPrefix("Checked for updates at "))
        XCTAssertEqual(
            MobileCloudBrowserStatus.slow.message,
            "iCloud is taking longer than usual — showing available files"
        )
        XCTAssertEqual(
            MobileCloudBrowserStatus.offline.message,
            "Offline — showing available files"
        )
        XCTAssertEqual(
            MobileCloudBrowserStatus.failed.message,
            "Couldn’t check iCloud — showing available files"
        )
        XCTAssertEqual(MobileCloudBrowserStatus.unavailable.message, "iCloud Drive unavailable")

        XCTAssertEqual(MobileCloudBrowserStatus.checking.systemImageName, "icloud")
        XCTAssertEqual(MobileCloudBrowserStatus.slow.systemImageName, "icloud")
        XCTAssertEqual(checked.systemImageName, "checkmark.icloud")
        XCTAssertEqual(MobileCloudBrowserStatus.offline.systemImageName, "wifi.slash")
        XCTAssertEqual(MobileCloudBrowserStatus.failed.systemImageName, "exclamationmark.icloud")
        XCTAssertEqual(MobileCloudBrowserStatus.unavailable.systemImageName, "icloud.slash")
        XCTAssertTrue(MobileCloudBrowserStatus.checking.showsProgress)
        XCTAssertTrue(MobileCloudBrowserStatus.slow.showsProgress)
        XCTAssertFalse(checked.showsProgress)
        XCTAssertFalse(MobileCloudBrowserStatus.offline.showsProgress)
        XCTAssertFalse(MobileCloudBrowserStatus.failed.showsProgress)
        XCTAssertFalse(MobileCloudBrowserStatus.unavailable.showsProgress)
        XCTAssertTrue(MobileCloudBrowserStatus.failed.offersRetry)
        XCTAssertFalse(MobileCloudBrowserStatus.checking.offersRetry)
        XCTAssertFalse(checked.offersRetry)
        XCTAssertFalse(MobileCloudBrowserStatus.slow.offersRetry)
        XCTAssertFalse(MobileCloudBrowserStatus.offline.offersRetry)
        XCTAssertFalse(MobileCloudBrowserStatus.unavailable.offersRetry)
    }

    func testCloudBrowserStatusStateMachineTracksFreshnessAndIgnoresStaleChecks() throws {
        let checkedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = MobileCloudBrowserStatusStateMachine()

        XCTAssertTrue(state.needsRefresh(at: checkedAt, freshnessInterval: 300))
        let firstCheck = try XCTUnwrap(
            state.beginCheck(networkAvailable: nil, iCloudAvailable: true)
        )
        XCTAssertEqual(state.status, .checking)
        XCTAssertFalse(state.needsRefresh(at: checkedAt, freshnessInterval: 300))

        state.markSlow(for: firstCheck + 1)
        XCTAssertEqual(state.status, .checking)
        state.markSlow(for: firstCheck)
        XCTAssertEqual(state.status, .slow)

        state.complete(firstCheck + 1, at: checkedAt)
        XCTAssertEqual(state.status, .slow)
        state.complete(firstCheck, at: checkedAt)
        XCTAssertEqual(state.status, .checked(checkedAt))
        XCTAssertFalse(
            state.needsRefresh(
                at: checkedAt.addingTimeInterval(299),
                freshnessInterval: 300
            )
        )
        XCTAssertTrue(
            state.needsRefresh(
                at: checkedAt.addingTimeInterval(300),
                freshnessInterval: 300
            )
        )

        let secondCheck = try XCTUnwrap(
            state.beginCheck(networkAvailable: true, iCloudAvailable: true)
        )
        state.fail(firstCheck)
        XCTAssertEqual(state.status, .checking)
        state.fail(secondCheck)
        XCTAssertEqual(state.status, .failed)
        XCTAssertTrue(state.needsRefresh(at: checkedAt, freshnessInterval: 300))
    }

    func testCloudBrowserStatusStateMachineReportsOfflineAndUnavailable() {
        var state = MobileCloudBrowserStatusStateMachine(status: .failed)

        XCTAssertNil(state.beginCheck(networkAvailable: false, iCloudAvailable: true))
        XCTAssertEqual(state.status, .offline)
        XCTAssertTrue(state.needsRefresh(at: Date(), freshnessInterval: 300))

        XCTAssertNil(state.beginCheck(networkAvailable: true, iCloudAvailable: false))
        XCTAssertEqual(state.status, .unavailable)
        XCTAssertTrue(state.needsRefresh(at: Date(), freshnessInterval: 300))

        _ = state.beginCheck(networkAvailable: true, iCloudAvailable: true)
        state.setOffline()
        XCTAssertEqual(state.status, .offline)
        _ = state.beginCheck(networkAvailable: true, iCloudAvailable: true)
        state.setUnavailable()
        XCTAssertEqual(state.status, .unavailable)
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

    func testLoaderReadDoesNotRequestPresenterSaveOrChangeSourceDates() async throws {
        let sourceURL = directory.appendingPathComponent("read-only.md")
        let originalData = Data("# Read Only\n\nOriginal bytes.".utf8)
        try originalData.write(to: sourceURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: sourceURL.path
        )
        let before = try sourceURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )
        XCTAssertNotNil(before.creationDate)
        XCTAssertNotNil(before.contentModificationDate)

        let presenter = SaveTrackingFilePresenter(url: sourceURL) {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: sourceURL.path
            )
        }
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        let document = try await MobileDocumentLoader().load(at: sourceURL)
        var refreshedSourceURL = sourceURL
        refreshedSourceURL.removeAllCachedResourceValues()
        let after = try refreshedSourceURL.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey]
        )

        XCTAssertEqual(document.markdown, String(decoding: originalData, as: UTF8.self))
        XCTAssertEqual(document.sourceModificationDate, before.contentModificationDate)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
        XCTAssertEqual(presenter.saveRequestCount, 0)
        XCTAssertEqual(after.creationDate, before.creationDate)
        XCTAssertEqual(after.contentModificationDate, before.contentModificationDate)
    }

    func testCancellingLoaderPropagatesToTheFileReadTask() async throws {
        let started = expectation(description: "File read started")
        let releaseRead = DispatchSemaphore(value: 0)
        let loader = MobileDocumentLoader { _ in
            started.fulfill()
            releaseRead.wait()
            return Data("# Should not open".utf8)
        }
        let task = Task {
            try await loader.load(at: URL(fileURLWithPath: "/provider/Waiting.md"))
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        releaseRead.signal()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
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

    func testDirectoryAuthorizationRequiresAContainingFolder() {
        let requestedURL = directory.appendingPathComponent("Research Map.md")
        let parent = requestedURL.deletingLastPathComponent()
        XCTAssertTrue(MobileDirectoryAuthorization.contains(requestedURL, within: parent))
        XCTAssertTrue(
            MobileDirectoryAuthorization.contains(
                requestedURL,
                within: parent.deletingLastPathComponent()
            )
        )
        XCTAssertFalse(
            MobileDirectoryAuthorization.contains(
                requestedURL,
                within: parent.appendingPathComponent("Research")
            )
        )
        XCTAssertFalse(MobileDirectoryAuthorization.contains(parent, within: parent))

        let request = MobileDocumentPermissionRequest(url: requestedURL)
        XCTAssertEqual(request.filename, "Research Map.md")
        XCTAssertEqual(request.directoryURL, parent)
    }

    func testDirectoryAccessStorePersistsScopeAndReplacesAnExplicitRegrant() throws {
        let defaults = makeDefaults()
        let key = "authorized-folders"
        let bookmark = Data("directory-bookmark".utf8)
        var startCount = 0
        var stopCount = 0
        var store: MobileDirectoryAccessStore? = MobileDirectoryAccessStore(
            defaults: defaults,
            bookmarkKey: key,
            bookmarkCreator: { _ in bookmark },
            bookmarkResolver: { _ in throw TestError.failed },
            leaseFactory: { url in
                SecurityScopedResourceLease(
                    url: url,
                    startAccessing: {
                        startCount += 1
                        return true
                    },
                    stopAccessing: { stopCount += 1 }
                )
            },
            isReadableDirectory: { _ in false }
        )

        try store?.authorize(directoryURL: directory)
        try store?.authorize(directoryURL: directory)
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(
            store?.hasAccess(to: directory.appendingPathComponent("Nested/Notes.md")) == true
        )
        XCTAssertFalse(
            store?.hasAccess(
                to: directory.deletingLastPathComponent().appendingPathComponent("Elsewhere.md")
            ) == true
        )
        XCTAssertEqual(defaults.array(forKey: key) as? [Data], [bookmark])

        store = nil
        XCTAssertEqual(stopCount, 2)
    }

    func testDirectoryAccessStoreRestoresAndRefreshesAStaleBookmark() {
        let defaults = makeDefaults()
        let key = "authorized-folders"
        let original = Data("old-bookmark".utf8)
        let refreshed = Data("new-bookmark".utf8)
        defaults.set([original], forKey: key)
        var scopeAvailable = false
        var resolutionCount = 0
        let store = MobileDirectoryAccessStore(
            defaults: defaults,
            bookmarkKey: key,
            bookmarkCreator: { _ in refreshed },
            bookmarkResolver: { data in
                XCTAssertEqual(data, original)
                resolutionCount += 1
                return (self.directory, true)
            },
            leaseFactory: { url in
                SecurityScopedResourceLease(
                    url: url,
                    startAccessing: { scopeAvailable },
                    stopAccessing: {}
                )
            },
            isReadableDirectory: { _ in false }
        )

        XCTAssertFalse(store.hasAccess(to: directory.appendingPathComponent("Linked.md")))
        scopeAvailable = true
        XCTAssertTrue(store.activateStoredAccess(containing: directory.appendingPathComponent("Linked.md")))
        XCTAssertTrue(store.activateStoredAccess(containing: directory.appendingPathComponent("Other.md")))
        XCTAssertEqual(resolutionCount, 2)
        XCTAssertEqual(defaults.array(forKey: key) as? [Data], [refreshed])
    }

    func testDirectoryAccessStoreMapsGrantFailures() {
        let defaults = makeDefaults()
        let denied = MobileDirectoryAccessStore(
            defaults: defaults,
            bookmarkKey: "denied",
            bookmarkCreator: { _ in Data() },
            bookmarkResolver: { _ in throw TestError.failed },
            leaseFactory: { url in
                SecurityScopedResourceLease(
                    url: url,
                    startAccessing: { false },
                    stopAccessing: {}
                )
            },
            isReadableDirectory: { _ in false }
        )
        XCTAssertThrowsError(try denied.authorize(directoryURL: directory)) { error in
            XCTAssertEqual(error as? MobileDirectoryAccessError, .accessDenied)
        }

        let bookmarkFailure = MobileDirectoryAccessStore(
            defaults: defaults,
            bookmarkKey: "bookmark-failure",
            bookmarkCreator: { _ in throw TestError.failed },
            bookmarkResolver: { _ in throw TestError.failed },
            leaseFactory: { url in
                SecurityScopedResourceLease(
                    url: url,
                    startAccessing: { true },
                    stopAccessing: {}
                )
            },
            isReadableDirectory: { _ in false }
        )
        XCTAssertThrowsError(try bookmarkFailure.authorize(directoryURL: directory)) { error in
            XCTAssertEqual(error as? MobileDirectoryAccessError, .bookmarkFailed)
        }
    }

    func testBackSwipePolicySupportsBothScreenEdgesWithoutTakingVerticalSwipes() {
        XCTAssertTrue(
            MobileBackSwipePolicy.shouldNavigateBack(
                from: .leading,
                horizontalTravel: 90,
                verticalTravel: 12
            )
        )
        XCTAssertTrue(
            MobileBackSwipePolicy.shouldNavigateBack(
                from: .trailing,
                horizontalTravel: -90,
                verticalTravel: 12
            )
        )
        XCTAssertFalse(
            MobileBackSwipePolicy.shouldNavigateBack(
                from: .leading,
                horizontalTravel: -90,
                verticalTravel: 12
            )
        )
        XCTAssertFalse(
            MobileBackSwipePolicy.shouldNavigateBack(
                from: .trailing,
                horizontalTravel: 90,
                verticalTravel: 12
            )
        )
        XCTAssertFalse(
            MobileBackSwipePolicy.shouldNavigateBack(
                from: .trailing,
                horizontalTravel: -40,
                verticalTravel: 2
            )
        )
        XCTAssertFalse(
            MobileBackSwipePolicy.shouldNavigateBack(
                from: .trailing,
                horizontalTravel: -80,
                verticalTravel: 75
            )
        )
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

        let remoteSource = "https://example.com/cached.png"
        let cache = RemoteImageCache(directoryURL: directory.appendingPathComponent("cache"))
        let cachedURL = try cache.store(try XCTUnwrap(image.pngData()), for: remoteSource)
        XCTAssertEqual(
            MobileImageResolver(remoteImageCache: cache).resolve(
                source: remoteSource,
                relativeTo: directory
            ),
            .local(cachedURL)
        )
    }

    func testErrorsHaveReadableMessages() {
        XCTAssertNotNil(MobileDocumentAccessError.unreadableDocument.errorDescription)
        XCTAssertNotNil(MobileDocumentAccessError.unsupportedTextEncoding.errorDescription)
        XCTAssertEqual(
            MobileDocumentAccessError.permissionRequired("Linked.md").errorDescription,
            "Allow access to the folder containing “Linked.md” so Markdown Printer can open it."
        )
        XCTAssertEqual(MobileImagePlaceholderReason.remote.message, "Remote image not loaded")
        XCTAssertEqual(MobileImagePlaceholderReason.missing.message, "Image not found")
        XCTAssertEqual(MobileImagePlaceholderReason.corrupt.message, "Image could not be displayed")
        XCTAssertEqual(MobileImagePlaceholderReason.inaccessible.message, "Image unavailable from this file provider")
        XCTAssertNotNil(MobileDirectoryAccessError.wrongFolder("Linked.md").errorDescription)
        XCTAssertNotNil(MobileDirectoryAccessError.accessDenied.errorDescription)
        XCTAssertNotNil(MobileDirectoryAccessError.bookmarkFailed.errorDescription)
        XCTAssertNotNil(MobileDirectoryAccessError.noPendingRequest.errorDescription)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MobileDocumentAccessTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

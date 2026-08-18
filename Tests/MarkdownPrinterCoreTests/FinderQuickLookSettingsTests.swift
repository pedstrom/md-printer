import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class DefaultApplicationControllerTests: XCTestCase {
    private let applicationURL = URL(fileURLWithPath: "/Applications/Markdown Printer.app")
    private let typeOne = UTType(exportedAs: "com.example.markdown-one", conformingTo: .plainText)

    func testDefaultRequestUsesOneDeclaredMarkdownTypeForEverySupportedExtension() {
        let types = DefaultApplicationController.resolvedDefaultApplicationContentTypes()
        let identifiers = types.map(\.identifier)

        XCTAssertEqual(identifiers, ["net.daringfireball.markdown"])
        XCTAssertFalse(identifiers.contains(UTType.plainText.identifier))
        XCTAssertEqual(
            DefaultApplicationController.supportedFilenameExtensions,
            ["md", "markdown", "mdown", "mkd"]
        )
    }

    func testRefreshReportsDefaultWhenDeclaredTypeMatches() {
        let workspace = FakeDefaultApplicationWorkspace()
        let controller = makeController(workspace: workspace)

        controller.refreshDefaultStatus()
        XCTAssertEqual(controller.state, .idle)

        workspace.defaults[typeOne.identifier] = applicationURL
        controller.refreshDefaultStatus()
        XCTAssertEqual(controller.state, .isDefault)
    }

    func testRequestSetsDeclaredTypeOnceThenVerifiesSuccess() async {
        let workspace = FakeDefaultApplicationWorkspace()
        let controller = makeController(workspace: workspace)

        await controller.makeMarkdownPrinterDefault()

        XCTAssertEqual(workspace.requestedIdentifiers, [typeOne.identifier])
        XCTAssertEqual(controller.state, .isDefault)
    }

    func testProductionResolverMakesOnlyOneWorkspaceRequest() async {
        let workspace = FakeDefaultApplicationWorkspace()
        let controller = DefaultApplicationController(
            workspace: workspace,
            applicationURL: applicationURL
        )

        await controller.makeMarkdownPrinterDefault()

        XCTAssertEqual(workspace.requestedIdentifiers, ["net.daringfireball.markdown"])
        XCTAssertEqual(controller.state, .isDefault)
    }

    func testReturnedErrorKeepsButtonStateActionable() async {
        let workspace = FakeDefaultApplicationWorkspace()
        workspace.errors[typeOne.identifier] = TestDefaultApplicationError.denied
        let controller = makeController(workspace: workspace)

        await controller.makeMarkdownPrinterDefault()

        XCTAssertEqual(workspace.requestedIdentifiers, [typeOne.identifier])
        XCTAssertEqual(controller.state, .failed("macOS declined the request."))
        XCTAssertFalse(controller.isRequesting)
    }

    func testVerificationFailureIsReported() async {
        let workspace = FakeDefaultApplicationWorkspace()
        workspace.shouldPersistRequests = false
        let controller = makeController(workspace: workspace)

        await controller.makeMarkdownPrinterDefault()

        XCTAssertEqual(
            controller.state,
            .failed("macOS did not confirm Markdown Printer as the default for all Markdown files.")
        )
    }

    func testEmptyResolvedTypeListIsReported() async {
        let workspace = FakeDefaultApplicationWorkspace()
        let controller = DefaultApplicationController(
            workspace: workspace,
            applicationURL: applicationURL,
            contentTypeResolver: { [] }
        )

        await controller.makeMarkdownPrinterDefault()

        XCTAssertEqual(
            controller.state,
            .failed("macOS did not report any Markdown content types to update.")
        )
    }

    private func makeController(
        workspace: FakeDefaultApplicationWorkspace
    ) -> DefaultApplicationController {
        DefaultApplicationController(
            workspace: workspace,
            applicationURL: applicationURL,
            contentTypeResolver: { [self.typeOne] }
        )
    }
}

@MainActor
final class FinderQuickLookSettingsTests: XCTestCase {
    func testSettingsCopyDocumentsUseActivationRemovalAndDurablePath() {
        XCTAssertTrue(FinderQuickLookSettingsCopy.usage.contains("Space"))
        XCTAssertTrue(FinderQuickLookSettingsCopy.usage.contains("⌘Y"))
        XCTAssertTrue(FinderQuickLookSettingsCopy.bundled.contains("Deleting the app removes it"))
        XCTAssertTrue(FinderQuickLookSettingsCopy.troubleshooting.contains(
            "System Settings → General → Login Items & Extensions → Quick Look ⓘ"
        ))
        XCTAssertFalse(FinderQuickLookSettingsCopy.troubleshooting.lowercased().contains("another"))
    }

    func testButtonOpensNormalSystemSettings() {
        let opener = FakeWorkspaceOpener(results: [true])
        let navigator = FinderQuickLookSettingsNavigator(opener: opener)

        navigator.openSystemSettings()

        XCTAssertEqual(opener.openedURLs, [
            FinderQuickLookSettingsNavigator.systemSettingsURL
        ])
        XCTAssertTrue(FinderQuickLookSettingsNavigator.systemSettingsURL.isFileURL)
    }
}

@MainActor
private final class FakeDefaultApplicationWorkspace: DefaultApplicationWorkspace {
    var defaults: [String: URL] = [:]
    var errors: [String: Error] = [:]
    var shouldPersistRequests = true
    private(set) var requestedIdentifiers: [String] = []

    func defaultApplicationURL(for contentType: UTType) -> URL? {
        defaults[contentType.identifier]
    }

    func setDefaultApplication(
        at applicationURL: URL,
        toOpen contentType: UTType,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        requestedIdentifiers.append(contentType.identifier)
        if let error = errors[contentType.identifier] {
            completion(error)
            return
        }
        if shouldPersistRequests {
            defaults[contentType.identifier] = applicationURL
        }
        completion(nil)
    }
}

private enum TestDefaultApplicationError: LocalizedError {
    case denied

    var errorDescription: String? { "macOS declined the request." }
}

@MainActor
private final class FakeWorkspaceOpener: WorkspaceOpening {
    private var results: [Bool]
    private(set) var openedURLs: [URL] = []

    init(results: [Bool]) {
        self.results = results
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        return results.isEmpty ? true : results.removeFirst()
    }
}

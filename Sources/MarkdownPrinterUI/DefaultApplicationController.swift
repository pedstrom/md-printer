import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
package protocol DefaultApplicationWorkspace: AnyObject {
    func defaultApplicationURL(for contentType: UTType) -> URL?
    func setDefaultApplication(
        at applicationURL: URL,
        toOpen contentType: UTType,
        completion: @escaping @Sendable (Error?) -> Void
    )
}

@MainActor
private final class SystemDefaultApplicationWorkspace: DefaultApplicationWorkspace {
    func defaultApplicationURL(for contentType: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: contentType)
    }

    func setDefaultApplication(
        at applicationURL: URL,
        toOpen contentType: UTType,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        NSWorkspace.shared.setDefaultApplication(
            at: applicationURL,
            toOpen: contentType,
            completion: completion
        )
    }
}

@MainActor
public final class DefaultApplicationController: ObservableObject {
    public enum State: Equatable {
        case idle
        case requesting
        case isDefault
        case failed(String)
    }

    public static let supportedFilenameExtensions = ["md", "markdown", "mdown", "mkd"]
    public static let declaredMarkdownType = UTType(
        importedAs: "net.daringfireball.markdown"
    )
    public static let defaultApplicationContentTypes = [declaredMarkdownType]

    @Published public private(set) var state: State = .idle

    public var isRequesting: Bool { state == .requesting }

    private let workspace: any DefaultApplicationWorkspace
    private let applicationURL: URL
    private let contentTypeResolver: () -> [UTType]

    public convenience init() {
        self.init(
            workspace: SystemDefaultApplicationWorkspace(),
            applicationURL: Bundle.main.bundleURL
        )
    }

    package init(
        workspace: any DefaultApplicationWorkspace,
        applicationURL: URL,
        contentTypeResolver: @MainActor @escaping () -> [UTType] = DefaultApplicationController
            .resolvedDefaultApplicationContentTypes
    ) {
        self.workspace = workspace
        self.applicationURL = applicationURL
        self.contentTypeResolver = contentTypeResolver
    }

    public static func resolvedDefaultApplicationContentTypes() -> [UTType] {
        defaultApplicationContentTypes
    }

    public func refreshDefaultStatus() {
        let types = contentTypeResolver()
        state = types.isEmpty || !allTypesUseThisApplication(types) ? .idle : .isDefault
    }

    public func makeMarkdownPrinterDefault() async {
        guard state != .requesting else { return }
        state = .requesting
        let types = contentTypeResolver()
        guard !types.isEmpty else {
            state = .failed("macOS did not report any Markdown content types to update.")
            return
        }

        for type in types {
            if let error = await requestDefault(for: type) {
                state = .failed(error.localizedDescription)
                return
            }
        }

        if allTypesUseThisApplication(types) {
            state = .isDefault
        } else {
            state = .failed(
                "macOS did not confirm Markdown Printer as the default for all Markdown files."
            )
        }
    }

    private func requestDefault(for type: UTType) async -> Error? {
        await withCheckedContinuation { continuation in
            workspace.setDefaultApplication(
                at: applicationURL,
                toOpen: type
            ) { error in
                continuation.resume(returning: error)
            }
        }
    }

    private func allTypesUseThisApplication(_ types: [UTType]) -> Bool {
        let expectedURL = normalized(applicationURL)
        return types.allSatisfy { type in
            guard let actualURL = workspace.defaultApplicationURL(for: type) else {
                return false
            }
            return normalized(actualURL) == expectedURL
        }
    }

    private func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

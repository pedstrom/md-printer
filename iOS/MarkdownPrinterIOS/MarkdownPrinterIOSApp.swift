import MarkdownPrinterCore
import MarkdownPrinterMobileSupport
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct MarkdownPrinterIOSApp: App {
    var body: some Scene {
        WindowGroup {
            MarkdownPrinterRootView()
        }
    }
}

private struct MarkdownPrinterRootView: View {
    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    var body: some View {
        if isUITesting {
            UITestMarkdownDocumentContainer()
        } else {
            MarkdownDocumentBrowser()
                .ignoresSafeArea()
        }
    }
}

private struct MarkdownDocumentBrowser: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let controller = UIDocumentBrowserViewController(
            forOpening: [MobileMarkdownFileDocument.markdownContentType]
        )
        controller.delegate = context.coordinator
        controller.allowsDocumentCreation = false
        controller.allowsPickingMultipleItems = false
        context.coordinator.controller = controller
        context.coordinator.installStoreReadinessItems(on: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentBrowserViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {
        weak var controller: UIDocumentBrowserViewController?

        func installStoreReadinessItems(on controller: UIDocumentBrowserViewController) {
            let sampleButton = UIBarButtonItem(
                title: "Sample",
                style: .plain,
                target: self,
                action: #selector(openSample)
            )
            sampleButton.tintColor = .systemBlue
            sampleButton.accessibilityLabel = "Open Markdown Printer sample"
            sampleButton.accessibilityIdentifier = "open-sample-button"
            controller.additionalLeadingNavigationBarButtonItems = [sampleButton]

            let informationButton = UIBarButtonItem(
                image: UIImage(systemName: "info.circle"),
                style: .plain,
                target: self,
                action: #selector(showInformation)
            )
            informationButton.tintColor = .systemBlue
            informationButton.accessibilityLabel = "About, privacy, and support"
            informationButton.accessibilityIdentifier = "app-information-button"
            controller.additionalTrailingNavigationBarButtonItems = [informationButton]
        }

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didPickDocumentsAt documentURLs: [URL]
        ) {
            guard let url = documentURLs.first else { return }
            presentDocument(at: url, from: controller)
        }

        @objc private func openSample() {
            guard let controller else { return }
            do {
                let url = try AppStoreSampleDocument.ensureExists()
                presentDocument(at: url, from: controller)
            } catch {
                presentError(error, from: controller)
            }
        }

        @objc private func showInformation() {
            guard let controller else { return }
            let hosting = UIHostingController(
                rootView: MarkdownPrinterInformationView {
                    controller.dismiss(animated: true)
                }
            )
            hosting.modalPresentationStyle = .pageSheet
            hosting.sheetPresentationController?.detents = [.medium(), .large()]
            controller.present(hosting, animated: true)
        }

        private func presentDocument(at url: URL, from controller: UIDocumentBrowserViewController) {
            let hosting = UIHostingController(
                rootView: BrowserMarkdownDocumentContainer(url: url) { [weak controller] in
                    controller?.dismiss(animated: true)
                }
            )
            hosting.modalPresentationStyle = .fullScreen
            controller.present(hosting, animated: true)
        }

        private func presentError(_ error: Error, from controller: UIViewController) {
            let alert = UIAlertController(
                title: "Couldn’t Open Sample",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            controller.present(alert, animated: true)
        }

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            failedToImportDocumentAt documentURL: URL,
            error: Error?
        ) {
            let alert = UIAlertController(
                title: "Couldn’t Open Markdown",
                message: error?.localizedDescription ?? "The file provider couldn’t make this document available.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            controller.present(alert, animated: true)
        }
    }
}

enum AppStoreSampleDocument {
    static let filename = "Markdown Printer Sample.md"
    static let markdown = """
    # Welcome to Markdown Printer

    This local sample gives you something useful to open immediately. Markdown Printer reads files in place and does not upload their contents.

    ## A quick tour

    - **Formatted Markdown** with headings, lists, links, and tables
    - [x] Search the document
    - [ ] Share, export, or print its PDF

    | Output | Behavior |
    | :--- | :--- |
    | Preview | Continuous and selectable |
    | PDF | Searchable and paginated |

    > Your original Markdown remains unchanged.

    ```swift
    let document = "local and private"
    ```

    Tap **Markdown Printer Sample** in the title bar to explore the document actions. You can delete this sample from Files whenever you like.
    """

    static func ensureExists() throws -> URL {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ensureExists(in: directory)
    }

    static func ensureExists(in directory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: url.path) {
            try Data(markdown.utf8).write(to: url, options: .atomic)
        }
        return url
    }
}

private struct BrowserMarkdownDocumentContainer: View {
    let url: URL
    let onClose: () -> Void
    @State private var linkedDocuments: [URL] = []
    @StateObject private var session = MobileDocumentSession()

    var body: some View {
        NavigationStack(path: $linkedDocuments) {
            Group {
                if session.document != nil {
                    MarkdownViewerView(
                        session: session,
                        linkedDocuments: $linkedDocuments,
                        onClose: onClose
                    )
                } else if let error = session.errorMessage {
                    ContentUnavailableView(
                        "Couldn’t Open Markdown",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(error)
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back", systemImage: "chevron.backward", action: onClose)
                        }
                    }
                } else {
                    ProgressView("Opening…")
                }
            }
            .navigationDestination(for: URL.self) { linkedURL in
                LinkedMarkdownDocumentView(url: linkedURL, linkedDocuments: $linkedDocuments)
            }
        }
        .task(id: url) {
            await session.load(url: url)
        }
    }
}

private struct UITestMarkdownDocumentContainer: View {
    @State private var linkedDocuments: [URL] = []
    @StateObject private var session: MobileDocumentSession

    init() {
        let fixture = Self.makeFixture()
        _session = StateObject(
            wrappedValue: MobileDocumentSession(document: fixture.document, sourceURL: fixture.url)
        )
    }

    var body: some View {
        NavigationStack(path: $linkedDocuments) {
            MarkdownViewerView(session: session, linkedDocuments: $linkedDocuments)
                .navigationDestination(for: URL.self) { url in
                    LinkedMarkdownDocumentView(url: url, linkedDocuments: $linkedDocuments)
                }
        }
    }

    private static func makeFixture() -> (document: MarkdownDocument, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPrinterUITestFixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let linkedURL = directory.appendingPathComponent("linked.markdown")
        let linkedMarkdown = """
        # Linked Markdown Page

        This sibling document opened inside the same viewer.
        """
        try? Data(linkedMarkdown.utf8).write(to: linkedURL, options: .atomic)

        let permissionURL = directory.appendingPathComponent("permission-required.md")
        try? Data("# Permission-gated Markdown".utf8).write(to: permissionURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: permissionURL.path
        )

        let sourceURL = directory.appendingPathComponent("fixture.md")
        let markdown = """
        # iPhone Viewer Fixture

        The exact search phrase appears here. The exact search phrase appears twice.

        [Linked page](linked.markdown) and [Apple website](https://www.apple.com/).

        [Missing linked file](missing.md) demonstrates a recoverable provider error.

        [Permission-gated page](permission-required.md) exercises explicit Files authorization.

        - [x] Render Markdown
        - [ ] Inspect PDF

        | Feature | State |
        | :--- | ---: |
        | Search | Ready |
        | Export | Ready |

        > A local, private Preview-style reader.

        ```swift
        let message = "Hello from Markdown Printer"
        ```

        A note reference[^viewer].

        ![Network artwork](https://example.com/image.png)

        [^viewer]: Footnotes remain searchable and printable.
        """
        try? Data(markdown.utf8).write(to: sourceURL, options: .atomic)
        let document = (try? MarkdownDocument.load(from: sourceURL))
            ?? MarkdownDocument(title: "fixture", markdown: markdown)
        return (document, sourceURL)
    }
}

private struct LinkedMarkdownDocumentView: View {
    let url: URL
    @Binding var linkedDocuments: [URL]
    @StateObject private var session = MobileDocumentSession()
    @State private var showingPermissionPicker = false
    @State private var selectionError: String?

    var body: some View {
        Group {
            if session.document != nil {
                MarkdownViewerView(
                    session: session,
                    linkedDocuments: $linkedDocuments,
                    onNavigateBack: navigateBack
                )
            } else if let request = session.permissionRequest {
                ContentUnavailableView {
                    Label("Folder Access Needed", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(
                        "Allow access to the folder containing “\(request.filename)” once. "
                            + "Markdown Printer will remember it and open links inside that folder directly."
                    )
                } actions: {
                    Button("Allow Folder Access…") {
                        showingPermissionPicker = true
                    }
                }
            } else if let error = session.errorMessage {
                ContentUnavailableView(
                    "Couldn’t Open Markdown",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(error)
                )
            } else {
                ProgressView("Opening…")
            }
        }
        .task(id: url) {
            await session.load(url: url)
            if session.permissionRequest != nil {
                showingPermissionPicker = true
            }
        }
        .sheet(isPresented: $showingPermissionPicker) {
            if let request = session.permissionRequest {
                LinkedMarkdownFolderPicker(request: request) { selectedURL in
                    showingPermissionPicker = false
                    guard let selectedURL else { return }
                    do {
                        try session.authorizeDirectory(selectedURL)
                    } catch {
                        selectionError = error.localizedDescription
                        return
                    }
                    Task { await session.load(url: request.url) }
                }
            }
        }
        .alert(
            "Choose Containing Folder",
            isPresented: Binding(
                get: { selectionError != nil },
                set: { if !$0 { selectionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(selectionError ?? "Choose a folder containing the linked Markdown file.")
        }
    }

    private func navigateBack() {
        guard !linkedDocuments.isEmpty else { return }
        linkedDocuments.removeLast()
    }
}

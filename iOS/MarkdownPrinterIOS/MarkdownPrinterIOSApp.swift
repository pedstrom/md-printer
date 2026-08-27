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
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentBrowserViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {
        weak var controller: UIDocumentBrowserViewController?

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didPickDocumentsAt documentURLs: [URL]
        ) {
            guard let url = documentURLs.first else { return }
            let hosting = UIHostingController(
                rootView: BrowserMarkdownDocumentContainer(url: url) { [weak controller] in
                    controller?.dismiss(animated: true)
                }
            )
            hosting.modalPresentationStyle = .fullScreen
            controller.present(hosting, animated: true)
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

        let sourceURL = directory.appendingPathComponent("fixture.md")
        let markdown = """
        # iPhone Viewer Fixture

        The exact search phrase appears here. The exact search phrase appears twice.

        [Linked page](linked.markdown) and [Apple website](https://www.apple.com/).

        [Missing linked file](missing.md) demonstrates a recoverable provider error.

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

    var body: some View {
        Group {
            if session.document != nil {
                MarkdownViewerView(session: session, linkedDocuments: $linkedDocuments)
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
        }
    }
}

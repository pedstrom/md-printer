import AppKit
import MarkdownPrinterUI
import SwiftUI

@main
struct MarkdownPrinterApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self) private var applicationDelegate

    var body: some Scene {
        Window("Markdown Printer", id: "welcome") {
            WelcomeMarkdownWindow()
        }
        .defaultSize(width: 760, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        DocumentGroup(viewing: MarkdownFileDocument.self) { configuration in
            MarkdownDocumentWindow(
                fileDocument: configuration.document,
                sourceURL: configuration.fileURL
            )
        }
        .defaultSize(width: 760, height: 980)
    }
}

@MainActor
private struct WelcomeMarkdownWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openDocument) private var openDocument
    @StateObject private var session = DocumentSession()

    var body: some View {
        MarkdownPrinterView(session: session, openFiles: openFiles)
    }

    private func openFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            var openedDocument = false
            for url in urls {
                do {
                    try await openDocument(at: url)
                    openedDocument = true
                } catch {
                    session.report(error: error)
                }
            }
            if openedDocument {
                dismissWindow(id: "welcome")
            }
        }
    }
}

@MainActor
private struct MarkdownDocumentWindow: View {
    @Environment(\.openDocument) private var openDocument
    @StateObject private var session: DocumentSession
    private let sourceURL: URL?

    init(fileDocument: MarkdownFileDocument, sourceURL: URL?) {
        self.sourceURL = sourceURL
        let session = DocumentSession()
        do {
            try session.apply(fileDocument.markdownDocument(sourceURL: sourceURL))
        } catch {
            session.report(error: error)
        }
        _session = StateObject(wrappedValue: session)
    }

    var body: some View {
        MarkdownPrinterView(session: session, openFiles: openFiles)
            .onAppear(perform: applyMarkdownWindowTitle)
    }

    private func openFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                do {
                    try await openDocument(at: url)
                } catch {
                    session.report(error: error)
                }
            }
        }
    }

    private func applyMarkdownWindowTitle() {
        guard let sourceURL else { return }
        let fileName = sourceURL.lastPathComponent
        let fileStem = sourceURL.deletingPathExtension().lastPathComponent

        for delay in [0.0, 0.1, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApplication.shared.windows.first(where: { window in
                    window.representedURL?.standardizedFileURL == sourceURL.standardizedFileURL
                        || window.title == fileName
                        || window.title == fileStem
                }) else { return }
                window.title = session.title
            }
        }
    }
}

import AppKit
import MarkdownPrinterUI
import SwiftUI

@main
struct MarkdownPrinterApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self) private var applicationDelegate
    @StateObject private var exportPreferences = ExportPreferences()

    var body: some Scene {
        Window("Markdown Printer", id: "welcome") {
            WelcomeMarkdownWindow(exportPreferences: exportPreferences)
        }
        .defaultSize(width: 760, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Markdown Printer") {
                    AboutPanel.show()
                }
            }
            PDFSearchCommands()
        }

        DocumentGroup(viewing: MarkdownFileDocument.self) { configuration in
            MarkdownDocumentWindow(
                fileDocument: configuration.document,
                sourceURL: configuration.fileURL,
                exportPreferences: exportPreferences
            )
        }
        .defaultSize(width: 760, height: 980)

        Settings {
            ExportSettingsView(preferences: exportPreferences)
        }
    }
}

@MainActor
private struct WelcomeMarkdownWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openDocument) private var openDocument
    @StateObject private var session = DocumentSession()
    @ObservedObject var exportPreferences: ExportPreferences

    var body: some View {
        MarkdownPrinterView(
            session: session,
            exportPreferences: exportPreferences,
            openFiles: openFiles
        )
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
    private let fileDocument: MarkdownFileDocument
    private let sourceURL: URL?
    @ObservedObject var exportPreferences: ExportPreferences

    init(
        fileDocument: MarkdownFileDocument,
        sourceURL: URL?,
        exportPreferences: ExportPreferences
    ) {
        self.fileDocument = fileDocument
        self.sourceURL = sourceURL
        self.exportPreferences = exportPreferences
        _session = StateObject(
            wrappedValue: Self.makeSession(fileDocument: fileDocument, sourceURL: sourceURL)
        )
    }

    var body: some View {
        MarkdownPrinterView(
            session: session,
            exportPreferences: exportPreferences,
            openFiles: openFiles
        )
            .onAppear {
                synchronizeFileDocument()
                session.startMonitoringSourceChanges()
            }
            .onChange(of: fileDocument.markdownDocument(sourceURL: sourceURL).markdown) {
                synchronizeFileDocument()
                session.startMonitoringSourceChanges()
            }
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

    private static func makeSession(
        fileDocument: MarkdownFileDocument,
        sourceURL: URL?
    ) -> DocumentSession {
        let session = DocumentSession()
        do {
            try session.apply(fileDocument.markdownDocument(sourceURL: sourceURL))
        } catch {
            session.report(error: error)
        }
        return session
    }

    private func synchronizeFileDocument() {
        do {
            try session.synchronize(with: fileDocument.markdownDocument(sourceURL: sourceURL))
        } catch {
            session.report(error: error)
        }
    }

}

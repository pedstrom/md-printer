import AppKit
import MarkdownPrinterUI
import SwiftUI

@main
struct MarkdownPrinterApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self) private var applicationDelegate
    @StateObject private var exportPreferences: ExportPreferences
    @StateObject private var activityCoordinator: ApplicationActivityCoordinator
    @StateObject private var documentRestoration: OpenDocumentRestorationController
    @StateObject private var updateController: UpdateController
    @StateObject private var defaultApplicationController: DefaultApplicationController
    private let quickLookNavigator: FinderQuickLookSettingsNavigator

    init() {
        let exportPreferences = ExportPreferences()
        let activityCoordinator = ApplicationActivityCoordinator()
        let documentRestoration = OpenDocumentRestorationController()
        let updateController = UpdateController(
            documentRestoration: documentRestoration,
            activityCoordinator: activityCoordinator
        )
        _exportPreferences = StateObject(wrappedValue: exportPreferences)
        _activityCoordinator = StateObject(wrappedValue: activityCoordinator)
        _documentRestoration = StateObject(wrappedValue: documentRestoration)
        _updateController = StateObject(wrappedValue: updateController)
        _defaultApplicationController = StateObject(
            wrappedValue: DefaultApplicationController()
        )
        quickLookNavigator = FinderQuickLookSettingsNavigator()
    }

    var body: some Scene {
        Window("Markdown Printer", id: "welcome") {
            WelcomeMarkdownWindow(
                exportPreferences: exportPreferences,
                activityCoordinator: activityCoordinator,
                documentRestoration: documentRestoration
            )
        }
        .defaultSize(width: 760, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About Markdown Printer") {
                    AboutPanel.show()
                }
                Divider()
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }
            PDFSearchCommands()
        }

        DocumentGroup(viewing: MarkdownFileDocument.self) { configuration in
            MarkdownDocumentWindow(
                fileDocument: configuration.document,
                sourceURL: configuration.fileURL,
                exportPreferences: exportPreferences,
                activityCoordinator: activityCoordinator,
                documentRestoration: documentRestoration
            )
        }
        .defaultSize(width: 760, height: 980)

        Settings {
            ExportSettingsView(
                preferences: exportPreferences,
                updateController: updateController,
                defaultApplicationController: defaultApplicationController,
                quickLookNavigator: quickLookNavigator
            )
        }
    }
}

@MainActor
private struct WelcomeMarkdownWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openDocument) private var openDocument
    @StateObject private var session = DocumentSession()
    @State private var hasAttemptedUpdateRestoration = false
    @ObservedObject var exportPreferences: ExportPreferences
    let activityCoordinator: ApplicationActivityCoordinator
    let documentRestoration: OpenDocumentRestorationController

    var body: some View {
        MarkdownPrinterView(
            session: session,
            exportPreferences: exportPreferences,
            activityCoordinator: activityCoordinator,
            openFiles: openFiles
        )
        .task {
            await restoreDocumentsAfterUpdate()
        }
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

    private func restoreDocumentsAfterUpdate() async {
        guard !hasAttemptedUpdateRestoration else { return }
        hasAttemptedUpdateRestoration = true
        guard
            let currentBuild = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        else {
            return
        }

        let urls = documentRestoration.consumeDocumentsForRelaunch(currentBuild: currentBuild)
        guard !urls.isEmpty else { return }
        await Task.yield()
        openFiles(urls.filter { !documentRestoration.isDocumentOpen(at: $0) })
    }
}

@MainActor
private struct MarkdownDocumentWindow: View {
    @Environment(\.openDocument) private var openDocument
    @StateObject private var session: DocumentSession
    private let fileDocument: MarkdownFileDocument
    private let sourceURL: URL?
    @ObservedObject var exportPreferences: ExportPreferences
    let activityCoordinator: ApplicationActivityCoordinator
    let documentRestoration: OpenDocumentRestorationController

    init(
        fileDocument: MarkdownFileDocument,
        sourceURL: URL?,
        exportPreferences: ExportPreferences,
        activityCoordinator: ApplicationActivityCoordinator,
        documentRestoration: OpenDocumentRestorationController
    ) {
        self.fileDocument = fileDocument
        self.sourceURL = sourceURL
        self.exportPreferences = exportPreferences
        self.activityCoordinator = activityCoordinator
        self.documentRestoration = documentRestoration
        _session = StateObject(
            wrappedValue: Self.makeSession(fileDocument: fileDocument, sourceURL: sourceURL)
        )
    }

    var body: some View {
        MarkdownPrinterView(
            session: session,
            exportPreferences: exportPreferences,
            activityCoordinator: activityCoordinator,
            openFiles: openFiles
        )
            .onAppear {
                documentRestoration.documentDidOpen(at: sourceURL)
                synchronizeFileDocument()
                session.startMonitoringSourceChanges()
            }
            .onDisappear {
                documentRestoration.documentDidClose(at: sourceURL)
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

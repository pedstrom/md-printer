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
    @StateObject private var windowTabCoordinator: WindowTabCoordinator
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
        _windowTabCoordinator = StateObject(wrappedValue: WindowTabCoordinator())
        quickLookNavigator = FinderQuickLookSettingsNavigator()
    }

    var body: some Scene {
        WindowGroup("Markdown Printer", id: "welcome", for: UUID.self) { identifier in
            WelcomeMarkdownWindow(
                identifier: identifier.wrappedValue,
                applicationDelegate: applicationDelegate,
                exportPreferences: exportPreferences,
                activityCoordinator: activityCoordinator,
                documentRestoration: documentRestoration,
                windowTabCoordinator: windowTabCoordinator
            )
        } defaultValue: {
            UUID()
        }
        .defaultSize(width: 760, height: 980)
        .commands {
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
            PDFFitPageCommands()
            WindowTabCommands(coordinator: windowTabCoordinator)
        }

        DocumentGroup(viewing: MarkdownFileDocument.self) { configuration in
            MarkdownDocumentWindow(
                fileDocument: configuration.document,
                sourceURL: configuration.fileURL,
                exportPreferences: exportPreferences,
                activityCoordinator: activityCoordinator,
                documentRestoration: documentRestoration,
                applicationDelegate: applicationDelegate,
                windowTabCoordinator: windowTabCoordinator
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
    let identifier: UUID
    let applicationDelegate: ApplicationLifecycleDelegate
    @ObservedObject var exportPreferences: ExportPreferences
    let activityCoordinator: ApplicationActivityCoordinator
    let documentRestoration: OpenDocumentRestorationController
    let windowTabCoordinator: WindowTabCoordinator

    var body: some View {
        MarkdownPrinterView(
            session: session,
            exportPreferences: exportPreferences,
            activityCoordinator: activityCoordinator,
            openFiles: openFiles
        )
        .background(
            WindowTabAttachmentView(
                coordinator: windowTabCoordinator,
                identifier: identifier
            )
        )
        .background(
            WindowTabActionInstallerView(
                applicationDelegate: applicationDelegate,
                coordinator: windowTabCoordinator
            )
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
                let tabRequest = windowTabCoordinator.prepareDocumentTab(
                    for: url,
                    replacingWelcomeWindow: identifier
                )
                do {
                    try await openDocument(at: url)
                    openedDocument = true
                } catch {
                    if let tabRequest {
                        windowTabCoordinator.cancelDocumentTabRequest(tabRequest, for: url)
                    }
                    session.report(error: error)
                }
            }
            if openedDocument {
                dismissWindow(id: "welcome", value: identifier)
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
    @StateObject private var windowRestoration: DocumentWindowRestorationCoordinator
    private let fileDocument: MarkdownFileDocument
    private let sourceURL: URL?
    @ObservedObject var exportPreferences: ExportPreferences
    let activityCoordinator: ApplicationActivityCoordinator
    let applicationDelegate: ApplicationLifecycleDelegate
    let windowTabCoordinator: WindowTabCoordinator

    init(
        fileDocument: MarkdownFileDocument,
        sourceURL: URL?,
        exportPreferences: ExportPreferences,
        activityCoordinator: ApplicationActivityCoordinator,
        documentRestoration: OpenDocumentRestorationController,
        applicationDelegate: ApplicationLifecycleDelegate,
        windowTabCoordinator: WindowTabCoordinator
    ) {
        self.fileDocument = fileDocument
        self.sourceURL = sourceURL
        self.exportPreferences = exportPreferences
        self.activityCoordinator = activityCoordinator
        self.applicationDelegate = applicationDelegate
        self.windowTabCoordinator = windowTabCoordinator
        _session = StateObject(
            wrappedValue: Self.makeSession(fileDocument: fileDocument, sourceURL: sourceURL)
        )
        _windowRestoration = StateObject(
            wrappedValue: DocumentWindowRestorationCoordinator(
                sourceURL: sourceURL,
                restorationController: documentRestoration
            )
        )
    }

    var body: some View {
        MarkdownPrinterView(
            session: session,
            exportPreferences: exportPreferences,
            activityCoordinator: activityCoordinator,
            openFiles: openFiles
        )
            .environment(\.documentWindowRestorationCoordinator, windowRestoration)
            .background(DocumentWindowRestorationAttachmentView(coordinator: windowRestoration))
            .background(
                WindowTabAttachmentView(
                    coordinator: windowTabCoordinator,
                    documentURL: sourceURL
                )
            )
            .background(
                WindowTabActionInstallerView(
                    applicationDelegate: applicationDelegate,
                    coordinator: windowTabCoordinator
                )
            )
            .onAppear {
                windowRestoration.activate()
                synchronizeFileDocument()
                session.startMonitoringSourceChanges()
            }
            .onDisappear {
                windowRestoration.deactivate()
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

@MainActor
private struct WindowTabActionInstallerView: View {
    @Environment(\.openWindow) private var openWindow
    let applicationDelegate: ApplicationLifecycleDelegate
    let coordinator: WindowTabCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                coordinator.newTabRequestHandler = { [weak coordinator] sourceWindow in
                    guard let coordinator else { return }
                    let identifier = coordinator.prepareNewTab(from: sourceWindow)
                    openWindow(id: "welcome", value: identifier)
                }
                applicationDelegate.newTabHandler = { [weak coordinator] in
                    coordinator?.requestNewTab(from: NSApp.keyWindow ?? NSApp.mainWindow)
                }
                applicationDelegate.configureFileMenu(in: NSApp.mainMenu)
                DispatchQueue.main.async { [weak applicationDelegate] in
                    applicationDelegate?.configureFileMenu(in: NSApp.mainMenu)
                }
            }
    }
}

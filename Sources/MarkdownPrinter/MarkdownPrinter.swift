import AppKit
import MarkdownPrinterUI
import SwiftUI

@main
struct MarkdownPrinterApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self) private var applicationDelegate
    @StateObject private var exportPreferences: ExportPreferences
    @StateObject private var pagePreferences: PagePreferences
    @StateObject private var activityCoordinator: ApplicationActivityCoordinator
    @StateObject private var documentRestoration: OpenDocumentRestorationController
    @StateObject private var updateController: UpdateController
    @StateObject private var defaultApplicationController: DefaultApplicationController
    @StateObject private var windowTabCoordinator: WindowTabCoordinator
    @StateObject private var helpNavigator: MarkdownPrinterHelpNavigator
    private let quickLookNavigator: FinderQuickLookSettingsNavigator

    init() {
        let exportPreferences = ExportPreferences()
        let pagePreferences = PagePreferences()
        let activityCoordinator = ApplicationActivityCoordinator()
        let documentRestoration = OpenDocumentRestorationController()
        let windowTabCoordinator = WindowTabCoordinator()
        documentRestoration.workspaceCaptureProvider = {
            [weak documentRestoration, weak windowTabCoordinator] in
            guard let documentRestoration, let windowTabCoordinator else {
                return WorkspaceSnapshot(groups: [])
            }
            return windowTabCoordinator.captureWorkspace(
                restorationController: documentRestoration
            )
        }
        let updateController = UpdateController(
            documentRestoration: documentRestoration,
            activityCoordinator: activityCoordinator
        )
        _exportPreferences = StateObject(wrappedValue: exportPreferences)
        _pagePreferences = StateObject(wrappedValue: pagePreferences)
        _activityCoordinator = StateObject(wrappedValue: activityCoordinator)
        _documentRestoration = StateObject(wrappedValue: documentRestoration)
        _updateController = StateObject(wrappedValue: updateController)
        _defaultApplicationController = StateObject(
            wrappedValue: DefaultApplicationController()
        )
        _windowTabCoordinator = StateObject(wrappedValue: windowTabCoordinator)
        _helpNavigator = StateObject(wrappedValue: MarkdownPrinterHelpNavigator())
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
                windowTabCoordinator: windowTabCoordinator,
                helpNavigator: helpNavigator
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
            WindowTabCommands(coordinator: windowTabCoordinator)
        }

        DocumentGroup(viewing: MarkdownFileDocument.self) { configuration in
            MarkdownDocumentWindow(
                fileDocument: configuration.document,
                sourceURL: configuration.fileURL,
                exportPreferences: exportPreferences,
                pagePreferences: pagePreferences,
                activityCoordinator: activityCoordinator,
                documentRestoration: documentRestoration,
                applicationDelegate: applicationDelegate,
                windowTabCoordinator: windowTabCoordinator,
                helpNavigator: helpNavigator
            )
        }
        .defaultSize(width: 760, height: 980)
        .commands {
            PDFSearchCommands()
            PDFThumbnailCommands()
            PDFViewingCommands()
            DocumentFileCommands()
            WindowTabCommands(coordinator: windowTabCoordinator)
        }

        Window("Markdown Printer Help", id: "help") {
            MarkdownPrinterHelpView(navigator: helpNavigator)
        }
        .defaultSize(width: 640, height: 700)
        .windowResizability(.contentMinSize)

        Settings {
            TabView {
                ExportSettingsView(
                    preferences: exportPreferences,
                    updateController: updateController,
                    defaultApplicationController: defaultApplicationController,
                    quickLookNavigator: quickLookNavigator
                )
                .tabItem { Label("General", systemImage: "gearshape") }

                PageSettingsView(preferences: pagePreferences)
                    .tabItem { Label("Page", systemImage: "doc") }
            }
        }
    }
}

@MainActor
private struct WelcomeMarkdownWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openWindow) private var openWindow
    @StateObject private var session = DocumentSession()
    @State private var hasAttemptedUpdateRestoration = false
    let identifier: UUID
    let applicationDelegate: ApplicationLifecycleDelegate
    @ObservedObject var exportPreferences: ExportPreferences
    let activityCoordinator: ApplicationActivityCoordinator
    let documentRestoration: OpenDocumentRestorationController
    let windowTabCoordinator: WindowTabCoordinator
    let helpNavigator: MarkdownPrinterHelpNavigator

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
                coordinator: windowTabCoordinator,
                documentRestoration: documentRestoration,
                session: session,
                welcomeIdentifier: identifier,
                helpNavigator: helpNavigator
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

        guard let workspace = documentRestoration.consumeWorkspaceForRelaunch(
            currentBuild: currentBuild
        ) else { return }
        await Task.yield()
        let result = await WorkspaceRestorer.restore(
            workspace,
            restorationController: documentRestoration,
            tabCoordinator: windowTabCoordinator,
            openDocument: { url in try await openDocument(at: url) },
            openWelcome: { identifier in openWindow(id: "welcome", value: identifier) }
        )
        if result.openedDocumentCount > 0 {
            dismissWindow(id: "welcome", value: identifier)
        }
        if !result.failedDocumentNames.isEmpty {
            session.report(error: WorkspaceRestorationSummaryError(
                failedDocumentNames: result.failedDocumentNames
            ))
        }
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
    @ObservedObject var pagePreferences: PagePreferences
    let activityCoordinator: ApplicationActivityCoordinator
    let documentRestoration: OpenDocumentRestorationController
    let applicationDelegate: ApplicationLifecycleDelegate
    let windowTabCoordinator: WindowTabCoordinator
    let helpNavigator: MarkdownPrinterHelpNavigator

    init(
        fileDocument: MarkdownFileDocument,
        sourceURL: URL?,
        exportPreferences: ExportPreferences,
        pagePreferences: PagePreferences,
        activityCoordinator: ApplicationActivityCoordinator,
        documentRestoration: OpenDocumentRestorationController,
        applicationDelegate: ApplicationLifecycleDelegate,
        windowTabCoordinator: WindowTabCoordinator,
        helpNavigator: MarkdownPrinterHelpNavigator
    ) {
        self.fileDocument = fileDocument
        self.sourceURL = sourceURL
        self.exportPreferences = exportPreferences
        self.pagePreferences = pagePreferences
        self.activityCoordinator = activityCoordinator
        self.documentRestoration = documentRestoration
        self.applicationDelegate = applicationDelegate
        self.windowTabCoordinator = windowTabCoordinator
        self.helpNavigator = helpNavigator
        let session = Self.makeSession(
            fileDocument: fileDocument,
            sourceURL: sourceURL,
            pagePreferences: pagePreferences
        )
        _session = StateObject(wrappedValue: session)
        _windowRestoration = StateObject(
            wrappedValue: DocumentWindowRestorationCoordinator(
                sourceURL: sourceURL,
                restorationController: documentRestoration,
                session: session
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
                    coordinator: windowTabCoordinator,
                    documentRestoration: documentRestoration,
                    session: session,
                    welcomeIdentifier: nil,
                    helpNavigator: helpNavigator
                )
            )
            .onAppear {
                windowRestoration.activate()
            }
            .onDisappear {
                windowRestoration.deactivate()
            }
            .task(id: fileDocument.markdown) {
                await synchronizeFileDocument()
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
        sourceURL: URL?,
        pagePreferences: PagePreferences
    ) -> DocumentSession {
        DocumentSession(pagePreferences: pagePreferences)
    }

    private func synchronizeFileDocument() async {
        do {
            let document = fileDocument.markdownDocument(sourceURL: sourceURL)
            if session.hasDocument {
                try await session.synchronizeAsync(with: document)
            } else {
                try await session.applyAsync(document)
            }
        } catch {
            guard !Task.isCancelled else { return }
            session.report(error: error)
        }
    }
}

@MainActor
private struct WindowTabActionInstallerView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    let applicationDelegate: ApplicationLifecycleDelegate
    let coordinator: WindowTabCoordinator
    let documentRestoration: OpenDocumentRestorationController
    let session: DocumentSession
    let welcomeIdentifier: UUID?
    let helpNavigator: MarkdownPrinterHelpNavigator

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
                applicationDelegate.documentRestorationController = documentRestoration
                applicationDelegate.normalTerminationHandler = { [weak documentRestoration] in
                    documentRestoration?.captureLastSession()
                }
                applicationDelegate.helpHandler = { [weak helpNavigator] destination in
                    helpNavigator?.show(destination)
                    openWindow(id: "help")
                }
                documentRestoration.reopenLastSessionHandler = {
                    [weak documentRestoration, weak coordinator, weak session] in
                    guard let documentRestoration,
                          let coordinator,
                          let session,
                          let workspace = documentRestoration.lastSessionWorkspace()
                    else { return }
                    Task { @MainActor in
                        let result = await WorkspaceRestorer.restore(
                            workspace,
                            restorationController: documentRestoration,
                            tabCoordinator: coordinator,
                            openDocument: { url in try await openDocument(at: url) },
                            openWelcome: { identifier in
                                openWindow(id: "welcome", value: identifier)
                            }
                        )
                        if result.openedDocumentCount > 0, let welcomeIdentifier {
                            dismissWindow(id: "welcome", value: welcomeIdentifier)
                        }
                        if !result.failedDocumentNames.isEmpty {
                            session.report(error: WorkspaceRestorationSummaryError(
                                failedDocumentNames: result.failedDocumentNames
                            ))
                        }
                    }
                }
                applicationDelegate.configureFileMenu(in: NSApp.mainMenu)
                DispatchQueue.main.async { [weak applicationDelegate] in
                    applicationDelegate?.configureFileMenu(in: NSApp.mainMenu)
                }
            }
    }
}

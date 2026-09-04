@preconcurrency import Foundation
import MarkdownPrinterCore
import MarkdownPrinterMobileSupport
import Network
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
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var incomingDocuments = MobileIncomingDocumentQueue()
    @StateObject private var cloudStatus = MobileCloudBrowserStatusMonitor()

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    private var isOpeningUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing-opening")
    }

    var body: some View {
        Group {
            if isUITesting {
                UITestMarkdownDocumentContainer()
            } else if isOpeningUITesting {
                UITestOpeningDocumentContainer()
            } else {
                VStack(spacing: 0) {
                    MobileCloudBrowserStatusView(
                        status: cloudStatus.status,
                        onRetry: cloudStatus.retry
                    )

                    MarkdownDocumentBrowser(
                        incomingDocument: incomingDocuments.current,
                        onIncomingDocumentHandled: incomingDocuments.complete,
                        onBrowserDidAppear: cloudStatus.refreshIfNeeded
                    )
                }
                .ignoresSafeArea(edges: .bottom)
                .onAppear(perform: cloudStatus.start)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        cloudStatus.refreshIfNeeded()
                    }
                }
            }
        }
        .onOpenURL(perform: incomingDocuments.receive)
    }
}

private struct MobileCloudBrowserStatusView: View {
    let status: MobileCloudBrowserStatus
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if status.showsProgress {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: status.systemImageName)
            }

            Text(status.message)
                .lineLimit(2)

            Spacer(minLength: 4)

            if status.offersRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("icloud-status")
    }
}

@MainActor
final class MobileCloudBrowserStatusMonitor: ObservableObject {
    @Published private(set) var status: MobileCloudBrowserStatus

    private static let freshnessInterval: TimeInterval = 5 * 60
    private static let slowDelay: UInt64 = 8_000_000_000
    private static let timeoutDelay: UInt64 = 30_000_000_000

    private var stateMachine: MobileCloudBrowserStatusStateMachine
    private let forcedStatus: MobileCloudBrowserStatus?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(
        label: "com.peteedstrom.markdown-printer.icloud-status"
    )
    private var networkAvailable: Bool?
    private var metadataQuery: NSMetadataQuery?
    private var queryObserver: NSObjectProtocol?
    private var identityObserver: NSObjectProtocol?
    private var slowTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var started = false

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let forcedStatus = Self.forcedStatus(in: arguments)
        self.forcedStatus = forcedStatus
        let initialStatus = forcedStatus ?? .checking
        stateMachine = MobileCloudBrowserStatusStateMachine(status: initialStatus)
        status = initialStatus
    }

    deinit {
        networkMonitor.cancel()
        if let queryObserver {
            NotificationCenter.default.removeObserver(queryObserver)
        }
        if let identityObserver {
            NotificationCenter.default.removeObserver(identityObserver)
        }
        metadataQuery?.stop()
        slowTask?.cancel()
        timeoutTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        guard forcedStatus == nil else { return }

        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.networkPathChanged(isAvailable: path.status == .satisfied)
            }
        }
        networkMonitor.start(queue: networkQueue)

        identityObserver = NotificationCenter.default.addObserver(
            forName: FileManager.UbiquityIdentityDidChangeMessage.name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginCheck(force: true)
            }
        }

        beginCheck(force: true)
    }

    func refreshIfNeeded() {
        guard forcedStatus == nil else { return }
        beginCheck(force: false)
    }

    func retry() {
        if forcedStatus != nil {
            stateMachine = MobileCloudBrowserStatusStateMachine(status: .checking)
            publishStatus()
        } else {
            beginCheck(force: true)
        }
    }

    private func beginCheck(force: Bool) {
        if !force,
           !stateMachine.needsRefresh(
               at: Date(),
               freshnessInterval: Self.freshnessInterval
           ) {
            return
        }

        cancelMetadataQuery()
        let iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
        guard let checkID = stateMachine.beginCheck(
            networkAvailable: networkAvailable,
            iCloudAvailable: iCloudAvailable
        ) else {
            publishStatus()
            return
        }
        publishStatus()

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.predicate = Self.markdownFilenamePredicate
        metadataQuery = query
        queryObserver = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.completeActiveQuery(checkID: checkID)
            }
        }

        guard query.start() else {
            fail(query: query, checkID: checkID)
            return
        }
        scheduleDelays(for: checkID)
    }

    private func scheduleDelays(for checkID: UInt64) {
        slowTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.slowDelay)
            } catch {
                return
            }
            guard let self else { return }
            stateMachine.markSlow(for: checkID)
            publishStatus()
        }
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.timeoutDelay)
            } catch {
                return
            }
            guard let self, let query = metadataQuery else { return }
            fail(query: query, checkID: checkID)
        }
    }

    private func complete(query: NSMetadataQuery, checkID: UInt64) {
        guard metadataQuery === query else { return }
        cancelMetadataQuery()
        stateMachine.complete(checkID, at: Date())
        publishStatus()
    }

    private func completeActiveQuery(checkID: UInt64) {
        guard let query = metadataQuery else { return }
        complete(query: query, checkID: checkID)
    }

    private func fail(query: NSMetadataQuery, checkID: UInt64) {
        guard metadataQuery === query else { return }
        cancelMetadataQuery()
        stateMachine.fail(checkID)
        publishStatus()
    }

    private func cancelMetadataQuery() {
        slowTask?.cancel()
        slowTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let queryObserver {
            NotificationCenter.default.removeObserver(queryObserver)
            self.queryObserver = nil
        }
        metadataQuery?.stop()
        metadataQuery = nil
    }

    private func networkPathChanged(isAvailable: Bool) {
        let wasAvailable = networkAvailable
        networkAvailable = isAvailable
        guard isAvailable else {
            cancelMetadataQuery()
            stateMachine.setOffline()
            publishStatus()
            return
        }
        if wasAvailable == false {
            beginCheck(force: true)
        }
    }

    private func publishStatus() {
        status = stateMachine.status
    }

    private static var markdownFilenamePredicate: NSPredicate {
        let extensions = ["md", "markdown", "mdown", "mkd"]
        return NSCompoundPredicate(orPredicateWithSubpredicates: extensions.map { fileExtension in
            NSPredicate(
                format: "%K ENDSWITH[c] %@",
                NSMetadataItemFSNameKey,
                ".\(fileExtension)"
            )
        })
    }

    private static func forcedStatus(in arguments: [String]) -> MobileCloudBrowserStatus? {
        guard let argumentIndex = arguments.firstIndex(of: "-ui-testing-cloud-status"),
              arguments.indices.contains(argumentIndex + 1) else {
            return nil
        }
        switch arguments[argumentIndex + 1] {
        case "checking":
            return .checking
        case "checked":
            return .checked(Date(timeIntervalSinceReferenceDate: 0))
        case "slow":
            return .slow
        case "offline":
            return .offline
        case "failed":
            return .failed
        case "unavailable":
            return .unavailable
        default:
            return nil
        }
    }
}

struct MobileIncomingDocument: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

@MainActor
final class MobileIncomingDocumentQueue: ObservableObject {
    @Published private(set) var current: MobileIncomingDocument?
    private var pending: [MobileIncomingDocument] = []

    func receive(_ url: URL) {
        let document = MobileIncomingDocument(url: url)
        if current == nil {
            current = document
        } else {
            pending.append(document)
        }
    }

    func complete(_ id: UUID) {
        guard current?.id == id else { return }
        current = pending.isEmpty ? nil : pending.removeFirst()
    }
}

@MainActor
final class MobileDocumentBrowserViewController: UIDocumentBrowserViewController {
    var onDidAppear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onDidAppear?()
    }
}

struct MarkdownDocumentBrowser: UIViewControllerRepresentable {
    let incomingDocument: MobileIncomingDocument?
    let onIncomingDocumentHandled: (UUID) -> Void
    let onBrowserDidAppear: () -> Void

    init(
        incomingDocument: MobileIncomingDocument? = nil,
        onIncomingDocumentHandled: @escaping (UUID) -> Void = { _ in },
        onBrowserDidAppear: @escaping () -> Void = {}
    ) {
        self.incomingDocument = incomingDocument
        self.onIncomingDocumentHandled = onIncomingDocumentHandled
        self.onBrowserDidAppear = onBrowserDidAppear
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let controller = MobileDocumentBrowserViewController(
            forOpening: [MobileMarkdownFileDocument.markdownContentType]
        )
        controller.delegate = context.coordinator
        controller.allowsDocumentCreation = false
        controller.allowsPickingMultipleItems = false
        context.coordinator.controller = controller
        context.coordinator.onBrowserDidAppear = onBrowserDidAppear
        controller.onDidAppear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            coordinator.documentBrowserDidAppear(controller)
        }
        context.coordinator.installStoreReadinessItems(on: controller)
        return controller
    }

    func updateUIViewController(
        _ controller: UIDocumentBrowserViewController,
        context: Context
    ) {
        context.coordinator.onBrowserDidAppear = onBrowserDidAppear
        context.coordinator.openIncomingDocumentIfNeeded(
            incomingDocument,
            from: controller,
            onHandled: onIncomingDocumentHandled
        )
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIDocumentBrowserViewControllerDelegate {
        typealias DocumentRevealer = (
            UIDocumentBrowserViewController,
            URL,
            Bool,
            @escaping (URL?, Error?) -> Void
        ) -> Void
        typealias DocumentPresenter = (URL, UIDocumentBrowserViewController) -> Void
        typealias RevealReadiness = @MainActor (UIDocumentBrowserViewController) -> Bool

        private struct PendingIncomingDocument {
            let document: MobileIncomingDocument
            let onHandled: (UUID) -> Void
        }

        weak var controller: UIDocumentBrowserViewController?
        var onBrowserDidAppear: () -> Void = {}
        private var activeIncomingDocumentID: UUID?
        private var lastHandledIncomingDocumentID: UUID?
        private var pendingIncomingDocument: PendingIncomingDocument?
        private let revealDocument: DocumentRevealer
        private let presentRevealedDocument: DocumentPresenter?
        private let isReadyToReveal: RevealReadiness

        override convenience init() {
            self.init(
                revealDocument: { controller, url, importIfNeeded, completion in
                    controller.revealDocument(
                        at: url,
                        importIfNeeded: importIfNeeded,
                        completion: completion
                    )
                }
            )
        }

        init(
            revealDocument: @escaping DocumentRevealer,
            presentRevealedDocument: DocumentPresenter? = nil,
            isReadyToReveal: @escaping RevealReadiness = {
                $0.viewIfLoaded?.window != nil
            }
        ) {
            self.revealDocument = revealDocument
            self.presentRevealedDocument = presentRevealedDocument
            self.isReadyToReveal = isReadyToReveal
            super.init()
        }

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

        func openIncomingDocumentIfNeeded(
            _ document: MobileIncomingDocument?,
            from controller: UIDocumentBrowserViewController,
            onHandled: @escaping (UUID) -> Void
        ) {
            guard let document,
                  activeIncomingDocumentID == nil,
                  lastHandledIncomingDocumentID != document.id else {
                return
            }
            pendingIncomingDocument = PendingIncomingDocument(
                document: document,
                onHandled: onHandled
            )
            guard isReadyToReveal(controller) else { return }

            pendingIncomingDocument = nil
            activeIncomingDocumentID = document.id

            let reveal = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.revealDocument(
                    controller,
                    document.url,
                    true
                ) { [weak self, weak controller] url, _ in
                    guard let self, let controller else { return }
                    self.finishIncomingDocument(
                        document,
                        revealedURL: url,
                        from: controller,
                        onHandled: onHandled
                    )
                }
            }

            if controller.presentedViewController == nil {
                reveal()
            } else {
                controller.dismiss(animated: false, completion: reveal)
            }
        }

        func documentBrowserDidAppear(_ controller: UIDocumentBrowserViewController) {
            onBrowserDidAppear()
            guard let pendingIncomingDocument else { return }
            openIncomingDocumentIfNeeded(
                pendingIncomingDocument.document,
                from: controller,
                onHandled: pendingIncomingDocument.onHandled
            )
        }

        @objc private func openSample() {
            guard let controller else { return }
            do {
                let url = try AppStoreSampleDocument.ensureExists()
                presentDocument(at: url, from: controller)
            } catch {
                presentError(error, from: controller, title: "Couldn’t Open Sample")
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

        private func finishIncomingDocument(
            _ document: MobileIncomingDocument,
            revealedURL: URL?,
            from controller: UIDocumentBrowserViewController,
            onHandled: (UUID) -> Void
        ) {
            guard activeIncomingDocumentID == document.id else { return }
            activeIncomingDocumentID = nil
            lastHandledIncomingDocumentID = document.id

            let urlToOpen = revealedURL ?? document.url
            if let presentRevealedDocument {
                presentRevealedDocument(urlToOpen, controller)
            } else {
                presentDocument(at: urlToOpen, from: controller)
            }
            onHandled(document.id)
        }

        private func presentError(
            _ error: Error,
            from controller: UIViewController,
            title: String
        ) {
            let alert = UIAlertController(
                title: title,
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
    - [ ] Share, save, or print its PDF from one system sheet

    | Output | Behavior |
    | :--- | :--- |
    | Preview | Continuous and selectable |
    | PDF | Searchable and paginated |

    > Your original Markdown remains unchanged.

    ```swift
    let document = "local and private"
    ```

    Use **Find** and **Share PDF** in the bottom toolbar. Manage the source file in Files, where you can also delete this sample whenever you like.
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
                    BrowserDocumentOpeningView(
                        filename: url.lastPathComponent,
                        onBack: onClose
                    )
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

private struct BrowserDocumentOpeningView: View {
    let filename: String
    let onBack: () -> Void

    var body: some View {
        ProgressView("Opening…")
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward", action: onBack)
                        .accessibilityIdentifier("browser-back-button")
                }
            }
    }
}

private struct UITestOpeningDocumentContainer: View {
    @State private var isOpening = true

    var body: some View {
        NavigationStack {
            if isOpening {
                BrowserDocumentOpeningView(filename: "Waiting in iCloud.md") {
                    isOpening = false
                }
            } else {
                Text("Returned to document browser")
                    .accessibilityIdentifier("opening-dismissed")
            }
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

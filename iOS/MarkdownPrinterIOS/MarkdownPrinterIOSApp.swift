@preconcurrency import Foundation
import MarkdownPrinterCore
import MarkdownPrinterMobileSupport
import Network
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main
struct MarkdownPrinterIOSApp: App {
    @UIApplicationDelegateAdaptor(MobileApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup(id: "documents", for: UUID.self) { $windowID in
            MarkdownPrinterRootView(windowID: $windowID)
        } defaultValue: { UUID() }
        .commands { MarkdownPrinterMobileCommands() }
    }
}

private struct MarkdownPrinterRootView: View {
    @Binding var windowID: UUID
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
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-ui-testing-dark") ? .dark : .light)
                    .background(MobileSceneAttachment(onAttach: MobileWindowRuntime.selectFixtureScene))
            } else if isOpeningUITesting {
                UITestOpeningDocumentContainer()
            } else if UIDevice.current.userInterfaceIdiom == .pad {
                IPadMarkdownWindow(windowID: $windowID)
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
        .onOpenURL { url in
            if UIDevice.current.userInterfaceIdiom != .pad { incomingDocuments.receive(url) }
        }
    }
}

struct MobileCloudBrowserStatusView: View {
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
    let onPickDocument: ((URL) -> Void)?

    init(
        incomingDocument: MobileIncomingDocument? = nil,
        onIncomingDocumentHandled: @escaping (UUID) -> Void = { _ in },
        onBrowserDidAppear: @escaping () -> Void = {},
        onPickDocument: ((URL) -> Void)? = nil
    ) {
        self.incomingDocument = incomingDocument
        self.onIncomingDocumentHandled = onIncomingDocumentHandled
        self.onBrowserDidAppear = onBrowserDidAppear
        self.onPickDocument = onPickDocument
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
        context.coordinator.onPickDocument = onPickDocument
        controller.onDidAppear = { [weak coordinator = context.coordinator, weak controller] in
            guard let coordinator, let controller else { return }
            coordinator.documentBrowserDidAppear(controller)
        }
        context.coordinator.installBrowserItems(on: controller)
        return controller
    }

    func updateUIViewController(
        _ controller: UIDocumentBrowserViewController,
        context: Context
    ) {
        context.coordinator.onBrowserDidAppear = onBrowserDidAppear
        context.coordinator.onPickDocument = onPickDocument
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
        typealias PresentedContentCheck = @MainActor (UIDocumentBrowserViewController) -> Bool
        typealias PresentedContentDismisser = @MainActor (
            UIDocumentBrowserViewController,
            @escaping () -> Void
        ) -> Void

        private struct PendingIncomingDocument {
            let document: MobileIncomingDocument
            let onHandled: (UUID) -> Void
        }

        weak var controller: UIDocumentBrowserViewController?
        var onBrowserDidAppear: () -> Void = {}
        var onPickDocument: ((URL) -> Void)?
        private var activeIncomingDocumentID: UUID?
        private var lastHandledIncomingDocumentID: UUID?
        private var pendingIncomingDocument: PendingIncomingDocument?
        private var dismissingForIncomingDocumentID: UUID?
        private let revealDocument: DocumentRevealer
        private let presentRevealedDocument: DocumentPresenter?
        private let isReadyToReveal: RevealReadiness
        private let hasPresentedContent: PresentedContentCheck
        private let dismissPresentedContent: PresentedContentDismisser

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
            },
            hasPresentedContent: @escaping PresentedContentCheck = {
                $0.presentedViewController != nil
            },
            dismissPresentedContent: @escaping PresentedContentDismisser = {
                controller,
                completion in
                controller.dismiss(animated: false, completion: completion)
            }
        ) {
            self.revealDocument = revealDocument
            self.presentRevealedDocument = presentRevealedDocument
            self.isReadyToReveal = isReadyToReveal
            self.hasPresentedContent = hasPresentedContent
            self.dismissPresentedContent = dismissPresentedContent
            super.init()
        }

        func installBrowserItems(on controller: UIDocumentBrowserViewController) {
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
            if let onPickDocument { onPickDocument(url); return }
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

            if hasPresentedContent(controller) {
                guard dismissingForIncomingDocumentID != document.id else { return }
                dismissingForIncomingDocumentID = document.id
                dismissPresentedContent(controller) { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.dismissingForIncomingDocumentID = nil
                    self.openIncomingDocumentIfNeeded(
                        document,
                        from: controller,
                        onHandled: onHandled
                    )
                }
                return
            }
            guard isReadyToReveal(controller) else { return }

            pendingIncomingDocument = nil
            activeIncomingDocumentID = document.id

            revealDocument(
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

        func documentBrowserDidAppear(_ controller: UIDocumentBrowserViewController) {
            onBrowserDidAppear()
            guard let pendingIncomingDocument else { return }
            openIncomingDocumentIfNeeded(
                pendingIncomingDocument.document,
                from: controller,
                onHandled: pendingIncomingDocument.onHandled
            )
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

struct UITestMarkdownDocumentContainer: View {
    @State private var linkedDocuments: [URL] = []
    @State private var isDocumentOpen = true
    @StateObject private var session: MobileDocumentSession

    init() {
        let fixture = Self.makeFixture()
        // SwiftUI can rebuild this value while retaining the original session.
        // Never clear a cache that the retained session still owns.
        let cacheDirectory = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("UITestRemoteImageCache-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteImageCache(directoryURL: cacheDirectory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 70)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 70))
        }
        let downloader = UITestRemoteImageDownloader(
            cache: cache,
            imageData: image.pngData() ?? Data()
        )
        _session = StateObject(
            wrappedValue: MobileDocumentSession(
                document: fixture.document,
                sourceURL: fixture.url,
                remoteImageCache: cache,
                remoteImageDownloader: downloader
            )
        )
    }

    var body: some View {
        if isDocumentOpen {
            NavigationStack(path: $linkedDocuments) {
                MarkdownViewerView(
                    session: session,
                    linkedDocuments: $linkedDocuments,
                    onClose: { isDocumentOpen = false }
                )
                    .navigationDestination(for: URL.self) { url in
                        LinkedMarkdownDocumentView(url: url, linkedDocuments: $linkedDocuments)
                    }
            }
        } else {
            Text("Returned to document browser")
        }
    }

    static func makeFixture() -> (document: MarkdownDocument, url: URL) {
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

        for (folder, title, word, other) in [("one", "First Project", "alpha", "two"), ("two", "Second Project", "beta", "one")] {
            let file = directory.appendingPathComponent("\(folder)/Report.md")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("# \(title)\n\nAn independent \(word) document.\n\n[Other Project](../\(other)/Report.md)".utf8).write(to: file)
        }

        let sourceURL = directory.appendingPathComponent("fixture.md")
        var markdown = """
        # iPhone Viewer Fixture

        The exact search phrase appears here. The exact search phrase appears twice.

        [Linked page](linked.markdown) and [Apple website](https://www.apple.com/).

        [Missing linked file](missing.md) demonstrates a recoverable provider error.

        [Permission-gated page](permission-required.md) exercises explicit Files authorization.

        ![Network artwork](https://example.com/image.png)

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

        [^viewer]: Footnotes remain searchable and printable.
        """
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-windows") {
            markdown = markdown.replacingOccurrences(of: "![Network artwork](https://example.com/image.png)", with: "[First Project](one/Report.md)")
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-headings") {
            markdown = "# iPhone Viewer Fixture\n\n" + (2...6).map {
                "\(String(repeating: "#", count: $0)) Heading level \($0)\n\nBody text with **strong** text for comparison."
            }.joined(separator: "\n\n")
            markdown += "\n\n### A longer heading that wraps naturally across multiple lines\n\nFollowing paragraph."
        }
        try? Data(markdown.utf8).write(to: sourceURL, options: .atomic)
        let document = (try? MarkdownDocument.load(from: sourceURL))
            ?? MarkdownDocument(title: "fixture", markdown: markdown)
        return (document, sourceURL)
    }
}

private actor UITestRemoteImageDownloader: RemoteImageDownloading {
    let cache: RemoteImageCache
    let imageData: Data

    init(cache: RemoteImageCache, imageData: Data) {
        self.cache = cache
        self.imageData = imageData
    }

    func download(source: String) async throws -> URL {
        try cache.store(imageData, for: source)
    }
}

struct LinkedMarkdownDocumentView: View {
    @Environment(\.mobileDocumentWindow) private var documentWindow
    @State private var attempt = 0
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
                ContentUnavailableView {
                    Label("Couldn’t Open Markdown", systemImage: "doc.text.magnifyingglass")
                } description: { Text(error) } actions: {
                    Button("Retry") { attempt += 1 }
                    if let documentWindow { Button("Browse", action: documentWindow.browse) }
                }
            } else {
                ProgressView("Opening…")
            }
        }
        .task(id: "\(url.absoluteString)#\(attempt)") {
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

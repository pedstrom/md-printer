import Combine
import MarkdownPrinterCore
import MarkdownPrinterMobileSupport
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
enum MobileWindowRuntime {
    static let router = MobileDocumentWindowRouter()
    static let restorationStore = MobileWindowRestorationStore()
    static var resetTestSessions = Set<String>()
    static var selectedFixtureScene = false

    static func selectFixtureScene(_ scene: UIWindowScene) {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing"), !selectedFixtureScene else { return }
        selectedFixtureScene = true
        // Each single-reader UI test starts independently of saved multiwindow tests.
        for session in UIApplication.shared.openSessions where session != scene.session {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: scene.session))
    }
}

final class MobileApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        for session in sceneSessions {
            MobileWindowRuntime.router.discard(sessionID: session.persistentIdentifier)
            MobileWindowRuntime.restorationStore.discard(sessionID: session.persistentIdentifier)
        }
    }
}

private struct MobileWindowStateKey: EnvironmentKey {
    static let defaultValue: MobileDocumentWindowState? = nil
}

private struct MobileOpenWindowKey: EnvironmentKey {
    static let defaultValue: ((URL) -> Void)? = nil
}

extension EnvironmentValues {
    var mobileDocumentWindow: MobileDocumentWindowState? {
        get { self[MobileWindowStateKey.self] }
        set { self[MobileWindowStateKey.self] = newValue }
    }
    var openMarkdownWindow: ((URL) -> Void)? {
        get { self[MobileOpenWindowKey.self] }
        set { self[MobileOpenWindowKey.self] = newValue }
    }
}

final class MobileReaderCommands: ObservableObject {
    enum Action { case find, next, previous, share, print }
    var send: (Action) -> Void = { _ in }
    func find() { send(.find) }
    func next() { send(.next) }
    func previous() { send(.previous) }
    func share() { send(.share) }
    func print() { send(.print) }
}

struct MobileReaderCommandRequest: Equatable {
    let id = UUID()
    let action: MobileReaderCommands.Action
}

final class MobileSceneCommands: ObservableObject {
    var newWindow: () -> Void = {}
    var open: () -> Void = {}
    var close: () -> Void = {}
}

private struct ReaderCommandsKey: FocusedValueKey { typealias Value = MobileReaderCommands }
private struct SceneCommandsKey: FocusedValueKey { typealias Value = MobileSceneCommands }
extension FocusedValues {
    var markdownReaderCommands: MobileReaderCommands? {
        get { self[ReaderCommandsKey.self] }
        set { self[ReaderCommandsKey.self] = newValue }
    }
    var markdownSceneCommands: MobileSceneCommands? {
        get { self[SceneCommandsKey.self] }
        set { self[SceneCommandsKey.self] = newValue }
    }
}

struct MarkdownPrinterMobileCommands: Commands {
    @FocusedValue(\.markdownReaderCommands) private var reader
    @FocusedValue(\.markdownSceneCommands) private var scene
    var body: some Commands {
        CommandMenu("Document") {
            Button("New Window") { scene?.newWindow() }.keyboardShortcut("n").disabled(scene == nil)
            Button("Open…") { scene?.open() }.keyboardShortcut("o").disabled(scene == nil)
            Divider()
            Button("Close Window") { scene?.close() }.keyboardShortcut("w").disabled(scene == nil)
            Button("Share PDF…") { reader?.share() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(reader == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print PDF…") { reader?.print() }.keyboardShortcut("p").disabled(reader == nil)
        }
        CommandMenu("Find") {
            Button("Find…") { reader?.find() }.keyboardShortcut("f").disabled(reader == nil)
            Button("Find Next") { reader?.next() }.keyboardShortcut("g").disabled(reader == nil)
            Button("Find Previous") { reader?.previous() }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(reader == nil)
        }
    }
}

struct IPadMarkdownWindow: View {
    @Binding var windowID: UUID
    @StateObject private var sceneCommands = MobileSceneCommands()
    @StateObject private var window = MobileDocumentWindowState()
    @ObservedObject private var router = MobileWindowRuntime.router
    @StateObject private var cloudStatus = MobileCloudBrowserStatusMonitor()
    @SceneStorage("markdown-window-restoration-v1") private var savedState = ""
    @State private var snapshot = MobileWindowRestoration()
    @State private var restored = false
    @State private var showingOpen = false
    @State private var openingError: String?
    @State private var windowScene: UIWindowScene?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var phase

    private var id: UUID { windowID }

    var body: some View {
        Group {
            if !restored {
                ProgressView("Restoring window…")
            } else if let url = window.rootURL {
                IPadDocumentContainer(url: url, window: window, onBrowse: window.browse)
                    .id(url)
            } else {
                VStack(spacing: 0) {
                    MobileCloudBrowserStatusView(status: cloudStatus.status, onRetry: cloudStatus.retry)
                    MarkdownDocumentBrowser(onBrowserDidAppear: cloudStatus.refreshIfNeeded, onPickDocument: route)
                }
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .environment(\.mobileDocumentWindow, window)
        .environment(\.openMarkdownWindow, route)
        .background(MobileSceneAttachment { scene in
            windowScene = scene
            router.register(id, urls: window.documentURLs, sessionID: scene.session.persistentIdentifier)
        })
        .focusedSceneValue(\.markdownSceneCommands, sceneCommands)
        .fileImporter(isPresented: $showingOpen, allowedContentTypes: [MobileMarkdownFileDocument.markdownContentType], allowsMultipleSelection: false) { result in
            do { if let url = try result.get().first { route(url) } }
            catch { openingError = error.localizedDescription }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            acceptDrops(providers)
        }
        .onOpenURL(perform: route)
        .onAppear {
            sceneCommands.newWindow = { openWindow(id: "documents", value: UUID()) }
            sceneCommands.open = { showingOpen = true }
            sceneCommands.close = closeWindow
            restoreIfNeeded()
        }
        .onChange(of: windowScene?.session.persistentIdentifier) { _, _ in restoreIfNeeded() }
        .onDisappear {
            sceneCommands.newWindow = {}
            sceneCommands.open = {}
            sceneCommands.close = {}
        }
        .onChange(of: router.requests[id]?.id) { _, _ in consumeRequest() }
        .onChange(of: window.documentURLs) { _, urls in
            router.register(id, urls: urls)
            snapshot.documents = urls.map { MobileDocumentBookmark(url: $0) }
            save()
        }
        .onChange(of: window.readers) { _, readers in snapshot.readers = readers; save() }
        .onChange(of: phase) { _, value in
            if value == .active { cloudStatus.refreshIfNeeded() }
            if value == .background { save() }
        }
        .alert("Couldn’t Open Markdown", isPresented: Binding(get: { openingError != nil }, set: { if !$0 { openingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(openingError ?? "") }
    }

    private func restoreIfNeeded() {
        guard !restored, let sessionID = windowScene?.session.persistentIdentifier else { return }
        let arguments = ProcessInfo.processInfo.arguments
        let fixture = arguments.contains("-ui-testing-windows") ? UITestMarkdownDocumentContainer.makeFixture().url : nil
        let reset = (arguments.contains("-ui-testing-reset-window") || arguments.contains("-ui-testing-store-readiness")) && MobileWindowRuntime.resetTestSessions.insert(sessionID).inserted
        let state = reset ? MobileWindowRestoration() : MobileWindowRuntime.restorationStore.load(sessionID: sessionID) ?? MobileWindowRestoration.decode(savedState)
        snapshot = state
        window.restore(state)
        restored = true
        router.register(id, urls: window.documentURLs, sessionID: sessionID)
        consumeRequest()
        cloudStatus.start()
        if let fixture, window.rootURL == nil { route(fixture) }
    }

    private func route(_ url: URL) {
        guard let target = router.route(url, from: id, multipleWindows: true) else {
            openingError = "Choose a Markdown file (.md, .markdown, .mdown, or .mkd)."
            return
        }
        if target == id { consumeRequest() }
        else if let sessionID = router.sessionID(for: target),
                let session = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == sessionID }) {
            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session)) { error in
                openingError = error.localizedDescription
            }
        } else { openWindow(id: "documents", value: target) }
    }

    private func consumeRequest() {
        guard restored, let request = router.requests[id] else { return }
        window.open(request.url)
        router.complete(request, in: id)
    }

    private func save() {
        guard restored else { return }
        var current = snapshot
        current.readers = window.readers
        savedState = current.encoded
        if let sessionID = windowScene?.session.persistentIdentifier {
            try? MobileWindowRuntime.restorationStore.save(current, sessionID: sessionID)
        }
    }

    private func closeWindow() {
        guard let scene = windowScene else { return }
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil) { error in
            openingError = error.localizedDescription
        }
    }

    private func acceptDrops(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        for provider in files {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in
                    if let url { route(url) }
                    else { openingError = error?.localizedDescription ?? "The file could not be opened. Try choosing it from Files." }
                }
            }
        }
        return !files.isEmpty
    }
}

private struct IPadDocumentContainer: View {
    let url: URL
    @ObservedObject var window: MobileDocumentWindowState
    let onBrowse: () -> Void
    @StateObject private var session = MobileDocumentSession()
    @State private var attempt = 0
    @State private var showingPermission = false
    @State private var permissionError: String?

    var body: some View {
        NavigationStack(path: $window.linkedDocuments) {
            Group {
                if session.document != nil {
                    MarkdownViewerView(session: session, linkedDocuments: $window.linkedDocuments, onClose: onBrowse)
                } else {
                    Group {
                        if let error = session.errorMessage {
                            ContentUnavailableView {
                                Label(session.permissionRequest == nil ? "Couldn’t Open Markdown" : "Folder Access Needed", systemImage: "doc.text.magnifyingglass")
                            } description: { Text(permissionError ?? error) } actions: {
                                Button("Retry") { attempt += 1 }
                                if session.permissionRequest != nil { Button("Allow Folder Access…") { showingPermission = true } }
                                Button("Browse", action: onBrowse)
                            }
                        } else { ProgressView("Opening…") }
                    }
                    .navigationTitle(url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Browse", systemImage: "chevron.backward", action: onBrowse) } }
                }
            }
            .navigationDestination(for: URL.self) { url in
                LinkedMarkdownDocumentView(url: url, linkedDocuments: $window.linkedDocuments)
            }
        }
        .task(id: attempt) { await session.load(url: url) }
        .sheet(isPresented: $showingPermission) {
            if let request = session.permissionRequest {
                LinkedMarkdownFolderPicker(request: request) { url in
                    showingPermission = false
                    guard let url else { return }
                    do { try session.authorizeDirectory(url); permissionError = nil; attempt += 1 }
                    catch { permissionError = error.localizedDescription }
                }
            }
        }
    }
}

struct MobileSceneAttachment: UIViewRepresentable {
    var onAttach: (UIWindowScene) -> Void
    func makeUIView(context: Context) -> AttachmentView { AttachmentView() }
    func updateUIView(_ view: AttachmentView, context: Context) { view.onAttach = onAttach }
    final class AttachmentView: UIView {
        var onAttach: ((UIWindowScene) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { DispatchQueue.main.async { [weak self] in self?.onAttach?(scene) } }
        }
    }
}

struct PDFPresentationAnchor: UIViewRepresentable {
    let presenter: MobilePDFPresentationController
    func makeUIView(context: Context) -> AnchorView { AnchorView(presenter: presenter) }
    func updateUIView(_ view: AnchorView, context: Context) { presenter.anchor = view }
    final class AnchorView: UIView {
        let presenter: MobilePDFPresentationController
        init(presenter: MobilePDFPresentationController) {
            self.presenter = presenter
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            presenter.anchor = self
            presenter.updateAnchor()
        }
    }
}

struct MobileFindField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSearch: () -> Void
    let onPrint: () -> Void
    let onPreviousSearch: () -> Void
    func makeUIView(context: Context) -> MobileFindTextField { MobileFindTextField() }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MobileFindTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(44, uiView.intrinsicContentSize.height))
    }
    func updateUIView(_ field: MobileFindTextField, context: Context) {
        if field.text != text { field.text = text }
        field.onTextChange = { text = $0 }
        field.onFocusChange = { if isFocused != $0 { isFocused = $0 } }
        field.onSearch = onSearch
        field.onPrint = onPrint
        field.onPreviousSearch = onPreviousSearch
        field.setFocused(isFocused)
    }
}

struct MobileDocumentKeys: UIViewRepresentable {
    let commands: MobileReaderCommands
    func makeUIView(context: Context) -> MobileDocumentKeyView {
        let view = MobileDocumentKeyView()
        return view
    }
    func updateUIView(_ view: MobileDocumentKeyView, context: Context) {
        view.onCommand = { key in
            switch key {
            case "f": commands.find()
            case "g": commands.next()
            case "previous": commands.previous()
            case "s": commands.share()
            case "p": commands.print()
            default: break
            }
        }
        DispatchQueue.main.async { [weak view] in view?.activateIfNeeded() }
    }
}

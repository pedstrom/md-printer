import AppKit
import MarkdownPrinterCore
import SwiftUI
import UniformTypeIdentifiers

public struct MarkdownPrinterView: View {
    @ObservedObject private var session: DocumentSession
    @ObservedObject private var exportPreferences: ExportPreferences
    private let activityCoordinator: ApplicationActivityCoordinator
    private let openFiles: ([URL]) -> Void
    @State private var isDropTargeted = false
    @StateObject private var searchController = PDFSearchController()

    public init(
        session: DocumentSession,
        exportPreferences: ExportPreferences,
        activityCoordinator: ApplicationActivityCoordinator,
        openFiles: @escaping ([URL]) -> Void
    ) {
        self.session = session
        self.exportPreferences = exportPreferences
        self.activityCoordinator = activityCoordinator
        self.openFiles = openFiles
    }

    public var body: some View {
        Group {
            if session.hasDocument {
                preview
            } else {
                welcome
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .focusedSceneObject(searchController)
        .background(StableWindowTitleView(title: session.title))
        .background(PDFSearchPanelPresenter(controller: searchController))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10]))
                    .padding(18)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: acceptDrop)
        .toolbar {
            ToolbarItemGroup {
                Button(action: saveDocument) {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!session.hasDocument)
                Button(action: printDocument) {
                    Label("Print", systemImage: "printer")
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!session.hasDocument)
            }
        }
        .alert("Markdown Printer", isPresented: errorPresented) {
            Button("OK") { session.clearError() }
        } message: {
            Text(session.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var preview: some View {
        Group {
            if let snapshot = session.renderedSnapshot {
                let exportFormat = exportPreferences.defaultFormat
                PDFPreviewView(
                    data: snapshot.pdfData,
                    revision: snapshot.revision,
                    exportFormat: exportFormat,
                    fileName: session.suggestedFileName(for: exportFormat),
                    searchController: searchController,
                    exportData: { try session.exportData(as: exportFormat) },
                    openURL: openLink,
                    onDragError: { session.report(error: $0) }
                )
            }
        }
    }

    private func openLink(_ url: URL) {
        if let markdownURL = MarkdownLinkTarget.fileURL(from: url) {
            openFiles([markdownURL])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)
            Text("Markdown Printer")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Drop Markdown files here to turn them into polished, printable PDFs.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Choose Markdown File…", action: openDocument)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("Supports headings, emphasis, underlining, lists, tables, code, links, and local images.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.clearError() } }
        )
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.title = "Open Markdown"
        panel.prompt = "Open"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = markdownTypes
        guard panel.runModal() == .OK else { return }
        openFiles(panel.urls)
    }

    private func saveDocument() {
        activityCoordinator.performBlockingOperation {
            let defaultFormat = exportPreferences.defaultFormat
            let controller = ExportSavePanelController(
                defaultFormat: defaultFormat,
                suggestedFileName: session.suggestedFileName(for: defaultFormat)
            )
            guard let selection = controller.runModal() else { return }
            do {
                try session.save(to: selection.url, as: selection.format)
            } catch {
                session.report(error: error)
            }
        }
    }

    private func printDocument() {
        activityCoordinator.performBlockingOperation {
            do {
                try session.printOperation().run()
            } catch {
                session.report(error: error)
            }
        }
    }

    private func acceptDrop(providers: [NSItemProvider]) -> Bool {
        guard DroppedFileLoader.accepts(providers) else { return false }
        Task {
            let urls = await DroppedFileLoader.urls(from: providers)
            await MainActor.run {
                openFiles(urls)
            }
        }
        return true
    }

    private var markdownTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let markdown = UTType(filenameExtension: "md") { types.insert(markdown, at: 0) }
        if let markdown = UTType(filenameExtension: "markdown") { types.insert(markdown, at: 0) }
        return types
    }
}

private struct PDFSearchPanelView: View {
    @ObservedObject var controller: PDFSearchController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PDFSearchField(
                text: $controller.query,
                focusRequest: controller.focusRequest,
                onSubmit: controller.findNext,
                onCancel: controller.dismiss
            )
            .frame(height: 22)
            HStack(spacing: 10) {
                Text(controller.statusText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 84, alignment: .leading)
                Spacer()
                Button("Previous", action: controller.findPrevious)
                    .disabled(!controller.canNavigate)
                Button("Next", action: controller.findNext)
                    .disabled(!controller.canNavigate)
                Button("Done", action: controller.dismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .focusedSceneObject(controller)
    }
}

private struct PDFSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UInt64
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.setAccessibilityLabel("Find text")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.focus(
            field,
            request: focusRequest,
            selectQuery: PDFSearchFocusPolicy.shouldSelectQuery(text)
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void
        var onCancel: () -> Void
        private var handledFocusRequest: UInt64?

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func focus(
            _ field: NSSearchField,
            request: UInt64,
            selectQuery: Bool
        ) {
            guard handledFocusRequest != request else { return }
            handledFocusRequest = request
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                if selectQuery {
                    field.currentEditor()?.selectAll(nil)
                }
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            onCancel()
            return true
        }

        @objc
        func submit(_ sender: NSSearchField) {
            onSubmit()
        }
    }
}

private struct PDFSearchPanelPresenter: NSViewRepresentable {
    @ObservedObject var controller: PDFSearchController

    func makeNSView(context: Context) -> PDFSearchPanelHostView {
        PDFSearchPanelHostView(controller: controller)
    }

    func updateNSView(_ view: PDFSearchPanelHostView, context: Context) {
        view.update(controller: controller)
    }

    static func dismantleNSView(_ view: PDFSearchPanelHostView, coordinator: Void) {
        view.invalidate()
    }
}

@MainActor
private final class PDFSearchPanelHostView: NSView, NSWindowDelegate {
    private weak var controller: PDFSearchController?
    private weak var documentWindow: NSWindow?
    private var panel: PDFSearchPanel?
    private var hostingController: NSHostingController<PDFSearchPanelView>?
    private var lastFocusRequest = UInt64.max

    init(controller: PDFSearchController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        documentWindow = window
        synchronizePanel()
    }

    func update(controller: PDFSearchController) {
        self.controller = controller
        synchronizePanel()
    }

    func invalidate() {
        if let panel, let parent = panel.parent {
            parent.removeChildWindow(panel)
        }
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hostingController = nil
        documentWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        controller?.dismiss()
    }

    private func synchronizePanel() {
        guard let controller else { return }
        guard controller.isPresented else {
            panel?.orderOut(nil)
            return
        }
        guard let documentWindow = window ?? documentWindow else { return }

        let panel = panel ?? makePanel(controller: controller, relativeTo: documentWindow)
        if panel.parent !== documentWindow {
            panel.parent?.removeChildWindow(panel)
            documentWindow.addChildWindow(panel, ordered: .above)
        }
        let shouldFocus = !panel.isVisible || lastFocusRequest != controller.focusRequest
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        if shouldFocus {
            lastFocusRequest = controller.focusRequest
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makePanel(
        controller: PDFSearchController,
        relativeTo documentWindow: NSWindow
    ) -> PDFSearchPanel {
        let content = PDFSearchPanelView(controller: controller)
        let hostingController = NSHostingController(rootView: content)
        let contentSize = hostingController.view.fittingSize
        let panel = PDFSearchPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find"
        panel.contentViewController = hostingController
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.searchController = controller
        position(panel, relativeTo: documentWindow)
        self.panel = panel
        self.hostingController = hostingController
        return panel
    }

    private func position(_ panel: NSPanel, relativeTo documentWindow: NSWindow) {
        let visibleFrame = documentWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: documentWindow.frame.maxX - panel.frame.width - 24,
            y: documentWindow.frame.maxY - panel.frame.height - 52
        )
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - panel.frame.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
    }
}

@MainActor
private final class PDFSearchPanel: NSPanel {
    weak var searchController: PDFSearchController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, modifiers.isEmpty {
            searchController?.dismiss()
            return true
        }
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("f", [.command]):
            searchController?.present()
            return true
        case ("g", [.command]):
            searchController?.findNext()
            return true
        case ("g", [.command, .shift]):
            searchController?.findPrevious()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

package struct PDFSearchCommands: Commands {
    @FocusedObject private var controller: PDFSearchController?

    package init() { }

    package var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Menu("Find") {
                Button("Find…") {
                    controller?.present()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(controller?.canPresent != true)

                Button("Find Next") {
                    controller?.findNext()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(controller?.canNavigate != true)

                Button("Find Previous") {
                    controller?.findPrevious()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(controller?.canNavigate != true)
            }
        }
        CommandGroup(replacing: .textEditing) { }
    }
}

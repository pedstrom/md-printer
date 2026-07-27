import AppKit
import MarkdownPrinterCore
import SwiftUI
import UniformTypeIdentifiers

public struct MarkdownPrinterView: View {
    @ObservedObject private var session: DocumentSession
    private let openFiles: ([URL]) -> Void
    @State private var isDropTargeted = false

    public init(session: DocumentSession, openFiles: @escaping ([URL]) -> Void) {
        self.session = session
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
        .navigationTitle(session.title)
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
                Button(action: savePDF) {
                    Label("Save PDF", systemImage: "square.and.arrow.down")
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
            if let pdfData = session.renderedPDFData {
                PDFPreviewView(
                    data: pdfData,
                    fileName: session.suggestedPDFFileName,
                    openURL: openLink
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

    private func savePDF() {
        let panel = NSSavePanel()
        panel.title = "Save PDF"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.suggestedPDFFileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.savePDF(to: url)
        } catch {
            session.report(error: error)
        }
    }

    private func printDocument() {
        do {
            try session.printOperation().run()
        } catch {
            session.report(error: error)
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

import AppKit
import MarkdownPrinterCore
import SwiftUI
import UniformTypeIdentifiers

public struct MarkdownPrinterView: View {
    @ObservedObject private var session: DocumentSession
    @State private var isDropTargeted = false

    public init(session: DocumentSession) {
        self.session = session
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
                .disabled(!session.hasDocument)
                Button(action: printDocument) {
                    Label("Print", systemImage: "printer")
                }
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
                PDFPreviewView(data: pdfData)
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)
            Text("Markdown Printer")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Drop a Markdown file here to turn it into a polished, printable PDF.")
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
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = markdownTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.load(url: url)
    }

    private func savePDF() {
        let panel = NSSavePanel()
        panel.title = "Save PDF"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.title + ".pdf"
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
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
            guard error == nil,
                  let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in session.load(url: url) }
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

import MarkdownPrinterCore
import MarkdownPrinterMobileSupport
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MarkdownViewerView: View {
    @ObservedObject var session: MobileDocumentSession
    @Binding var linkedDocuments: [URL]
    var onClose: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase

    @State private var toolbarsVisible = true
    @State private var searchPresented = false
    @State private var searchOptions = MarkdownSearchOptions()
    @State private var selectedMatchIndex = 0
    @State private var requestedAnchor: String?
    @State private var showingInfo = false
    @State private var showingRename = false
    @State private var renameValue = ""
    @State private var showingMove = false
    @State private var showingShare = false
    @State private var shareItems: [Any] = []
    @State private var sharedTemporaryURL: URL?
    @State private var showingExporter = false
    @State private var exportDocument: MobilePDFFileDocument?
    @State private var actionError: String?

    private var matches: [MarkdownSearchMatch] {
        session.presentation?.searchIndex.matches(for: searchOptions) ?? []
    }

    private var selectedMatch: MarkdownSearchMatch? {
        guard !matches.isEmpty else { return nil }
        return matches[min(max(selectedMatchIndex, 0), matches.count - 1)]
    }

    var body: some View {
        Group {
            if let presentation = session.presentation {
                MobileMarkdownContentView(
                    presentation: presentation,
                    selectedMatch: selectedMatch,
                    requestedAnchor: requestedAnchor,
                    onOpenURL: open,
                    onTapBackground: toggleToolbars
                )
            } else {
                ContentUnavailableView(
                    "No Markdown Document",
                    systemImage: "doc.text",
                    description: Text("Choose a Markdown file from the document browser.")
                )
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(toolbarsVisible || searchPresented ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward", action: onClose)
                        .accessibilityIdentifier("browser-back-button")
                }
            }
            ToolbarItem(placement: .principal) {
                filenameMenu
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if toolbarsVisible || searchPresented {
                HStack(spacing: 14) {
                if searchPresented {
                    searchToolbar
                } else {
                    viewingToolbar
                }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 50)
                .background(.bar)
                .overlay(alignment: .top) {
                    Divider()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .searchable(
            text: $searchOptions.query,
            isPresented: $searchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Find in Markdown"
        )
        .onSubmit(of: .search) { selectNextMatch() }
        .onChange(of: searchOptions.query) { _, _ in resetSearchSelection() }
        .onChange(of: searchOptions.matchCase) { _, _ in resetSearchSelection() }
        .onChange(of: searchOptions.wholeWord) { _, _ in resetSearchSelection() }
        .onChange(of: searchPresented) { _, presented in
            if presented {
                toolbarsVisible = true
                resetSearchSelection()
            } else {
                searchOptions.query = ""
                selectedMatchIndex = 0
                requestedAnchor = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await session.refreshIfChanged() }
        }
        .sheet(isPresented: $showingInfo) {
            DocumentInfoView(metadata: session.metadata)
        }
        .sheet(isPresented: $showingShare, onDismiss: cleanUpSharedFile) {
            ActivityView(items: shareItems)
                .accessibilityIdentifier("share-sheet")
        }
        .sheet(isPresented: $showingMove) {
            if let sourceURL = session.sourceURL {
                MoveDocumentPicker(sourceURL: sourceURL) { result in
                    showingMove = false
                    switch result {
                    case let .success(url): session.updateSourceURL(url)
                    case let .failure(error): actionError = error.localizedDescription
                    }
                }
            }
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .pdf,
            defaultFilename: pdfFilename
        ) { result in
            if case let .failure(error) = result { actionError = error.localizedDescription }
            exportDocument = nil
        }
        .alert("Rename Markdown File", isPresented: $showingRename) {
            TextField("Filename", text: $renameValue)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameDocument() }
        } message: {
            Text("The Markdown extension is preserved if you don’t enter one.")
        }
        .alert(
            "Markdown Printer",
            isPresented: Binding(
                get: { actionError != nil || session.errorMessage != nil },
                set: { showing in
                    if !showing {
                        actionError = nil
                        session.clearError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? session.errorMessage ?? "An unknown error occurred.")
        }
        .overlay {
            if session.pdfState == .preparing {
                PDFProgressOverlay(cancel: session.cancelPDFGeneration)
            }
        }
        .onDisappear {
            session.cancelPDFGeneration()
            cleanUpSharedFile()
        }
    }

    private var filenameMenu: some View {
        Menu {
            Button("Rename", systemImage: "pencil") {
                renameValue = session.sourceURL?.lastPathComponent ?? session.title
                showingRename = true
            }
            .disabled(!session.fileActions.canRename)

            Button("Move", systemImage: "folder") { showingMove = true }
                .disabled(!session.fileActions.canMove)

            Button("Duplicate", systemImage: "plus.square.on.square") { duplicateDocument() }
                .disabled(!session.fileActions.canDuplicate)

            if let reason = session.fileActions.unavailableReason {
                Text(reason)
            }

            Divider()

            Button("Share Original Markdown", systemImage: "doc") { shareOriginal() }
                .disabled(session.sourceURL == nil)
            Button("Export PDF", systemImage: "square.and.arrow.down") { exportPDF() }
            Button("Print", systemImage: "printer") { printPDF() }
        } label: {
            HStack(spacing: 4) {
                Text(session.sourceURL?.lastPathComponent ?? session.title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
        }
        .accessibilityLabel("Document actions")
        .accessibilityIdentifier("document-actions-button")
    }

    @ViewBuilder
    private var viewingToolbar: some View {
        Button {
            showingInfo = true
        } label: {
            AdaptiveToolbarLabel("Info", systemImage: "info.circle")
        }
        .accessibilityIdentifier("info-button")

        Spacer()

        Button {
            sharePDF()
        } label: {
            AdaptiveToolbarLabel("Share PDF", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share-pdf-button")

        Spacer()

        Button {
            searchPresented = true
        } label: {
            AdaptiveToolbarLabel("Search", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier("search-button")
    }

    @ViewBuilder
    private var searchToolbar: some View {
        Menu {
            Toggle("Match Case", isOn: $searchOptions.matchCase)
            Toggle("Whole Word", isOn: $searchOptions.wholeWord)
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Search options")

        Text(matchSummary)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 58)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

        Spacer()

        Button(action: selectPreviousMatch) {
            Image(systemName: "chevron.up")
        }
        .disabled(matches.isEmpty)
        .accessibilityLabel("Previous result")

        Button(action: selectNextMatch) {
            Image(systemName: "chevron.down")
        }
        .disabled(matches.isEmpty)
        .accessibilityLabel("Next result")

        Button { searchPresented = false } label: {
            AdaptiveToolbarLabel("Done", systemImage: "xmark.circle")
        }
    }

    private var matchSummary: String {
        guard !searchOptions.query.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No Results" }
        return "\(selectedMatchIndex + 1) of \(matches.count)"
    }

    private var pdfFilename: String {
        let source = session.sourceURL?.deletingPathExtension().lastPathComponent ?? session.title
        let sanitized = source.replacingOccurrences(of: "/", with: "-")
        return (sanitized.isEmpty ? "Markdown Document" : sanitized) + ".pdf"
    }

    private func toggleToolbars() {
        guard !searchPresented else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            toolbarsVisible.toggle()
        }
    }

    private func resetSearchSelection() {
        selectedMatchIndex = 0
        requestedAnchor = selectedMatch?.blockID
    }

    private func selectNextMatch() {
        guard !matches.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex + 1) % matches.count
        requestedAnchor = selectedMatch?.blockID
    }

    private func selectPreviousMatch() {
        guard !matches.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex - 1 + matches.count) % matches.count
        requestedAnchor = selectedMatch?.blockID
    }

    private func open(_ url: URL) {
        if case let .definition(label)? = MobileFootnoteLink.target(from: url) {
            requestedAnchor = "footnote-\(label)"
            return
        }
        if let markdownURL = MarkdownLinkTarget.fileURL(from: url) {
            linkedDocuments.append(markdownURL)
            return
        }
        UIApplication.shared.open(url)
    }

    private func renameDocument() {
        guard let sourceURL = session.sourceURL else { return }
        do {
            let url = try MobileFileOperator().rename(sourceURL, to: renameValue)
            session.updateSourceURL(url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func duplicateDocument() {
        guard let sourceURL = session.sourceURL else { return }
        do {
            _ = try MobileFileOperator().duplicate(sourceURL)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func shareOriginal() {
        guard let sourceURL = session.sourceURL else { return }
        shareItems = [sourceURL]
        showingShare = true
    }

    private func sharePDF() {
        preparePDF { data in
            do {
                let url = try MobilePDFShareStore.write(data: data, filename: pdfFilename)
                sharedTemporaryURL = url
                shareItems = [MobilePDFActivityItem(data: data, fileURL: url)]
                showingShare = true
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func exportPDF() {
        preparePDF { data in
            exportDocument = MobilePDFFileDocument(data: data)
            showingExporter = true
        }
    }

    private func printPDF() {
        preparePDF { data in
            PrintPresenter.present(data: data, jobName: pdfFilename)
        }
    }

    private func preparePDF(completion: @escaping (Data) -> Void) {
        Task {
            do {
                completion(try await session.pdfData())
            } catch is CancellationError {
                return
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func cleanUpSharedFile() {
        guard let sharedTemporaryURL else { return }
        try? FileManager.default.removeItem(at: sharedTemporaryURL.deletingLastPathComponent())
        self.sharedTemporaryURL = nil
        shareItems = []
    }
}

private struct AdaptiveToolbarLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: systemImage)
                    .font(.title3)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .accessibilityLabel(title)
    }
}

private struct PDFProgressOverlay: View {
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Preparing PDF…")
                .font(.headline)
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

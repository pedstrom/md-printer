import MarkdownPrinterCore
import MarkdownPrinterMobileSupport
import SwiftUI
import UIKit

struct MarkdownViewerView: View {
    @ObservedObject var session: MobileDocumentSession
    @Binding var linkedDocuments: [URL]
    var onClose: (() -> Void)? = nil
    var onNavigateBack: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase

    @State private var toolbarsVisible = true
    @State private var searchOptions = MarkdownSearchOptions()
    @State private var selectedMatchIndex = 0
    @State private var requestedAnchor: String?
    @State private var showingShare = false
    @State private var shareItems: [Any] = []
    @State private var sharedTemporaryURL: URL?
    @State private var actionError: String?
    @FocusState private var searchFieldFocused: Bool

    private var matches: [MarkdownSearchMatch] {
        session.presentation?.searchIndex.matches(for: searchOptions) ?? []
    }

    private var selectedMatch: MarkdownSearchMatch? {
        guard !matches.isEmpty else { return nil }
        return matches[min(max(selectedMatchIndex, 0), matches.count - 1)]
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-ui-testing")
    }

    private var backSwipeAction: (() -> Void)? {
        onNavigateBack ?? onClose
    }

    var body: some View {
        Group {
            if let presentation = session.presentation {
                MobileMarkdownContentView(
                    presentation: presentation,
                    selectedMatch: selectedMatch,
                    requestedAnchor: requestedAnchor,
                    remoteImageCache: session.remoteImageCache,
                    remoteImageRevision: session.remoteImageRevision,
                    downloadingRemoteImageSources: session.downloadingRemoteImageSources,
                    onDownloadRemoteImage: downloadRemoteImage,
                    onDownloadAllRemoteImages: downloadAllRemoteImages,
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
        .simultaneousGesture(leadingBackSwipeGesture)
        .overlay(alignment: .trailing) {
            if let backSwipeAction {
                MobileBackSwipeEdgeView(edge: .trailing, onNavigateBack: backSwipeAction)
            }
        }
        .navigationTitle(session.sourceURL?.lastPathComponent ?? session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(toolbarsVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward", action: onClose)
                        .accessibilityIdentifier("browser-back-button")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: sharePDF) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share PDF")
                .accessibilityIdentifier("share-pdf-button")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if toolbarsVisible {
                searchBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .top) {
                    Divider()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onSubmit(of: .search) { selectNextMatch() }
        .onChange(of: searchOptions.query) { _, _ in resetSearchSelection() }
        .onChange(of: searchOptions.matchCase) { _, _ in resetSearchSelection() }
        .onChange(of: searchOptions.wholeWord) { _, _ in resetSearchSelection() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await session.refreshIfChanged() }
        }
        .task(id: session.documentRevision) {
            await session.loadRemoteImagesIfAvailable()
        }
        .sheet(isPresented: $showingShare, onDismiss: cleanUpSharedFile) {
            if isUITesting {
                ShareSheetTestView(filename: pdfFilename)
            } else {
                ActivityView(items: shareItems)
                    .accessibilityIdentifier("share-sheet")
            }
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
            searchFieldFocused = false
            session.cancelPDFGeneration()
            cleanUpSharedFile()
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in Markdown", text: $searchOptions.query)
                    .focused($searchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("find-field")
                if !searchOptions.query.isEmpty {
                    Button {
                        searchOptions.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            if searchFieldFocused {
                HStack(spacing: 18) {
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

                    Button("Done") {
                        searchFieldFocused = false
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var matchSummary: String {
        guard !searchOptions.query.isEmpty else { return "" }
        guard !matches.isEmpty else { return "No Results" }
        return "\(selectedMatchIndex + 1) of \(matches.count)"
    }

    private var leadingBackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onEnded { value in
                guard value.startLocation.x <= 30 else { return }
                let predicted = value.predictedEndTranslation
                let travel = abs(predicted.width) > abs(value.translation.width)
                    ? predicted
                    : value.translation
                guard MobileBackSwipePolicy.shouldNavigateBack(
                    from: .leading,
                    horizontalTravel: travel.width,
                    verticalTravel: travel.height
                ) else { return }
                backSwipeAction?()
            }
    }

    private var pdfFilename: String {
        let source = session.sourceURL?.deletingPathExtension().lastPathComponent ?? session.title
        let sanitized = source.replacingOccurrences(of: "/", with: "-")
        return (sanitized.isEmpty ? "Markdown Document" : sanitized) + ".pdf"
    }

    private func toggleToolbars() {
        if searchFieldFocused {
            searchFieldFocused = false
            return
        }
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
        if let source = RemoteImageActionURL.downloadSource(from: url) {
            downloadRemoteImage(source)
            return
        }
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

    private func downloadRemoteImage(_ source: String) {
        Task { await session.downloadRemoteImage(source: source) }
    }

    private func downloadAllRemoteImages() {
        Task { await session.downloadAllRemoteImages() }
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

private struct ShareSheetTestView: View {
    let filename: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "doc.richtext")
                    .font(.largeTitle)
                Text("PDF Ready to Share")
                    .font(.headline)
                Text(filename)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Share PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct MobileBackSwipeEdgeView: View {
    let edge: MobileBackSwipeEdge
    let onNavigateBack: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 14)
                    .onEnded { value in
                        let predicted = value.predictedEndTranslation
                        let travel = abs(predicted.width) > abs(value.translation.width)
                            ? predicted
                            : value.translation
                        guard MobileBackSwipePolicy.shouldNavigateBack(
                            from: edge,
                            horizontalTravel: travel.width,
                            verticalTravel: travel.height
                        ) else { return }
                        onNavigateBack()
                    }
            )
            .padding(.vertical, 56)
            .accessibilityHidden(true)
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

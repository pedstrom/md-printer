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
    @State private var searchPresented = false
    @State private var searchOptions = MarkdownSearchOptions()
    @State private var selectedMatchIndex = 0
    @State private var requestedAnchor: String?
    @State private var showingShare = false
    @State private var shareItems: [Any] = []
    @State private var sharedTemporaryURL: URL?
    @State private var actionError: String?

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
        .overlay(alignment: .leading) {
            if let onNavigateBack {
                MobileBackSwipeEdgeView(edge: .leading, onNavigateBack: onNavigateBack)
            }
        }
        .overlay(alignment: .trailing) {
            if let onNavigateBack {
                MobileBackSwipeEdgeView(edge: .trailing, onNavigateBack: onNavigateBack)
            }
        }
        .navigationTitle(session.sourceURL?.lastPathComponent ?? session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(toolbarsVisible || searchPresented ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward", action: onClose)
                        .accessibilityIdentifier("browser-back-button")
                }
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
        .modifier(
            MarkdownSearchPresentationModifier(
                query: $searchOptions.query,
                isPresented: $searchPresented
            )
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
            session.cancelPDFGeneration()
            cleanUpSharedFile()
        }
    }

    @ViewBuilder
    private var viewingToolbar: some View {
        Button {
            searchPresented = true
        } label: {
            AdaptiveToolbarLabel("Find", systemImage: "magnifyingglass")
        }
        .accessibilityIdentifier("search-button")

        Spacer()

        Button {
            sharePDF()
        } label: {
            AdaptiveToolbarLabel("Share PDF", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("share-pdf-button")
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

private struct MarkdownSearchPresentationModifier: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPresented {
            content.searchable(
                text: $query,
                isPresented: $isPresented,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Find in Markdown"
            )
        } else {
            content
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

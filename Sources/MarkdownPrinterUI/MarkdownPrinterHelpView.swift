import SwiftUI

package struct MarkdownPrinterHelpView: View {
    @ObservedObject private var navigator: MarkdownPrinterHelpNavigator

    package init(navigator: MarkdownPrinterHelpNavigator) {
        self.navigator = navigator
    }

    package var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    Text("Markdown Printer Help")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)

                    ForEach(MarkdownPrinterHelpContent.sections) { section in
                        HelpSectionView(section: section)
                            .id(section.id)
                    }
                }
                .padding(32)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .textSelection(.enabled)
            .onAppear {
                proxy.scrollTo(navigator.destination.sectionID, anchor: .top)
            }
            .onChange(of: navigator.requestRevision) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(navigator.destination.sectionID, anchor: .top)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HelpSectionView: View {
    let section: MarkdownPrinterHelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let prompt = section.copyablePrompt {
                HelpPromptView(prompt: prompt)
            }

            if section.id == .keyboardShortcuts {
                VStack(spacing: 0) {
                    ForEach(MarkdownPrinterHelpContent.shortcuts) { shortcut in
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            Text(shortcut.action)
                            Spacer(minLength: 20)
                            Text(shortcut.keys)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.vertical, 7)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(shortcut.accessibilityLabel)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct HelpPromptView: View {
    let prompt: MarkdownPrinterHelpCopyablePrompt
    @StateObject private var copyController = MarkdownPrinterHelpPromptCopyController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: prompt.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: prompt.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
            }

            Button {
                copyController.copy(prompt.text)
            } label: {
                Label(
                    copyController.isCopied ? "Copied" : "Copy prompt",
                    systemImage: copyController.isCopied ? "checkmark" : "doc.on.doc"
                )
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("Copy the complete prompt")
            .accessibilityHint("Copies the entire setup prompt as plain text to paste into Codex.")

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: prompt.exampleTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: prompt.example)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

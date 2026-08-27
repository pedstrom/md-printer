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

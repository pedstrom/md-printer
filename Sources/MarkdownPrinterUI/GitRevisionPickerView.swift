import SwiftUI

/// Thin native sheet composition; all work and lifecycle state live in its controller.
package struct GitRevisionPickerView: View {
    @ObservedObject var controller: GitRevisionPickerController
    @FocusState private var isRevisionListFocused: Bool
    let cancel: () -> Void

    package var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compare with Git Version")
                .font(.headline)
            Text("Choose an earlier version of this document.")
                .foregroundStyle(.secondary)
            if controller.isLoading {
                ProgressView("Loading document history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.revisions.isEmpty {
                Text(controller.errorMessage == nil
                     ? "No committed versions of this document were found."
                     : "Document history could not be loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $controller.selectedRevisionID) {
                    ForEach(controller.revisions) { revision in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(revision.committerDate, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                                Spacer()
                                Text(revision.abbreviatedID)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text(revision.subject)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        // Let List select on the first click without waiting
                        // for the double-click recognizer to fail.
                        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in
                            controller.compare(revisionID: revision.id)
                        })
                        .tag(revision.id)
                    }
                }
                .disabled(controller.isComparing)
                .focused($isRevisionListFocused)
                .onAppear { isRevisionListFocused = true }
                .accessibilityIdentifier("git-revision-list")
            }
            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                if controller.isComparing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Compare", action: controller.compare)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canCompare)
                    .accessibilityIdentifier("compare-git-revision")
            }
        }
        .padding(24)
        .frame(width: 580, height: 440)
        .background(GitRevisionPickerWindowAttachment(controller: controller))
    }
}

private struct GitRevisionPickerWindowAttachment: NSViewRepresentable {
    let controller: GitRevisionPickerController
    func makeNSView(context: Context) -> HostView { HostView(controller: controller) }
    func updateNSView(_ view: HostView, context: Context) { view.controller = controller; view.attachWindow() }

    final class HostView: NSView {
        var controller: GitRevisionPickerController
        init(controller: GitRevisionPickerController) {
            self.controller = controller
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachWindow() }
        func attachWindow() { controller.attachWindow(window?.sheetParent ?? window) }
    }
}

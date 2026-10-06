import AppKit
import Combine

@MainActor
package final class MarkdownPrinterHelpPromptCopyController: ObservableObject {
    @Published package private(set) var isCopied = false

    private let writeText: (String) -> Bool
    private let feedbackDuration: Duration
    private var feedbackTask: Task<Void, Never>?

    package init(
        pasteboard: NSPasteboard = .general,
        feedbackDuration: Duration = .seconds(2),
        writeText: ((String) -> Bool)? = nil
    ) {
        self.writeText = writeText ?? { text in
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
        self.feedbackDuration = feedbackDuration
    }

    @discardableResult
    package func copy(_ text: String) -> Bool {
        feedbackTask?.cancel()
        isCopied = writeText(text)
        guard isCopied else { return false }

        let duration = feedbackDuration
        feedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            self?.isCopied = false
        }
        return true
    }

    deinit {
        feedbackTask?.cancel()
    }
}

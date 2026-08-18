import SwiftUI

enum PDFSearchDirection: Equatable {
    case next
    case previous
}

struct PDFSearchSummary: Equatable {
    let matchCount: Int
    let selectedMatchIndex: Int?

    static let empty = PDFSearchSummary(matchCount: 0, selectedMatchIndex: nil)
}

enum PDFSearchFocusPolicy {
    static func shouldSelectQuery(_ query: String) -> Bool {
        !query.isEmpty
    }
}

@MainActor
protocol PDFSearchTarget: AnyObject {
    var isSearchAvailable: Bool { get }

    func performSearch(
        for query: String,
        showingAllMatches: Bool
    ) -> PDFSearchSummary
    func moveSearchSelection(
        _ direction: PDFSearchDirection,
        showingAllMatches: Bool
    ) -> PDFSearchSummary
    func setShowsAllSearchMatches(_ showsAllMatches: Bool)
}

@MainActor
final class PDFSearchController: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            updateSummary(
                target?.performSearch(for: query, showingAllMatches: isPresented) ?? .empty
            )
        }
    }
    @Published private(set) var matchCount = 0
    @Published private(set) var selectedMatchIndex: Int?
    @Published private(set) var isPresented = false
    @Published private(set) var focusRequest = UInt64(0)
    @Published private(set) var canPresent = false

    private weak var target: (any PDFSearchTarget)?

    var canNavigate: Bool {
        canPresent && matchCount > 0 && selectedMatchIndex != nil
    }

    var statusText: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        guard let selectedMatchIndex, matchCount > 0 else {
            return "No matches"
        }
        return "\(selectedMatchIndex + 1) of \(matchCount)"
    }

    func attach(to target: any PDFSearchTarget) {
        if self.target === target {
            canPresent = target.isSearchAvailable
            return
        }
        self.target?.setShowsAllSearchMatches(false)
        self.target = target
        canPresent = target.isSearchAvailable
        updateSummary(target.performSearch(for: query, showingAllMatches: isPresented))
    }

    func detach(from target: any PDFSearchTarget) {
        guard disconnect(from: target) else { return }
        resetDetachedState()
    }

    func detachForDismantling(from target: any PDFSearchTarget) {
        guard disconnect(from: target) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.target == nil else { return }
            self.resetDetachedState()
        }
    }

    private func disconnect(from target: any PDFSearchTarget) -> Bool {
        guard self.target === target else { return false }
        target.setShowsAllSearchMatches(false)
        self.target = nil
        return true
    }

    private func resetDetachedState() {
        canPresent = false
        updateSummary(.empty)
        isPresented = false
    }

    func present() {
        guard canPresent else { return }
        isPresented = true
        focusRequest &+= 1
        target?.setShowsAllSearchMatches(true)
    }

    func dismiss() {
        isPresented = false
        target?.setShowsAllSearchMatches(false)
    }

    func findNext() {
        move(.next)
    }

    func findPrevious() {
        move(.previous)
    }

    func target(_ target: any PDFSearchTarget, didUpdate summary: PDFSearchSummary) {
        guard self.target === target else { return }
        canPresent = target.isSearchAvailable
        updateSummary(summary)
    }

    private func move(_ direction: PDFSearchDirection) {
        guard canNavigate else { return }
        updateSummary(
            target?.moveSearchSelection(direction, showingAllMatches: isPresented) ?? .empty
        )
    }

    private func updateSummary(_ summary: PDFSearchSummary) {
        matchCount = summary.matchCount
        selectedMatchIndex = summary.selectedMatchIndex
    }
}

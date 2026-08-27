import SwiftUI

struct PDFViewingState: Equatable {
    let isAvailable: Bool
    let canZoomIn: Bool
    let canZoomOut: Bool
    let canGoToPreviousPage: Bool
    let canGoToNextPage: Bool

    static let unavailable = PDFViewingState(
        isAvailable: false,
        canZoomIn: false,
        canZoomOut: false,
        canGoToPreviousPage: false,
        canGoToNextPage: false
    )
}

@MainActor
protocol PDFViewingTarget: AnyObject {
    var viewingState: PDFViewingState { get }

    func showActualSize()
    func fitCurrentPage()
    func zoomIn()
    func zoomOut()
    func goToPreviousPage()
    func goToNextPage()
}

@MainActor
final class PDFViewingController: ObservableObject {
    @Published private(set) var state = PDFViewingState.unavailable

    private weak var target: (any PDFViewingTarget)?

    var isAvailable: Bool { state.isAvailable }
    var canZoomIn: Bool { state.canZoomIn }
    var canZoomOut: Bool { state.canZoomOut }
    var canGoToPreviousPage: Bool { state.canGoToPreviousPage }
    var canGoToNextPage: Bool { state.canGoToNextPage }

    func attach(to target: any PDFViewingTarget) {
        self.target = target
        refresh()
    }

    func detach(from target: any PDFViewingTarget) {
        guard self.target === target else { return }
        self.target = nil
        state = .unavailable
    }

    func detachForDismantling(from target: any PDFViewingTarget) {
        guard self.target === target else { return }
        self.target = nil
        Task { @MainActor [weak self] in
            guard let self, self.target == nil else { return }
            self.state = .unavailable
        }
    }

    func targetDidChange(_ target: any PDFViewingTarget) {
        guard self.target === target else { return }
        refresh()
    }

    func actualSize() {
        guard isAvailable else { return }
        target?.showActualSize()
    }

    func fitPage() {
        guard isAvailable else { return }
        target?.fitCurrentPage()
    }

    func zoomIn() {
        guard canZoomIn else { return }
        target?.zoomIn()
    }

    func zoomOut() {
        guard canZoomOut else { return }
        target?.zoomOut()
    }

    func previousPage() {
        guard canGoToPreviousPage else { return }
        target?.goToPreviousPage()
    }

    func nextPage() {
        guard canGoToNextPage else { return }
        target?.goToNextPage()
    }

    private func refresh() {
        state = target?.viewingState ?? .unavailable
    }
}

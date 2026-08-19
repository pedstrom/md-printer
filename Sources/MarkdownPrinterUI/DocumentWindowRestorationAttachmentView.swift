import AppKit
import SwiftUI

private struct DocumentWindowRestorationCoordinatorKey: EnvironmentKey {
    static let defaultValue: DocumentWindowRestorationCoordinator? = nil
}

extension EnvironmentValues {
    package var documentWindowRestorationCoordinator: DocumentWindowRestorationCoordinator? {
        get { self[DocumentWindowRestorationCoordinatorKey.self] }
        set { self[DocumentWindowRestorationCoordinatorKey.self] = newValue }
    }
}

package struct DocumentWindowRestorationAttachmentView: NSViewRepresentable {
    let coordinator: DocumentWindowRestorationCoordinator

    package init(coordinator: DocumentWindowRestorationCoordinator) {
        self.coordinator = coordinator
    }

    package func makeNSView(context: Context) -> DocumentWindowRestorationHostView {
        DocumentWindowRestorationHostView(coordinator: coordinator)
    }

    package func updateNSView(
        _ view: DocumentWindowRestorationHostView,
        context: Context
    ) {
        view.coordinator = coordinator
        view.attachCurrentWindow()
    }
}

@MainActor
package final class DocumentWindowRestorationHostView: NSView {
    package var coordinator: DocumentWindowRestorationCoordinator
    private weak var attachedWindow: NSWindow?

    package init(coordinator: DocumentWindowRestorationCoordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachCurrentWindow()
    }

    package func attachCurrentWindow() {
        guard attachedWindow !== window else { return }
        if attachedWindow != nil {
            coordinator.attach(window: nil)
        }
        attachedWindow = window
        coordinator.attach(window: window)
    }
}

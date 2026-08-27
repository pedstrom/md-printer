import AppKit
import MarkdownPrinterCore

package enum NativePageSetupResult: Equatable {
    case cancelled
    case accepted(DocumentPageSetup)
    case useDefault
}

@MainActor
package final class PageSetupDefaultAccessoryController: NSViewController {
    package let useDefaultButton: NSButton
    private let action: (NSWindow?) -> Void

    package init(action: @escaping (NSWindow?) -> Void) {
        self.action = action
        useDefaultButton = NSButton(
            title: "Use Default Page Setup",
            target: nil,
            action: nil
        )
        super.init(nibName: nil, bundle: nil)
        useDefaultButton.target = self
        useDefaultButton.action = #selector(useDefaultPageSetup)
        useDefaultButton.setAccessibilityLabel("Use Default Page Setup")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    package override func loadView() {
        let container = NSView()
        useDefaultButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(useDefaultButton)
        NSLayoutConstraint.activate([
            useDefaultButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            useDefaultButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            useDefaultButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            useDefaultButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])
        view = container
    }

    @objc private func useDefaultPageSetup() {
        action(useDefaultButton.window)
    }
}

@MainActor
package final class PageSetupPresentationContext {
    package var requestedDefault = false
    private var didComplete = false
    private let completion: (NativePageSetupResult) -> Void

    package init(completion: @escaping (NativePageSetupResult) -> Void) {
        self.completion = completion
    }

    package func complete(_ result: NativePageSetupResult) {
        guard !didComplete else { return }
        didComplete = true
        completion(result)
    }
}

@MainActor
package final class NativePageSetupPresenter {
    package typealias Presentation = @MainActor (
        DocumentPageSetup,
        Bool,
        NSWindow,
        @escaping (NativePageSetupResult) -> Void
    ) -> Void

    private let presentation: Presentation?
    private var activeSheets: [NSPageLayout] = []

    package init(presentation: Presentation? = nil) {
        self.presentation = presentation
    }

    package func present(
        _ pageSetup: DocumentPageSetup,
        allowsUseDefault: Bool = false,
        for window: NSWindow,
        completion: @escaping (NativePageSetupResult) -> Void
    ) {
        if let presentation {
            presentation(pageSetup, allowsUseDefault, window, completion)
            return
        }
        let printInfo = Self.printInfo(for: pageSetup)
        let pageLayout = NSPageLayout()
        let context = PageSetupPresentationContext(completion: completion)
        if allowsUseDefault {
            let accessory = PageSetupDefaultAccessoryController { sheet in
                context.requestedDefault = true
                guard let sheet, let parent = sheet.sheetParent
                else {
                    context.complete(.useDefault)
                    return
                }
                parent.endSheet(sheet, returnCode: .cancel)
            }
            pageLayout.addAccessoryController(accessory)
        }
        activeSheets.append(pageLayout)
        pageLayout.beginSheet(using: printInfo, on: window) { [weak self, weak pageLayout] result in
            if context.requestedDefault {
                context.complete(.useDefault)
            } else if result == .changed {
                context.complete(.accepted(Self.pageSetup(from: printInfo)))
            } else {
                context.complete(.cancelled)
            }
            // AppKit can continue unwinding the sheet callback after invoking
            // the handler. Retain the page-layout controller through the next
            // main-loop turn.
            DispatchQueue.main.async {
                guard let pageLayout else { return }
                self?.activeSheets.removeAll { $0 === pageLayout }
            }
        }
    }

    package static func printInfo(for pageSetup: DocumentPageSetup) -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperName = NSPrinter.PaperName(rawValue: pageSetup.paperName)
        info.paperSize = pageSetup.pageSize
        info.orientation = pageSetup.orientation == .landscape ? .landscape : .portrait
        info.scalingFactor = pageSetup.scale
        let margins = DocumentPageSetup.fixedMargins
        info.topMargin = margins.top
        info.leftMargin = margins.left
        info.bottomMargin = margins.bottom
        info.rightMargin = margins.right
        return info
    }

    package static func pageSetup(from printInfo: NSPrintInfo) -> DocumentPageSetup {
        DocumentPageSetup(
            paperName: printInfo.paperName?.rawValue ?? DocumentPageSetup.letter.paperName,
            paperSize: printInfo.paperSize,
            orientation: printInfo.orientation == .landscape ? .landscape : .portrait,
            scale: printInfo.scalingFactor
        )
    }

}

@MainActor
package final class DocumentPageActionController: ObservableObject {
    package typealias Printing = @MainActor (DocumentSession) throws -> Void
    package typealias ClearingPageSetup = @MainActor (DocumentSession) throws -> Void

    private weak var session: DocumentSession?
    private let activityCoordinator: ApplicationActivityCoordinator
    private let pageSetupPresenter: NativePageSetupPresenter
    private let printing: Printing
    private let clearingPageSetup: ClearingPageSetup

    package init(
        session: DocumentSession,
        activityCoordinator: ApplicationActivityCoordinator,
        pageSetupPresenter: NativePageSetupPresenter? = nil,
        printing: Printing? = nil,
        clearingPageSetup: ClearingPageSetup? = nil
    ) {
        self.session = session
        self.activityCoordinator = activityCoordinator
        self.pageSetupPresenter = pageSetupPresenter ?? NativePageSetupPresenter()
        self.printing = printing ?? { session in
            _ = try session.printOperation().run()
        }
        self.clearingPageSetup = clearingPageSetup ?? { session in
            try session.clearPageSetupOverride()
        }
    }

    package var canPageSetup: Bool { session?.hasDocument == true }
    package var canPrint: Bool { session?.hasDocument == true }

    package func showPageSetup(window: NSWindow? = nil) {
        guard let session,
              session.hasDocument,
              let window = window ?? NSApp.keyWindow
        else { return }
        activityCoordinator.beginBlockingOperation()
        pageSetupPresenter.present(
            session.activePageSetup,
            allowsUseDefault: session.hasExplicitPageSetup,
            for: window
        ) { [weak self, weak session] result in
            defer { self?.activityCoordinator.endBlockingOperation() }
            guard let self, let session else { return }
            do {
                switch result {
                case .cancelled:
                    return
                case let .accepted(pageSetup):
                    try session.applyExplicitPageSetup(pageSetup)
                case .useDefault:
                    try clearingPageSetup(session)
                }
            } catch {
                session.report(error: error)
            }
        }
    }

    package func printDocument() {
        guard let session, session.hasDocument else { return }
        activityCoordinator.performBlockingOperation {
            do {
                try printing(session)
            } catch {
                session.report(error: error)
            }
        }
    }
}

import AppKit
import MarkdownPrinterCore

@MainActor
package final class NativePageSetupPresenter {
    package typealias Presentation = @MainActor (
        DocumentPageSetup,
        NSWindow,
        @escaping (DocumentPageSetup?) -> Void
    ) -> Void

    private let presentation: Presentation?
    private var activeSheets: [NSPageLayout] = []

    package init(presentation: Presentation? = nil) {
        self.presentation = presentation
    }

    package func present(
        _ pageSetup: DocumentPageSetup,
        for window: NSWindow,
        completion: @escaping (DocumentPageSetup?) -> Void
    ) {
        if let presentation {
            presentation(pageSetup, window, completion)
            return
        }
        let printInfo = Self.printInfo(for: pageSetup)
        let pageLayout = NSPageLayout()
        activeSheets.append(pageLayout)
        pageLayout.beginSheet(using: printInfo, on: window) { [weak self, weak pageLayout] result in
            completion(result == .changed ? Self.pageSetup(from: printInfo) : nil)
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

    private weak var session: DocumentSession?
    private let activityCoordinator: ApplicationActivityCoordinator
    private let pageSetupPresenter: NativePageSetupPresenter
    private let printing: Printing

    package init(
        session: DocumentSession,
        activityCoordinator: ApplicationActivityCoordinator,
        pageSetupPresenter: NativePageSetupPresenter? = nil,
        printing: Printing? = nil
    ) {
        self.session = session
        self.activityCoordinator = activityCoordinator
        self.pageSetupPresenter = pageSetupPresenter ?? NativePageSetupPresenter()
        self.printing = printing ?? { session in
            _ = try session.printOperation().run()
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
        pageSetupPresenter.present(session.activePageSetup, for: window) {
            [weak self, weak session] acceptedPageSetup in
            defer { self?.activityCoordinator.endBlockingOperation() }
            guard let session, let acceptedPageSetup else { return }
            do {
                try session.applyExplicitPageSetup(acceptedPageSetup)
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

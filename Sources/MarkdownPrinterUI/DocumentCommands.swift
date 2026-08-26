import AppKit
import SwiftUI

package struct ShareToolbarButton: NSViewRepresentable {
    let controller: DocumentActionController

    package func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    package func makeNSView(context: Context) -> NSButton {
        let image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
            ?? NSImage()
        let button = NSButton(image: image, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("Share")
        controller.attachToolbarShareAnchor(button)
        return button
    }

    package func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.controller = controller
        button.isEnabled = controller.canShare
        button.toolTip = controller.shareCommandTitle.replacingOccurrences(of: "…", with: "")
        controller.attachToolbarShareAnchor(button)
    }

    package static func dismantleNSView(_ button: NSButton, coordinator: Coordinator) {
        coordinator.controller?.attachToolbarShareAnchor(nil)
        button.target = nil
    }

    @MainActor
    package final class Coordinator: NSObject {
        weak var controller: DocumentActionController?

        init(controller: DocumentActionController) {
            self.controller = controller
        }

        @objc func share(_ sender: NSButton) {
            controller?.share(anchorView: sender)
        }
    }
}

package struct DocumentFileCommands: Commands {
    @FocusedObject private var controller: DocumentActionController?
    @FocusedObject private var pageController: DocumentPageActionController?

    package init() {}

    package var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save As…") {
                controller?.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(controller?.canSaveAs != true)
        }

        CommandGroup(replacing: .importExport) {
            Button("Show in Finder") {
                controller?.showInFinder()
            }
            .disabled(controller?.canShowInFinder != true)

            Button(controller?.shareCommandTitle ?? "Share PDF…") {
                controller?.share()
            }
            .disabled(controller?.canShare != true)
        }

        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") {
                pageController?.showPageSetup()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(pageController?.canPageSetup != true)

            Button("Print…") {
                pageController?.printDocument()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(pageController?.canPrint != true)
        }
    }
}

package struct PDFThumbnailCommands: Commands {
    @FocusedObject private var controller: PDFThumbnailSidebarController?

    package init() {}

    package var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(controller?.commandTitle ?? "Show Thumbnails") {
                controller?.toggle()
            }
            .disabled(controller?.canToggle != true)
        }
    }
}

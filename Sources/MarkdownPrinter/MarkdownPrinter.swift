import MarkdownPrinterUI
import SwiftUI

@main
struct MarkdownPrinterApp: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self) private var applicationDelegate
    @StateObject private var session = DocumentSession()

    var body: some Scene {
        WindowGroup("Markdown Printer") {
            MarkdownPrinterView(session: session)
                .onOpenURL { session.load(url: $0) }
        }
        .defaultSize(width: 760, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

import MarkdownPrinterUI
import SwiftUI

@main
struct MarkdownPrinterApp: App {
    @StateObject private var session = DocumentSession()

    var body: some Scene {
        WindowGroup(session.title) {
            MarkdownPrinterView(session: session)
                .onOpenURL { session.load(url: $0) }
        }
        .defaultSize(width: 760, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

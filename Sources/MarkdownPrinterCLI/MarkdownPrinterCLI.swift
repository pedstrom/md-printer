import Foundation
import MarkdownPrinterCore

@main
struct MarkdownPrinterCLI {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            fail("Usage: MarkdownPrinterCLI <input.md> <output.pdf>")
        }

        do {
            let inputURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
            let outputURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let document = try MarkdownDocument.load(from: inputURL)
            let renderer = MarkdownRenderer()
            try PDFExporter(configuration: renderer.configuration)
                .write(renderer.render(document: document), to: outputURL)
            print("Rendered \(outputURL.path)")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(1)
    }
}

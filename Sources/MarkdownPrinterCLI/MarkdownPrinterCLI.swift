import AppKit
import Foundation
import MarkdownPrinterCore

@main
struct MarkdownPrinterCLI {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2, arguments[0] == "--benchmark" {
            guard let targetBytes = Int(arguments[1]), targetBytes > 0 else {
                fail("Benchmark size must be a positive byte count.")
            }
            do {
                try await runBenchmark(targetBytes: targetBytes)
            } catch {
                fail(error.localizedDescription)
            }
            return
        }

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

    @MainActor
    private static func runBenchmark(targetBytes: Int) async throws {
        let markdown = benchmarkMarkdown(targetBytes: targetBytes)
        let pdfPhase = try autoreleasepool {
            let parser = MarkdownParser()
            let parseStart = timestamp()
            let blocks = parser.parse(markdown)
            let parseSeconds = elapsed(since: parseStart)

            let renderer = MarkdownRenderer()
            let attributedStart = timestamp()
            let attributed = renderer.render(blocks: blocks)
            let attributedSeconds = elapsed(since: attributedStart)

            let pdfStart = timestamp()
            let pdfBytes = try PDFExporter(configuration: renderer.configuration)
                .pdfData(from: attributed).count
            return BenchmarkPDFPhase(
                blockCount: blocks.count,
                attributedCharacters: attributed.length,
                pdfBytes: pdfBytes,
                parseSeconds: parseSeconds,
                attributedSeconds: attributedSeconds,
                pdfSeconds: elapsed(since: pdfStart)
            )
        }

        let quickLookPhase = autoreleasepool {
            let quickLookStart = timestamp()
            let blocks = MarkdownParser().parse(markdown)
            let configuration = RendererConfiguration(
                bodyFontSize: 13,
                headingFontSizes: HeadingTypography.quickLookSizes,
                pageSize: CGSize(width: 680, height: 1_000),
                pageMargins: NSEdgeInsets(),
                maximumImageWidth: 680,
                codeBlockPadding: 10
            )
            let characters = MarkdownRenderer(configuration: configuration)
                .render(blocks: blocks).length
            return BenchmarkQuickLookPhase(
                characters: characters,
                seconds: elapsed(since: quickLookStart)
            )
        }

        let wordPhase = try autoreleasepool {
            let parser = MarkdownParser()
            let parseStart = timestamp()
            let blocks = parser.parse(markdown)
            let parseSeconds = elapsed(since: parseStart)
            let renderer = MarkdownRenderer()
            let attributedStart = timestamp()
            let attributed = renderer.render(blocks: blocks)
            let attributedSeconds = elapsed(since: attributedStart)
            let wordStart = timestamp()
            let bytes = try WordExporter().wordData(from: attributed).count
            let wordSeconds = elapsed(since: wordStart)
            return BenchmarkWordPhase(
                bytes: bytes,
                seconds: wordSeconds,
                totalSeconds: parseSeconds + attributedSeconds + wordSeconds
            )
        }

        let responsiveness = try await measureMainActorResponsiveness(markdown: markdown)
        let report = BenchmarkReport(
            sourceBytes: markdown.utf8.count,
            blockCount: pdfPhase.blockCount,
            attributedCharacters: pdfPhase.attributedCharacters,
            quickLookCharacters: quickLookPhase.characters,
            pdfBytes: pdfPhase.pdfBytes,
            wordBytes: wordPhase.bytes,
            parseSeconds: pdfPhase.parseSeconds,
            attributedSeconds: pdfPhase.attributedSeconds,
            pdfSeconds: pdfPhase.pdfSeconds,
            pdfTotalSeconds: pdfPhase.parseSeconds + pdfPhase.attributedSeconds + pdfPhase.pdfSeconds,
            quickLookSeconds: quickLookPhase.seconds,
            wordSeconds: wordPhase.seconds,
            wordTotalSeconds: wordPhase.totalSeconds,
            mainActorMaxStallSeconds: responsiveness
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    @MainActor
    private static func measureMainActorResponsiveness(markdown: String) async throws -> Double {
        let sampler = MainActorStallSampler()
        let samplingTask = Task { await sampler.sample() }
        let renderTask = Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let parser = MarkdownParser()
                let blocks = parser.parse(markdown)
                let renderer = MarkdownRenderer()
                return BenchmarkAttributedText(value: renderer.render(blocks: blocks))
            }
        }
        let attributed = await renderTask.value.value
        _ = try await PDFExporter().pdfDataAsync(from: attributed).count
        samplingTask.cancel()
        await samplingTask.value
        return sampler.maximumGapSeconds
    }

    private static func benchmarkMarkdown(targetBytes: Int) -> String {
        let chunk = """
        ## A representative section

        Paragraph text with *emphasis*, **strong text**, `inline code`, an [inline link](https://example.com), and an &amp; entity.

        - First list item
          - Nested list item with a [reference][destination]
        - Second list item\u{20}\u{20}
          with a hard break

        > A quoted paragraph with enough prose to wrap naturally in both the paginated PDF and continuous Quick Look layouts.

        | Name | Value | Notes |
        | :--- | ---: | :---: |
        | Alpha | 42 | Local and deterministic |

        ```swift
        let value = "performance"
        ```

        [destination]: https://example.com/reference "Reference title"

        """
        let repetitions = max(1, (targetBytes + chunk.utf8.count - 1) / chunk.utf8.count)
        return "# Performance Fixture\n\n" + Array(repeating: chunk, count: repetitions).joined()
    }

    private static func timestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(timestamp() - start) / 1_000_000_000
    }
}

private struct BenchmarkAttributedText: @unchecked Sendable {
    let value: NSAttributedString
}

private struct BenchmarkPDFPhase {
    let blockCount: Int
    let attributedCharacters: Int
    let pdfBytes: Int
    let parseSeconds: Double
    let attributedSeconds: Double
    let pdfSeconds: Double
}

private struct BenchmarkQuickLookPhase {
    let characters: Int
    let seconds: Double
}

private struct BenchmarkWordPhase {
    let bytes: Int
    let seconds: Double
    let totalSeconds: Double
}

private struct BenchmarkReport: Codable {
    let sourceBytes: Int
    let blockCount: Int
    let attributedCharacters: Int
    let quickLookCharacters: Int
    let pdfBytes: Int
    let wordBytes: Int
    let parseSeconds: Double
    let attributedSeconds: Double
    let pdfSeconds: Double
    let pdfTotalSeconds: Double
    let quickLookSeconds: Double
    let wordSeconds: Double
    let wordTotalSeconds: Double
    let mainActorMaxStallSeconds: Double
}

@MainActor
private final class MainActorStallSampler {
    private(set) var maximumGapSeconds: Double = 0

    func sample() async {
        var previous = DispatchTime.now().uptimeNanoseconds
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let current = DispatchTime.now().uptimeNanoseconds
            maximumGapSeconds = max(
                maximumGapSeconds,
                Double(current - previous) / 1_000_000_000
            )
            previous = current
        }
    }
}

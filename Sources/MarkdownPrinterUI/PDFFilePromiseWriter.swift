import AppKit
import Foundation
import UniformTypeIdentifiers

final class PDFFilePromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    let pdfData: Data
    let fileName: String
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MarkdownPrinter.PDFFilePromise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(pdfData: Data, fileName: String) {
        self.pdfData = pdfData
        self.fileName = fileName
    }

    func makeProvider() -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: UTType.pdf.identifier, delegate: self)
        provider.userInfo = self
        return provider
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        fileName
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try pdfData.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }
}

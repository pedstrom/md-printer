import MarkdownPrinterMobileSupport
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct MobilePDFFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

final class MobilePDFActivityItem: NSObject, UIActivityItemSource {
    let data: Data
    let fileURL: URL

    init(data: Data, fileURL: URL) {
        self.data = data
        self.fileURL = fileURL
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        // The share-sheet Print activity may continue reading after its source sheet dismisses.
        // Supplying the complete bytes avoids treating a cleaned-up temporary URL as protected.
        activityType == .print ? data : fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.pdf.identifier
    }
}

struct MoveDocumentPicker: UIViewControllerRepresentable {
    let sourceURL: URL
    let completion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: false)
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void

        init(completion: @escaping (Result<URL, Error>) -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            if let url = urls.first {
                completion(.success(url))
            } else {
                completion(.failure(CocoaError(.fileNoSuchFile)))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: true)
        }
    }
}

enum MobilePDFShareStore {
    static func write(data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPrinterShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}

@MainActor
enum PrintPresenter {
    static func present(data: Data, jobName: String) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = jobName
        info.orientation = .portrait
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }
}

struct DocumentInfoView: View {
    let metadata: MobileDocumentMetadata?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let metadata {
                    LabeledContent("Name", value: metadata.filename)
                    LabeledContent("Kind", value: metadata.kind)
                    if let byteSize = metadata.byteSize {
                        LabeledContent(
                            "Size",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(byteSize),
                                countStyle: .file
                            )
                        )
                    }
                    if let date = metadata.modificationDate {
                        LabeledContent("Modified") {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                    if let location = metadata.locationName, !location.isEmpty {
                        LabeledContent("Location", value: location)
                    }
                } else {
                    ContentUnavailableView("No File Information", systemImage: "info.circle")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

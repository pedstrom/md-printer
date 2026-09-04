import MarkdownPrinterMobileSupport
import SwiftUI
import UniformTypeIdentifiers
import UIKit

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

    var placeholderItem: Any { fileURL }
    var dataTypeIdentifier: String { UTType.pdf.identifier }

    init(data: Data, fileURL: URL) {
        self.data = data
        self.fileURL = fileURL
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        placeholderItem
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        item(for: activityType)
    }

    func item(for activityType: UIActivity.ActivityType?) -> Any {
        // The share-sheet Print activity may continue reading after its source sheet dismisses.
        // Supplying the complete bytes avoids treating a cleaned-up temporary URL as protected.
        activityType == .print ? data : fileURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        dataTypeIdentifier
    }
}

struct LinkedMarkdownFolderPicker: UIViewControllerRepresentable {
    let request: MobileDocumentPermissionRequest
    let completion: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        controller.directoryURL = request.directoryURL
        controller.view.accessibilityIdentifier = "linked-folder-access-picker"
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (URL?) -> Void

        init(completion: @escaping (URL?) -> Void) {
            self.completion = completion
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            completion(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(nil)
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

enum MarkdownPrinterAppInformation {
    static let privacyPolicyURL = URL(
        string: "https://github.com/pedstrom/md-printer/blob/main/docs/privacy-policy.md"
    )!
    static let supportURL = URL(
        string: "https://github.com/pedstrom/md-printer/blob/main/docs/ios-support.md"
    )!
    static let sourceURL = URL(string: "https://github.com/pedstrom/md-printer")!

    static var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "Unknown"
        return "Version \(version) (\(build))"
    }
}

struct MarkdownPrinterInformationView: View {
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List {
                Section("About") {
                    Label("Markdown Printer", systemImage: "doc.richtext")
                        .font(.headline)
                    Text("A local-first Markdown reader for creating polished, searchable PDFs on iPhone.")
                    LabeledContent("App", value: MarkdownPrinterAppInformation.versionDescription)
                }

                Section("Getting Started") {
                    Text("Choose a Markdown file from Files, or tap Sample in the document browser for a ready-made tour.")
                    Text("The iCloud status above the document browser says when Markdown Printer last checked for updates. Files already available on the device remain usable while a check is slow, offline, or unsuccessful.")
                    Text("Use Find to search the open document. Share PDF opens the system share sheet for sending, saving, or printing the generated PDF.")
                }

                Section("Privacy") {
                    Text("Documents are processed on this iPhone. Markdown Printer does not collect analytics, track you, upload document contents, or fetch remote images.")
                    Text("Folder permissions you grant are remembered only on this device so linked local files can open again.")
                    Link(destination: MarkdownPrinterAppInformation.privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }

                Section("Help") {
                    Link(destination: MarkdownPrinterAppInformation.supportURL) {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: MarkdownPrinterAppInformation.sourceURL) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("Markdown Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let onDone {
                            onDone()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

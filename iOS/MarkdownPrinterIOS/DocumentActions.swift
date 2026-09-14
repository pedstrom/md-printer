import MarkdownPrinterMobileSupport
import SwiftUI
import UniformTypeIdentifiers
import UIKit

typealias MobilePDFActivityItem = MarkdownPrinterMobileSupport.MobilePDFActivityItem

typealias MobilePDFShareStore = MarkdownPrinterMobileSupport.MobilePDFShareStore

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
                    Text("A local-first Markdown reader for creating polished, searchable PDFs on iPhone and iPad.")
                    LabeledContent("App", value: MarkdownPrinterAppInformation.versionDescription)
                }

                Section("Getting Started") {
                    Text("Choose a Markdown file from Files. On iPad, shared files open in separate windows or activate an existing matching document. On iPhone, they replace the currently open document.")
                    Text("The iCloud status above the document browser says when Markdown Printer last checked for updates. Files already available on the device remain usable while a check is slow, offline, or unsuccessful.")
                    Text("Use the bottom Find field to search the open document. The share icon beside the filename opens the system sheet for sending, saving, or printing the generated PDF.")
                }

                Section("Privacy") {
                    Text("Documents are processed on this device. Markdown Printer does not collect analytics, track you, or upload document contents. Secure remote images referenced by an open document load automatically and stay in the app cache.")
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

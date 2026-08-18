import MarkdownPrinterCore
import SwiftUI

public struct ExportSettingsView: View {
    @ObservedObject private var preferences: ExportPreferences
    @ObservedObject private var updateController: UpdateController

    public init(preferences: ExportPreferences, updateController: UpdateController) {
        self.preferences = preferences
        self.updateController = updateController
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exports")
                .font(.headline)
            Picker("Default format:", selection: $preferences.defaultFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
            Text("Used by Save and when dragging a document from the preview.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Text("Updates")
                .font(.headline)
            Toggle("Automatically check for updates", isOn: automaticChecksBinding)
            Text("Checks at most once per day. Updates download only after you approve them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 420)
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updateController.automaticallyChecksForUpdates },
            set: { updateController.automaticallyChecksForUpdates = $0 }
        )
    }
}

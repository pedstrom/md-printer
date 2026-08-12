import MarkdownPrinterCore
import SwiftUI

public struct ExportSettingsView: View {
    @ObservedObject private var preferences: ExportPreferences

    public init(preferences: ExportPreferences) {
        self.preferences = preferences
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
        }
        .padding(24)
        .frame(width: 420)
    }
}

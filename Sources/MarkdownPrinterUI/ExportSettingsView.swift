import MarkdownPrinterCore
import SwiftUI

public struct ExportSettingsView: View {
    @ObservedObject private var preferences: ExportPreferences
    @ObservedObject private var updateController: UpdateController
    @ObservedObject private var defaultApplicationController: DefaultApplicationController
    private let quickLookNavigator: FinderQuickLookSettingsNavigator

    public init(
        preferences: ExportPreferences,
        updateController: UpdateController,
        defaultApplicationController: DefaultApplicationController,
        quickLookNavigator: FinderQuickLookSettingsNavigator
    ) {
        self.preferences = preferences
        self.updateController = updateController
        self.defaultApplicationController = defaultApplicationController
        self.quickLookNavigator = quickLookNavigator
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

            Text("Finder Quick Look")
                .font(.headline)
            Text(FinderQuickLookSettingsCopy.usage)
            Text(FinderQuickLookSettingsCopy.bundled)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(FinderQuickLookSettingsCopy.troubleshooting)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings…") {
                quickLookNavigator.openSystemSettings()
            }

            defaultApplicationControls

            Text(FinderQuickLookSettingsCopy.associationNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 4)

            Text("Updates")
                .font(.headline)
            HStack(spacing: 12) {
                Toggle("Automatically check for updates", isOn: automaticChecksBinding)
                Spacer()
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
            }
            Text("Checks at most once per day. Updates download only after you approve them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 520)
        .task {
            defaultApplicationController.refreshDefaultStatus()
        }
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updateController.automaticallyChecksForUpdates },
            set: { updateController.automaticallyChecksForUpdates = $0 }
        )
    }

    @ViewBuilder
    private var defaultApplicationControls: some View {
        switch defaultApplicationController.state {
        case .isDefault:
            Label("Markdown Printer is the default", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Button("Make Markdown Printer Default") {
                requestDefaultApplication()
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .requesting:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Requesting permission from macOS…")
            }
        case .idle:
            Button("Make Markdown Printer Default") {
                requestDefaultApplication()
            }
        }
    }

    private func requestDefaultApplication() {
        Task {
            await defaultApplicationController.makeMarkdownPrinterDefault()
        }
    }
}

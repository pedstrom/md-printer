import AppKit
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
            Text("Used by Save, Share, and dragging from the preview. Hold Option when dragging or clicking Share to use the other format just once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        .frame(width: 520, height: 540, alignment: .topLeading)
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

public struct PageSettingsView: View {
    @ObservedObject private var preferences: PagePreferences
    private let pageSetupPresenter: NativePageSetupPresenter

    public init(preferences: PagePreferences) {
        self.preferences = preferences
        pageSetupPresenter = NativePageSetupPresenter()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Default Page Setup")
                .font(.headline)

            LabeledContent("Paper", value: paperDescription)
            LabeledContent("Orientation", value: orientationDescription)
            LabeledContent("Scale", value: "\(preferences.defaultPageSetup.scalePercentage)%")

            Button("Change Default Page Setup…") {
                changeDefaultPageSetup()
            }

            Text("Documents use fixed 0.75-inch print-safe margins. A document changed with File → Page Setup keeps its own setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Footers")
                .font(.headline)
            FooterPreferenceControl(title: "Left Footer", value: $preferences.leftFooter)
            FooterPreferenceControl(title: "Right Footer", value: $preferences.rightFooter)
            Text("Dates use the Markdown file’s last-modified time. Page numbers remain centered.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 520, height: 540, alignment: .topLeading)
    }

    private var paperDescription: String {
        if preferences.defaultPageSetup.paperName == DocumentPageSetup.letter.paperName {
            return "US Letter"
        }
        return preferences.defaultPageSetup.paperName
    }

    private var orientationDescription: String {
        preferences.defaultPageSetup.orientation == .portrait ? "Portrait" : "Landscape"
    }

    private func changeDefaultPageSetup() {
        guard let window = NSApp.keyWindow else { return }
        pageSetupPresenter.present(preferences.defaultPageSetup, for: window) { result in
            guard case let .accepted(pageSetup) = result else { return }
            preferences.defaultPageSetup = pageSetup
        }
    }
}

private struct FooterPreferenceControl: View {
    let title: String
    @Binding var value: FooterValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: kindBinding) {
                ForEach(FooterKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if case .custom = value {
                TextField("Custom footer text", text: customTextBinding)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var kindBinding: Binding<FooterKind> {
        Binding(
            get: { FooterKind(value) },
            set: { kind in
                switch kind {
                case .none: value = .none
                case .date: value = .date
                case .dateTime: value = .dateTime
                case .documentTitle: value = .documentTitle
                case .filename: value = .filename
                case .custom:
                    if case .custom = value { return }
                    value = .custom("")
                }
            }
        )
    }

    private var customTextBinding: Binding<String> {
        Binding(
            get: {
                guard case let .custom(text) = value else { return "" }
                return text
            },
            set: { value = FooterValue.custom($0).normalized }
        )
    }
}

private enum FooterKind: String, CaseIterable, Identifiable {
    case none
    case date
    case dateTime
    case documentTitle
    case filename
    case custom

    init(_ value: FooterValue) {
        switch value {
        case .none: self = .none
        case .date: self = .date
        case .dateTime: self = .dateTime
        case .documentTitle: self = .documentTitle
        case .filename: self = .filename
        case .custom: self = .custom
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .date: return "Date"
        case .dateTime: return "Date & Time"
        case .documentTitle: return "Document Title"
        case .filename: return "Filename"
        case .custom: return "Custom…"
        }
    }
}

import AppKit
import Combine
import Foundation
import MarkdownPrinterCore

@MainActor
public final class ExportPreferences: ObservableObject {
    public static let defaultFormatKey = "defaultExportFormat"

    @Published public var defaultFormat: ExportFormat {
        didSet {
            defaults.set(defaultFormat.rawValue, forKey: Self.defaultFormatKey)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultFormat = defaults.string(forKey: Self.defaultFormatKey)
            .flatMap(ExportFormat.init(rawValue:))
            ?? .pdf
    }
}

extension ExportFormat {
    var alternate: ExportFormat {
        switch self {
        case .pdf: return .word
        case .word: return .pdf
        }
    }

    func forAction(modifierFlags: NSEvent.ModifierFlags) -> ExportFormat {
        modifierFlags.contains(.option) ? alternate : self
    }
}

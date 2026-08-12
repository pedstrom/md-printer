import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownPrinterCore
@testable import MarkdownPrinterUI

@MainActor
final class ExportPreferencesTests: XCTestCase {
    func testPreferencesDefaultToPDFAndPersistWordAcrossInstances() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = ExportPreferences(defaults: defaults)
        XCTAssertEqual(initial.defaultFormat, .pdf)

        initial.defaultFormat = .word

        XCTAssertEqual(defaults.string(forKey: ExportPreferences.defaultFormatKey), "word")
        XCTAssertEqual(ExportPreferences(defaults: defaults).defaultFormat, .word)
    }

    func testUnknownStoredPreferenceFallsBackToPDF() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-format", forKey: ExportPreferences.defaultFormatKey)

        XCTAssertEqual(ExportPreferences(defaults: defaults).defaultFormat, .pdf)
    }

    func testSavePanelUsesAndOverridesDefaultWithoutChangingPreference() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = ExportPreferences(defaults: defaults)
        preferences.defaultFormat = .word
        let controller = ExportSavePanelController(
            defaultFormat: preferences.defaultFormat,
            suggestedFileName: "Quarterly Notes.final.docx"
        )

        XCTAssertEqual(controller.selectedFormat, .word)
        XCTAssertEqual(controller.panel.allowedContentTypes, [.wordProcessingML])
        XCTAssertEqual(controller.panel.nameFieldStringValue, "Quarterly Notes.final.docx")

        controller.select(.pdf)

        XCTAssertEqual(controller.selectedFormat, .pdf)
        XCTAssertEqual(controller.panel.allowedContentTypes, [.pdf])
        XCTAssertEqual(controller.panel.nameFieldStringValue, "Quarterly Notes.final.pdf")
        XCTAssertEqual(preferences.defaultFormat, .word)
    }

    func testSavePanelAddsExtensionsWithoutDiscardingUnknownCompoundSuffixes() {
        let controller = ExportSavePanelController(
            defaultFormat: .pdf,
            suggestedFileName: "Quarterly Notes.draft"
        )

        XCTAssertEqual(controller.panel.nameFieldStringValue, "Quarterly Notes.draft.pdf")
        controller.panel.nameFieldStringValue = "   "
        controller.select(.word)
        XCTAssertEqual(controller.panel.nameFieldStringValue, "Untitled.docx")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "ExportPreferencesTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

private extension UTType {
    static let wordProcessingML = UTType(filenameExtension: "docx")!
}

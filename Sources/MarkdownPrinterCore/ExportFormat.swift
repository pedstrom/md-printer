import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case word

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pdf:
            return "PDF"
        case .word:
            return "Microsoft Word"
        }
    }

    public var pathExtension: String {
        switch self {
        case .pdf:
            return "pdf"
        case .word:
            return "docx"
        }
    }

    public var contentType: UTType {
        switch self {
        case .pdf:
            return .pdf
        case .word:
            return UTType(filenameExtension: "docx")
                ?? UTType(importedAs: "org.openxmlformats.wordprocessingml.document")
        }
    }
}

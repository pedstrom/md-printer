import AppKit
import UniformTypeIdentifiers

public enum DroppedFileLoader {
    public static func accepts(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    }

    public static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await url(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                guard error == nil, let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
            }
        }
    }
}

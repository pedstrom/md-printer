import AppKit
import Combine
import MarkdownPrinterCore

/// Requests are keyed by file identity, never by the fragment-bearing URL.
@MainActor
public final class MarkdownNavigationCoordinator: ObservableObject {
    public static let shared = MarkdownNavigationCoordinator()
    @Published public private(set) var requests: [URL: MarkdownNavigationRequest] = [:]
    public init() {}

    public func enqueue(_ request: MarkdownNavigationRequest) {
        requests[request.fileURL] = request
    }

    public func request(for fileURL: URL?) -> MarkdownNavigationRequest? {
        fileURL.flatMap { requests[$0.standardizedFileURL] }
    }

    public func complete(_ request: MarkdownNavigationRequest) {
        if requests[request.fileURL]?.id == request.id { requests.removeValue(forKey: request.fileURL) }
    }
}

#if canImport(UIKit)
import Combine
import Foundation
import MarkdownPrinterCore

@MainActor
public final class MobileSectionNavigation: ObservableObject {
    public static let shared = MobileSectionNavigation()
    @Published public private(set) var requests: [URL: MarkdownNavigationRequest] = [:]
    public init() {}
    public func enqueue(_ request: MarkdownNavigationRequest) { requests[request.fileURL] = request }
    public func request(for url: URL?) -> MarkdownNavigationRequest? { url.flatMap { requests[$0.standardizedFileURL] } }
    public func complete(_ request: MarkdownNavigationRequest) {
        if requests[request.fileURL]?.id == request.id { requests.removeValue(forKey: request.fileURL) }
    }
}
#endif

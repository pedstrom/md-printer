#if canImport(UIKit)
import Foundation
import UIKit

public enum MobileImagePlaceholderReason: String, Equatable, Sendable {
    case remote
    case missing
    case corrupt
    case inaccessible

    public var message: String {
        switch self {
        case .remote: return "Remote image not loaded"
        case .missing: return "Image not found"
        case .corrupt: return "Image could not be displayed"
        case .inaccessible: return "Image unavailable from this file provider"
        }
    }
}

public enum MobileImageResolution: Equatable, Sendable {
    case local(URL)
    case placeholder(MobileImagePlaceholderReason)
}

public struct MobileImageResolver: Sendable {
    public init() {}

    public func resolve(source: String, relativeTo baseURL: URL?) -> MobileImageResolution {
        let decoded = source.removingPercentEncoding ?? source
        if let candidate = URL(string: decoded),
           let scheme = candidate.scheme?.lowercased(),
           scheme != "file" {
            return .placeholder(.remote)
        }

        let url: URL?
        if let candidate = URL(string: decoded), candidate.isFileURL {
            url = candidate
        } else if let baseURL {
            url = URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
        } else {
            url = nil
        }
        guard let url else { return .placeholder(.missing) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .placeholder(.missing)
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return .placeholder(.inaccessible)
        }
        guard UIImage(data: data) != nil else { return .placeholder(.corrupt) }
        return .local(url)
    }
}
#endif

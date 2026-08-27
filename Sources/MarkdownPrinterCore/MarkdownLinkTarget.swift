import Foundation

public enum MarkdownLinkTarget {
    public static let supportedPathExtensions = ["md", "markdown", "mdown", "mkd"]

    public static func fileURL(from url: URL) -> URL? {
        guard url.isFileURL,
              supportedPathExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.url ?? url).standardizedFileURL
    }

    public static func resolvedURL(for destination: String, relativeTo baseURL: URL?) -> URL? {
        let decoded = destination.removingPercentEncoding ?? destination
        if let absolute = URL(string: decoded), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL else { return URL(string: decoded) }
        return URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
    }
}

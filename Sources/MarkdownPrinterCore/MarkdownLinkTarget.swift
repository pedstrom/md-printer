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
        // Encode raw Unicode without encoding percent escapes a second time.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        let encoded = destination.addingPercentEncoding(withAllowedCharacters: allowed) ?? destination
        if let absolute = URL(string: encoded), absolute.scheme != nil {
            return absolute
        }
        if destination.hasPrefix("#") { return URL(string: encoded) }
        guard let baseURL else { return URL(string: encoded) }
        return URL(string: encoded, relativeTo: baseURL)?.absoluteURL
    }

    public static func localTarget(from url: URL) -> MarkdownNavigationRequest? {
        guard let file = fileURL(from: url) else { return nil }
        return MarkdownNavigationRequest(fileURL: file, fragment: URLComponents(url: url, resolvingAgainstBaseURL: true)?.fragment)
    }

    public static func sectionFragment(from url: URL, sourceURL: URL? = nil) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let fragment = components.fragment else { return nil }
        if components.scheme == nil, components.path.isEmpty { return fragment }
        if let sourceURL, let target = fileURL(from: url), target == sourceURL.standardizedFileURL { return fragment }
        return nil
    }

    public static func hostAppURL(for target: MarkdownNavigationRequest) -> URL {
        var components = URLComponents()
        components.scheme = "markdown-printer"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "file", value: target.fileURL.absoluteString)]
        if let fragment = target.fragment { components.queryItems?.append(URLQueryItem(name: "section", value: fragment)) }
        return components.url!
    }

    public static func hostAppTarget(from url: URL) -> MarkdownNavigationRequest? {
        guard url.scheme == "markdown-printer", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let file = items.first(where: { $0.name == "file" })?.value.flatMap(URL.init(string:)),
              let normalized = fileURL(from: file) else { return nil }
        return MarkdownNavigationRequest(fileURL: normalized, fragment: items.first(where: { $0.name == "section" })?.value)
    }
}

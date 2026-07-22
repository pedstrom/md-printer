import Foundation

public enum MarkdownLinkTarget {
    private static let pathExtensions = ["md", "markdown", "mdown", "mkd"]

    public static func fileURL(from url: URL) -> URL? {
        guard url.isFileURL,
              pathExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return (components?.url ?? url).standardizedFileURL
    }
}

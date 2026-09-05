import CryptoKit
import Foundation
import ImageIO

public struct RemoteImageReference: Equatable, Hashable, Sendable {
    public let source: String
    public let alternativeText: String
    public let requestedWidth: Double?

    public init?(source: String, alternativeText: String, requestedWidth: Double? = nil) {
        guard Self.remoteURL(from: source) != nil else { return nil }
        self.source = source
        self.alternativeText = alternativeText
        self.requestedWidth = requestedWidth
    }

    public static func remoteURL(from source: String) -> URL? {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}

public enum RemoteImageCatalog {
    public static func references(in document: MarkdownDocument) -> [RemoteImageReference] {
        references(in: document.blocks)
    }

    public static func references(in blocks: [MarkdownBlock]) -> [RemoteImageReference] {
        var references: [RemoteImageReference] = []
        var seenSources = Set<String>()
        append(blocks: blocks, to: &references, seenSources: &seenSources)
        return references
    }

    public static func references(in nodes: [InlineNode]) -> [RemoteImageReference] {
        var references: [RemoteImageReference] = []
        var seenSources = Set<String>()
        append(nodes: nodes, to: &references, seenSources: &seenSources)
        return references
    }

    private static func append(
        blocks: [MarkdownBlock],
        to references: inout [RemoteImageReference],
        seenSources: inout Set<String>
    ) {
        for block in blocks {
            switch block {
            case let .heading(_, nodes), let .paragraph(nodes), let .footnoteDefinition(_, nodes):
                append(nodes: nodes, to: &references, seenSources: &seenSources)
            case let .blockquote(children):
                append(blocks: children, to: &references, seenSources: &seenSources)
            case let .list(items, _, _, _):
                for item in items {
                    append(blocks: item.blocks, to: &references, seenSources: &seenSources)
                }
            case let .rawHTML(source):
                if let htmlImage = HTMLImageReference(html: source) {
                    append(
                        source: htmlImage.source,
                        alternativeText: htmlImage.alternativeText,
                        requestedWidth: htmlImage.requestedWidth,
                        to: &references,
                        seenSources: &seenSources
                    )
                }
            case let .table(headers, _, rows):
                for cell in headers + rows.flatMap({ $0 }) {
                    append(nodes: cell, to: &references, seenSources: &seenSources)
                }
            case .codeBlock, .thematicBreak:
                break
            }
        }
    }

    private static func append(
        nodes: [InlineNode],
        to references: inout [RemoteImageReference],
        seenSources: inout Set<String>
    ) {
        for node in nodes {
            switch node {
            case let .image(alt, source, _):
                append(
                    source: source,
                    alternativeText: alt,
                    requestedWidth: nil,
                    to: &references,
                    seenSources: &seenSources
                )
            case let .rawHTML(source):
                if let htmlImage = HTMLImageReference(html: source) {
                    append(
                        source: htmlImage.source,
                        alternativeText: htmlImage.alternativeText,
                        requestedWidth: htmlImage.requestedWidth,
                        to: &references,
                        seenSources: &seenSources
                    )
                }
            case let .emphasis(children),
                 let .strong(children),
                 let .underline(children),
                 let .strikethrough(children),
                 let .link(children, _, _):
                append(nodes: children, to: &references, seenSources: &seenSources)
            case .text, .code, .footnoteReference, .softBreak, .hardBreak:
                break
            }
        }
    }

    private static func append(
        source: String,
        alternativeText: String,
        requestedWidth: Double?,
        to references: inout [RemoteImageReference],
        seenSources: inout Set<String>
    ) {
        guard let reference = RemoteImageReference(
            source: source,
            alternativeText: alternativeText,
            requestedWidth: requestedWidth
        ), seenSources.insert(reference.source).inserted else {
            return
        }
        references.append(reference)
    }
}

public enum RemoteImageActionURL {
    private static let scheme = "markdown-printer"
    private static let host = "remote-image"

    public static func downloadURL(for source: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/download"
        components.queryItems = [URLQueryItem(name: "source", value: source)]
        return components.url!
    }

    public static func downloadSource(from value: Any) -> String? {
        let url: URL?
        if let candidate = value as? URL {
            url = candidate
        } else if let candidate = value as? String {
            url = URL(string: candidate)
        } else {
            url = nil
        }
        guard let url,
              url.scheme == scheme,
              url.host == host,
              url.path == "/download" else {
            return nil
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "source" })?
            .value
    }
}

public struct RemoteImageCache: Equatable, Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    public static var applicationDefault: RemoteImageCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RemoteImageCache(
            directoryURL: base
                .appendingPathComponent("MarkdownPrinter", isDirectory: true)
                .appendingPathComponent("RemoteImages", isDirectory: true)
        )
    }

    public func cachedFileURL(for source: String) -> URL? {
        guard let remoteURL = RemoteImageReference.remoteURL(from: source) else { return nil }
        let fileURL = cacheFileURL(for: remoteURL)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              Self.isSupportedImage(data) else {
            return nil
        }
        return fileURL
    }

    @discardableResult
    public func store(_ data: Data, for source: String) throws -> URL {
        guard let remoteURL = RemoteImageReference.remoteURL(from: source) else {
            throw RemoteImageDownloadError.invalidURL
        }
        guard Self.isSupportedImage(data) else {
            throw RemoteImageDownloadError.invalidImage
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = cacheFileURL(for: remoteURL)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    public func removeCachedFile(for source: String) throws {
        guard let remoteURL = RemoteImageReference.remoteURL(from: source) else { return }
        let fileURL = cacheFileURL(for: remoteURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func cacheFileURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directoryURL.appendingPathComponent(digest, isDirectory: false)
    }

    private static func isSupportedImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return false
        }
        return true
    }
}

public struct RemoteImageDownloadResponse: Sendable {
    public let data: Data
    public let statusCode: Int?
    public let mimeType: String?
    public let expectedContentLength: Int64

    public init(
        data: Data,
        statusCode: Int?,
        mimeType: String?,
        expectedContentLength: Int64 = -1
    ) {
        self.data = data
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.expectedContentLength = expectedContentLength
    }
}

public protocol RemoteImageDownloading: Sendable {
    func download(source: String) async throws -> URL
}

public actor RemoteImageDownloader: RemoteImageDownloading {
    public typealias Fetch = @Sendable (URL) async throws -> RemoteImageDownloadResponse

    public let cache: RemoteImageCache
    public let maximumDownloadSize: Int
    private let fetch: Fetch

    public init(
        cache: RemoteImageCache = .applicationDefault,
        maximumDownloadSize: Int = 25 * 1_024 * 1_024,
        fetch: Fetch? = nil
    ) {
        self.cache = cache
        self.maximumDownloadSize = maximumDownloadSize
        self.fetch = fetch ?? { url in
            try await Self.fetchFromNetwork(url)
        }
    }

    public func download(source: String) async throws -> URL {
        if let cached = cache.cachedFileURL(for: source) { return cached }
        guard let url = RemoteImageReference.remoteURL(from: source) else {
            throw RemoteImageDownloadError.invalidURL
        }
        guard url.scheme?.lowercased() == "https" else {
            throw RemoteImageDownloadError.insecureURL
        }
        try Task.checkCancellation()
        let response = try await fetch(url)
        try Task.checkCancellation()
        if let statusCode = response.statusCode, !(200...299).contains(statusCode) {
            throw RemoteImageDownloadError.httpStatus(statusCode)
        }
        if response.expectedContentLength > Int64(maximumDownloadSize)
            || response.data.count > maximumDownloadSize {
            throw RemoteImageDownloadError.tooLarge(maximumDownloadSize)
        }
        if let mimeType = response.mimeType?.lowercased(),
           !mimeType.hasPrefix("image/") {
            throw RemoteImageDownloadError.invalidContentType
        }
        return try cache.store(response.data, for: source)
    }

    private static func fetchFromNetwork(_ url: URL) async throws -> RemoteImageDownloadResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        let http = response as? HTTPURLResponse
        return RemoteImageDownloadResponse(
            data: data,
            statusCode: http?.statusCode,
            mimeType: response.mimeType,
            expectedContentLength: response.expectedContentLength
        )
    }
}

public enum RemoteImageDownloadError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case insecureURL
    case httpStatus(Int)
    case invalidContentType
    case invalidImage
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The remote image address is invalid."
        case .insecureURL:
            return "Only secure HTTPS images can be downloaded."
        case let .httpStatus(status):
            return "The image server returned HTTP status \(status)."
        case .invalidContentType, .invalidImage:
            return "The downloaded file is not a supported image."
        case let .tooLarge(maximumBytes):
            return "The remote image exceeds the \(maximumBytes / 1_024 / 1_024) MB download limit."
        }
    }
}

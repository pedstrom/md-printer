import Combine
import Foundation

@MainActor
public final class ImagePreferences: ObservableObject {
    public static let automaticDownloadsKey = "automaticallyDownloadRemoteImages"

    @Published public var automaticallyDownloadRemoteImages: Bool {
        didSet {
            defaults.set(automaticallyDownloadRemoteImages, forKey: Self.automaticDownloadsKey)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyDownloadRemoteImages = defaults.object(forKey: Self.automaticDownloadsKey) as? Bool ?? true
    }
}

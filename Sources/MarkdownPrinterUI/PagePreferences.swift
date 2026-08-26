import Combine
import Foundation
import MarkdownPrinterCore

@MainActor
public final class PagePreferences: ObservableObject {
    package static let pageSetupKey = "defaultDocumentPageSetup"
    package static let leftFooterKey = "leftDocumentFooter"
    package static let rightFooterKey = "rightDocumentFooter"

    @Published public var defaultPageSetup: DocumentPageSetup {
        didSet { persist(defaultPageSetup, key: Self.pageSetupKey) }
    }
    @Published public var leftFooter: FooterValue {
        didSet {
            let normalized = leftFooter.normalized
            if normalized != leftFooter {
                leftFooter = normalized
            } else {
                persist(leftFooter, key: Self.leftFooterKey)
            }
        }
    }
    @Published public var rightFooter: FooterValue {
        didSet {
            let normalized = rightFooter.normalized
            if normalized != rightFooter {
                rightFooter = normalized
            } else {
                persist(rightFooter, key: Self.rightFooterKey)
            }
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultPageSetup = Self.load(
            DocumentPageSetup.self,
            key: Self.pageSetupKey,
            defaults: defaults
        ) ?? .letter
        leftFooter = Self.load(
            FooterValue.self,
            key: Self.leftFooterKey,
            defaults: defaults
        )?.normalized ?? .none
        rightFooter = Self.load(
            FooterValue.self,
            key: Self.rightFooterKey,
            defaults: defaults
        )?.normalized ?? .none
    }

    public func resolvedFooters(for document: MarkdownDocument) -> ResolvedFooterConfiguration {
        ResolvedFooterConfiguration(
            left: leftFooter.resolved(for: document),
            right: rightFooter.resolved(for: document)
        )
    }

    private func persist<Value: Encodable>(_ value: Value, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        defaults: UserDefaults
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

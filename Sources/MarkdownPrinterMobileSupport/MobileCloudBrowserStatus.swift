import Foundation

public enum MobileCloudBrowserStatus: Equatable, Sendable {
    case checking
    case checked(Date)
    case slow
    case offline
    case failed
    case unavailable

    public var message: String {
        switch self {
        case .checking:
            return "Checking iCloud…"
        case let .checked(date):
            return "Checked for updates at \(date.formatted(date: .omitted, time: .shortened))"
        case .slow:
            return "iCloud is taking longer than usual — showing available files"
        case .offline:
            return "Offline — showing available files"
        case .failed:
            return "Couldn’t check iCloud — showing available files"
        case .unavailable:
            return "iCloud Drive unavailable"
        }
    }

    public var systemImageName: String {
        switch self {
        case .checking, .slow:
            return "icloud"
        case .checked:
            return "checkmark.icloud"
        case .offline:
            return "wifi.slash"
        case .failed:
            return "exclamationmark.icloud"
        case .unavailable:
            return "icloud.slash"
        }
    }

    public var showsProgress: Bool {
        switch self {
        case .checking, .slow:
            return true
        case .checked, .offline, .failed, .unavailable:
            return false
        }
    }

    public var offersRetry: Bool {
        self == .failed
    }
}

public struct MobileCloudBrowserStatusStateMachine: Sendable {
    public private(set) var status: MobileCloudBrowserStatus

    private var nextCheckID: UInt64 = 0
    private var activeCheckID: UInt64?

    public init(status: MobileCloudBrowserStatus = .checking) {
        self.status = status
    }

    public func needsRefresh(
        at date: Date,
        freshnessInterval: TimeInterval
    ) -> Bool {
        switch status {
        case .checking, .slow:
            return activeCheckID == nil
        case let .checked(checkedAt):
            return date.timeIntervalSince(checkedAt) >= freshnessInterval
        case .offline, .failed, .unavailable:
            return true
        }
    }

    @discardableResult
    public mutating func beginCheck(
        networkAvailable: Bool?,
        iCloudAvailable: Bool
    ) -> UInt64? {
        guard networkAvailable != false else {
            setOffline()
            return nil
        }
        guard iCloudAvailable else {
            setUnavailable()
            return nil
        }

        nextCheckID &+= 1
        activeCheckID = nextCheckID
        status = .checking
        return nextCheckID
    }

    public mutating func markSlow(for checkID: UInt64) {
        guard activeCheckID == checkID else { return }
        status = .slow
    }

    public mutating func complete(_ checkID: UInt64, at date: Date) {
        guard activeCheckID == checkID else { return }
        activeCheckID = nil
        status = .checked(date)
    }

    public mutating func fail(_ checkID: UInt64) {
        guard activeCheckID == checkID else { return }
        activeCheckID = nil
        status = .failed
    }

    public mutating func setOffline() {
        activeCheckID = nil
        status = .offline
    }

    public mutating func setUnavailable() {
        activeCheckID = nil
        status = .unavailable
    }
}

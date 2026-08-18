import Combine
import Foundation

@MainActor
public final class ApplicationActivityCoordinator: ObservableObject {
    private var activeBlockingOperationCount = 0
    private var pendingRelaunchHandler: (() -> Void)?

    public init() {}

    public func performBlockingOperation<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        activeBlockingOperationCount += 1
        defer { finishBlockingOperation() }
        return try operation()
    }

    package var hasActiveBlockingOperation: Bool {
        activeBlockingOperationCount > 0
    }

    package func postponeRelaunch(until handler: @escaping () -> Void) -> Bool {
        guard hasActiveBlockingOperation else { return false }
        pendingRelaunchHandler = handler
        return true
    }

    private func finishBlockingOperation() {
        precondition(activeBlockingOperationCount > 0)
        activeBlockingOperationCount -= 1
        guard activeBlockingOperationCount == 0 else { return }

        let handler = pendingRelaunchHandler
        pendingRelaunchHandler = nil
        handler?()
    }
}

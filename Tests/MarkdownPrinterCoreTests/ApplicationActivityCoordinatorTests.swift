import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class ApplicationActivityCoordinatorTests: XCTestCase {
    func testRelaunchDoesNotPostponeWithoutBlockingOperation() {
        let coordinator = ApplicationActivityCoordinator()
        var didRelaunch = false

        XCTAssertFalse(coordinator.postponeRelaunch { didRelaunch = true })
        XCTAssertFalse(didRelaunch)
    }

    func testRelaunchWaitsUntilBlockingOperationFinishes() {
        let coordinator = ApplicationActivityCoordinator()
        var didRelaunch = false

        coordinator.performBlockingOperation {
            XCTAssertTrue(coordinator.hasActiveBlockingOperation)
            XCTAssertTrue(coordinator.postponeRelaunch { didRelaunch = true })
            XCTAssertFalse(didRelaunch)
        }

        XCTAssertTrue(didRelaunch)
        XCTAssertFalse(coordinator.hasActiveBlockingOperation)
    }

    func testNestedBlockingOperationsWaitForOutermostOperation() {
        let coordinator = ApplicationActivityCoordinator()
        var didRelaunch = false

        coordinator.performBlockingOperation {
            coordinator.performBlockingOperation {
                XCTAssertTrue(coordinator.postponeRelaunch { didRelaunch = true })
            }
            XCTAssertFalse(didRelaunch)
        }

        XCTAssertTrue(didRelaunch)
    }

    func testThrowingOperationStillEndsBlockingState() {
        enum ExpectedError: Error { case failure }
        let coordinator = ApplicationActivityCoordinator()

        XCTAssertThrowsError(
            try coordinator.performBlockingOperation {
                throw ExpectedError.failure
            }
        )
        XCTAssertFalse(coordinator.hasActiveBlockingOperation)
    }
}

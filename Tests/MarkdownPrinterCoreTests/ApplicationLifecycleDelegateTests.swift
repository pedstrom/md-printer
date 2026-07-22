import AppKit
import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class ApplicationLifecycleDelegateTests: XCTestCase {
    func testApplicationTerminatesAfterLastWindowCloses() {
        let delegate = ApplicationLifecycleDelegate()

        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }
}

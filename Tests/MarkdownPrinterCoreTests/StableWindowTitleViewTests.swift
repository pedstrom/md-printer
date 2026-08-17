import XCTest
@testable import MarkdownPrinterUI

@MainActor
final class StableWindowTitleViewTests: XCTestCase {
    func testHostAcceptsTitleUpdatesBeforeJoiningAWindow() {
        let host = StableWindowTitleHostView(frame: .zero)

        host.updateTitle("Markdown Heading")
        host.viewDidMoveToWindow()

        XCTAssertNil(host.window)
    }

    func testPolicyRestoresTheDocumentTitleWithoutRedundantWrites() {
        let window = TestWindowTitle(title: "notes.md")

        XCTAssertTrue(StableWindowTitlePolicy.enforce("Markdown Heading", on: window))
        XCTAssertEqual(window.title, "Markdown Heading")
        XCTAssertEqual(window.setCount, 1)

        XCTAssertFalse(StableWindowTitlePolicy.enforce("Markdown Heading", on: window))
        XCTAssertEqual(window.setCount, 1)

        window.title = "notes.md"
        XCTAssertTrue(StableWindowTitlePolicy.enforce("Markdown Heading", on: window))
        XCTAssertEqual(window.title, "Markdown Heading")
        XCTAssertEqual(window.setCount, 3)

        XCTAssertFalse(StableWindowTitlePolicy.enforce("", on: window))
        XCTAssertEqual(window.setCount, 3)
    }
}

@MainActor
private final class TestWindowTitle: WindowTitleWriting {
    var title: String {
        didSet { setCount += 1 }
    }
    private(set) var setCount = 0

    init(title: String) {
        self.title = title
    }
}

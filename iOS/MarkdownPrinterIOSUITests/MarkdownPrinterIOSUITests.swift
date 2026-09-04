import XCTest

final class MarkdownPrinterIOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["iPhone Viewer Fixture"].waitForExistence(timeout: 8))
    }

    func testViewerUsesStaticFilenameAndFocusedFindShareToolbar() {
        XCTAssertTrue(app.staticTexts["fixture.md"].exists)
        XCTAssertFalse(app.buttons["document-actions-button"].exists)
        XCTAssertFalse(app.buttons["info-button"].exists)
        XCTAssertTrue(app.buttons["share-pdf-button"].exists)
        XCTAssertTrue(app.buttons["search-button"].exists)
        XCTAssertFalse(app.searchFields["Find in Markdown"].exists)
        XCTAssertEqual(app.buttons["search-button"].label, "Find")
        XCTAssertEqual(app.buttons["share-pdf-button"].label, "Share PDF")
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "iPhone viewer portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
    }

    func testSearchNavigatesMatchesAndExposesOptions() {
        app.buttons["search-button"].tap()
        let search = app.searchFields["Find in Markdown"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("EXACT SEARCH PHRASE")
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 3))

        app.buttons["Next result"].tap()
        XCTAssertTrue(app.staticTexts["2 of 2"].exists)
        app.buttons["Previous result"].tap()
        XCTAssertTrue(app.staticTexts["1 of 2"].exists)

        app.buttons["Search options"].tap()
        XCTAssertTrue(app.buttons["Match Case"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Whole Word"].exists)
        app.buttons["Match Case"].tap()
        app.tap()
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["search-button"].waitForExistence(timeout: 3))
    }

    func testSharePDFPreparesNamedPDFForSystemShare() {
        app.buttons["share-pdf-button"].tap()
        XCTAssertTrue(app.staticTexts["PDF Ready to Share"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["fixture.pdf"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["share-pdf-button"].waitForExistence(timeout: 3))
    }

    func testFirstLaunchOffersInformationAndAWorkingSample() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-store-readiness"]
        app.launch()

        let sampleButton = app.buttons["Open Markdown Printer sample"]
        let informationButton = app.buttons["About, privacy, and support"]
        XCTAssertTrue(sampleButton.waitForExistence(timeout: 8))
        XCTAssertTrue(informationButton.exists)

        let browser = XCTAttachment(screenshot: app.screenshot())
        browser.name = "First-launch document browser"
        browser.lifetime = .keepAlways
        add(browser)

        informationButton.tap()
        XCTAssertTrue(app.navigationBars["Markdown Printer"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()

        sampleButton.tap()
        XCTAssertTrue(app.staticTexts["Welcome to Markdown Printer"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["browser-back-button"].exists)
    }

    func testFilesSentFromAnotherAppOpenOnColdAndWarmLaunches() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-store-readiness"]
        app.launch()
        XCTAssertTrue(app.buttons["Open Markdown Printer sample"].waitForExistence(timeout: 8))
        app.terminate()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MarkdownPrinterIncomingUITest-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("Shared from ChatGPT.md")
        try Data("# Received from ChatGPT\n\nCold launch.".utf8).write(to: firstURL)
        app.open(firstURL)

        XCTAssertTrue(app.staticTexts["Received from ChatGPT"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts["Couldn’t Open Markdown"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Shared from ChatGPT")
            ).firstMatch.exists
        )

        let secondURL = directory.appendingPathComponent("Shared while Open.md")
        try Data("# Received While Open\n\nWarm launch.".utf8).write(to: secondURL)
        app.open(secondURL)

        XCTAssertTrue(app.staticTexts["Received While Open"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts["Couldn’t Open Markdown"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Shared while Open")
            ).firstMatch.exists
        )
    }

    func testLinkedMarkdownPushesAndBackReturnsToOriginalDocument() {
        let link = app.links["Linked page"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        XCTAssertTrue(app.staticTexts["Linked Markdown Page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["linked.markdown"].exists)
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["iPhone Viewer Fixture"].waitForExistence(timeout: 5))
    }

    func testLinkedMarkdownSupportsBackSwipesFromBothScreenEdges() {
        openLinkedMarkdown()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.45))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
            )
        XCTAssertTrue(app.staticTexts["iPhone Viewer Fixture"].waitForExistence(timeout: 5))

        openLinkedMarkdown()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
            )
        XCTAssertTrue(app.staticTexts["iPhone Viewer Fixture"].waitForExistence(timeout: 5))
    }

    func testPermissionGatedLinkedDocumentRequestsReusableFolderAccess() {
        let link = app.links["Permission-gated page"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()

        XCTAssertTrue(
            app.otherElements["linked-folder-access-picker"].waitForExistence(timeout: 8)
        )
        app.swipeDown()

        XCTAssertTrue(app.staticTexts["Folder Access Needed"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Allow Folder Access…"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "open links inside that folder directly")
            ).firstMatch.exists
        )
        XCTAssertFalse(app.staticTexts["Couldn’t Open Markdown"].exists)
    }

    func testReadingTapHidesAndRestoresToolbars() {
        XCTAssertTrue(app.buttons["share-pdf-button"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        XCTAssertFalse(app.buttons["share-pdf-button"].waitForExistence(timeout: 1))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        XCTAssertTrue(app.buttons["share-pdf-button"].waitForExistence(timeout: 3))
    }

    func testViewerAdaptsToLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["iPhone Viewer Fixture"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["share-pdf-button"].exists)
        let landscape = XCTAttachment(screenshot: app.screenshot())
        landscape.name = "iPhone viewer landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
    }

    func testTableAndCodeRenderInsideTheContinuousViewer() {
        let tableHeader = app.descendants(matching: .any)["markdown-table-0-0"]
        for _ in 0..<5 where !tableHeader.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(tableHeader.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["markdown-table-0-1"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["markdown-table-1-0"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["markdown-table-2-0"].exists)

        let table = XCTAttachment(screenshot: app.screenshot())
        table.name = "Aligned Markdown table"
        table.lifetime = .keepAlways
        add(table)

        let code = app.staticTexts["markdown-code-block"]
        for _ in 0..<4 where !code.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(code.waitForExistence(timeout: 3))
    }

    func testUnreadableLinkedDocumentShowsRecoverableErrorState() {
        let link = app.links["Missing linked file"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        XCTAssertTrue(app.staticTexts["Couldn’t Open Markdown"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).exists)
    }

    private func openLinkedMarkdown() {
        let link = app.links["Linked page"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        XCTAssertTrue(app.staticTexts["Linked Markdown Page"].waitForExistence(timeout: 5))
    }
}

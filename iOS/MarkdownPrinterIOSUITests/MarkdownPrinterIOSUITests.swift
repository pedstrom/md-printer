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

    func testViewerOpensWithPreviewStyleToolbarAndInfo() {
        XCTAssertTrue(app.buttons["info-button"].exists)
        XCTAssertTrue(app.buttons["share-pdf-button"].exists)
        XCTAssertTrue(app.buttons["search-button"].exists)
        XCTAssertTrue(app.buttons["document-actions-button"].exists)
        let portrait = XCTAttachment(screenshot: app.screenshot())
        portrait.name = "iPhone viewer portrait"
        portrait.lifetime = .keepAlways
        add(portrait)

        app.buttons["info-button"].tap()
        XCTAssertTrue(app.navigationBars["Info"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["fixture.md"].exists)
        XCTAssertTrue(app.staticTexts["Name"].exists)
        XCTAssertTrue(app.staticTexts["Kind"].exists)
        XCTAssertTrue(app.staticTexts["Size"].exists)
        for _ in 0..<3 where !app.staticTexts["Modified"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Modified"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["info-button"].waitForExistence(timeout: 3))
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

    func testSharePDFPresentsSystemShareSheet() {
        app.buttons["share-pdf-button"].tap()
        XCTAssertTrue(app.otherElements["share-sheet"].waitForExistence(timeout: 8))
    }

    func testSharePDFPrintOpensPrinterOptionsWithoutProtectedPDFError() {
        app.buttons["share-pdf-button"].tap()
        XCTAssertTrue(app.otherElements["share-sheet"].waitForExistence(timeout: 8))

        let printAction = app.cells["Print"]
        for _ in 0..<4 where !printAction.isHittable {
            app.swipeLeft()
        }
        XCTAssertTrue(printAction.waitForExistence(timeout: 3))
        printAction.tap()

        XCTAssertFalse(
            app.staticTexts["Protected PDF files can only be printed separately."].waitForExistence(
                timeout: 2
            )
        )
        XCTAssertTrue(app.navigationBars["Options"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["US Letter"].exists)
    }

    func testShareOriginalMarkdownPresentsSystemShareSheet() {
        app.buttons["document-actions-button"].tap()
        XCTAssertTrue(app.buttons["Share Original Markdown"].waitForExistence(timeout: 2))
        app.buttons["Share Original Markdown"].tap()
        XCTAssertTrue(app.otherElements["share-sheet"].waitForExistence(timeout: 5))
    }

    func testFilenameMenuProvidesLocalFileActions() {
        app.buttons["document-actions-button"].tap()
        for name in [
            "Rename",
            "Move",
            "Duplicate",
            "Share Original Markdown",
            "Export PDF",
            "Print",
            "About, Privacy & Support",
        ] {
            XCTAssertTrue(app.buttons[name].exists, "Missing \(name) action")
            XCTAssertTrue(app.buttons[name].isEnabled, "Expected \(name) to be available for the local fixture")
        }
    }

    func testAboutPrivacyAndSupportAreAvailableInsideViewer() {
        app.buttons["document-actions-button"].tap()
        app.buttons["About, Privacy & Support"].tap()

        XCTAssertTrue(app.navigationBars["Markdown Printer"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["About"].exists)
        for _ in 0..<3 where !app.staticTexts["Privacy"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Privacy"].exists)
        XCTAssertTrue(app.buttons["Privacy Policy"].exists)
        for _ in 0..<3 where !app.buttons["Support"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["Support"].exists)

        let information = XCTAttachment(screenshot: app.screenshot())
        information.name = "About privacy and support"
        information.lifetime = .keepAlways
        add(information)

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["document-actions-button"].waitForExistence(timeout: 3))
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

    func testLinkedMarkdownPushesAndBackReturnsToOriginalDocument() {
        let link = app.links["Linked page"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        XCTAssertTrue(app.staticTexts["Linked Markdown Page"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["fixture.md"].exists || app.navigationBars.buttons.element(boundBy: 0).exists)
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

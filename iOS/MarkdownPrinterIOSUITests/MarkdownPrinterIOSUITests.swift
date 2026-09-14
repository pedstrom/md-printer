import XCTest
import UIKit

final class MarkdownPrinterIOSUITests: XCTestCase {
    private var app: XCUIApplication!
    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["iPhone Viewer Fixture"].waitForExistence(timeout: 8))
    }

    func testViewerUsesStaticFilenameTopShareIconAndBottomFindField() {
        XCTAssertTrue(app.staticTexts["fixture.md"].exists)
        XCTAssertFalse(app.buttons["document-actions-button"].exists)
        XCTAssertFalse(app.buttons["info-button"].exists)
        XCTAssertTrue(app.buttons["share-pdf-button"].exists)
        XCTAssertFalse(app.buttons["search-button"].exists)
        XCTAssertTrue(app.textFields["find-field"].exists)
        XCTAssertFalse(app.buttons["Previous result"].exists)
        XCTAssertFalse(app.buttons["Next result"].exists)
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertEqual(app.buttons["share-pdf-button"].label, "Share PDF")
        XCTAssertFalse(app.staticTexts["Share PDF"].exists)
        let portrait = XCTAttachment(screenshot: readerScreenshot())
        portrait.name = isIPad ? "iPad viewer portrait" : "iPhone viewer portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
    }

    func testSearchNavigatesMatchesAndExposesOptions() {
        let search = app.textFields["find-field"]
        XCTAssertTrue(search.exists)
        search.tap()
        if !isIPad { XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3)) }
        XCTAssertTrue(app.buttons["Previous result"].exists)
        XCTAssertTrue(app.buttons["Next result"].exists)
        XCTAssertTrue(app.buttons["Done"].exists)
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
        XCTAssertTrue(app.staticTexts["No Results"].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["find-field"].exists)
        XCTAssertFalse(app.buttons["Previous result"].exists)
        XCTAssertFalse(app.buttons["Next result"].exists)
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertEqual(app.keyboards.count, 0)
    }

    func testSharePDFPreparesNamedPDFForSystemShare() {
        app.buttons["share-pdf-button"].tap()
        XCTAssertTrue(app.staticTexts["PDF Ready to Share"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["fixture.pdf"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["share-pdf-button"].waitForExistence(timeout: 3))
    }

    func testFirstLaunchOffersInformationWithoutASampleButton() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-store-readiness",
            "-ui-testing-cloud-status", "checked"
        ]
        app.launch()

        let informationButton = app.buttons["About, privacy, and support"]
        XCTAssertTrue(informationButton.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Open Markdown Printer sample"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Checked for updates at ")
            ).firstMatch.exists
        )

        let browser = XCTAttachment(screenshot: readerScreenshot())
        browser.name = "First-launch document browser"
        browser.lifetime = .keepAlways
        add(browser)

        informationButton.tap()
        XCTAssertTrue(app.navigationBars["Markdown Printer"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
    }

    func testFilesSentFromAnotherAppOpenFromExternalURLs() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-store-readiness",
            "-ui-testing-cloud-status", "checked"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["About, privacy, and support"].waitForExistence(timeout: 8))
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

    func testDocumentBrowserShowsCloudCheckWithoutReplacingNativeNavigation() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-store-readiness",
            "-ui-testing-cloud-status", "checking"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Checking iCloud…"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Open Markdown Printer sample"].exists)
        XCTAssertTrue(app.buttons["Recents"].exists)
        XCTAssertTrue(app.buttons["Browse"].exists)

        let status = XCTAttachment(screenshot: readerScreenshot())
        status.name = "Document browser checking iCloud"
        status.lifetime = .keepAlways
        add(status)
    }

    func testFailedCloudCheckKeepsFilesAvailableAndOffersRetry() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-store-readiness",
            "-ui-testing-cloud-status", "failed"
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Couldn’t check iCloud — showing available files"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.buttons["Browse"].exists)
        let retry = app.buttons["Retry"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Checking iCloud…"].waitForExistence(timeout: 3))
    }

    func testOpeningCloudDocumentAlwaysOffersAnImmediateWayBack() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing-opening"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Opening…"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Waiting in iCloud.md"].exists)
        let back = app.buttons["browser-back-button"]
        XCTAssertTrue(back.exists)

        let opening = XCTAttachment(screenshot: readerScreenshot())
        opening.name = "Cancellable iCloud document opening"
        opening.lifetime = .keepAlways
        add(opening)

        back.tap()
        XCTAssertTrue(app.staticTexts["opening-dismissed"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Opening…"].exists)
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

    func testLinkedMarkdownSupportsBackSwipesFromBothScreenEdges() throws {
        try XCTSkipIf(isIPad, "Custom screen-edge gestures are iPhone-only; iPad uses native navigation.")
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

    func testMainDocumentSwipeRightMatchesBrowserBackButton() throws {
        try XCTSkipIf(isIPad, "Custom screen-edge gestures are iPhone-only; iPad uses native navigation.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.45))
            )

        XCTAssertTrue(app.staticTexts["Returned to document browser"].waitForExistence(timeout: 5))
    }

    func testPermissionGatedLinkedDocumentRequestsReusableFolderAccess() {
        let link = app.links["Permission-gated page"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()

        XCTAssertTrue(
            app.otherElements["linked-folder-access-picker"].waitForExistence(timeout: 8)
        )
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.swipeDown() }

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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)).tap()
        XCTAssertFalse(app.buttons["share-pdf-button"].waitForExistence(timeout: 1))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)).tap()
        XCTAssertTrue(app.buttons["share-pdf-button"].waitForExistence(timeout: 3))
    }

    func testViewerAdaptsToLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscapeWindow()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["iPhone Viewer Fixture"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["share-pdf-button"].exists)
        let landscape = XCTAttachment(screenshot: readerScreenshot())
        landscape.name = isIPad ? "iPad viewer landscape" : "iPhone viewer landscape"
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

        let table = XCTAttachment(screenshot: readerScreenshot())
        table.name = "Aligned Markdown table"
        table.lifetime = .keepAlways
        add(table)

        let code = app.staticTexts["markdown-code-block"]
        for _ in 0..<4 where !code.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(code.waitForExistence(timeout: 3))
    }

    func testRemoteImageDisplaysAutomaticallyWhenAvailable() {
        let loadedImage = app.images["Network artwork"]
        for _ in 0..<8 where !loadedImage.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(loadedImage.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Tap to download: Network artwork"].exists)

        let loaded = XCTAttachment(screenshot: readerScreenshot())
        loaded.name = "Downloaded remote image from app cache"
        loaded.lifetime = .keepAlways
        add(loaded)
    }

    func testUnreadableLinkedDocumentShowsRecoverableErrorState() {
        let link = app.links["Missing linked file"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        XCTAssertTrue(app.staticTexts["Couldn’t Open Markdown"].waitForExistence(timeout: 6))
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts["Couldn’t Open Markdown"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).exists)
    }

    func testIPadKeyboardFindAndMatchNavigation() throws {
        try XCTSkipUnless(isIPad)
        // Attach Simulator's synthesized hardware keyboard before its first shortcut.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Next result"].waitForExistence(timeout: 3), app.debugDescription)
        app.typeKey("z", modifierFlags: [])
        XCTAssertEqual(app.textFields["find-field"].value as? String, "z")
        app.typeKey("a", modifierFlags: .command)
        app.textFields["find-field"].typeText("exact search phrase")
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 3))
        app.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 3))
        app.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 3))
        // The Simulator reserves Escape for releasing keyboard capture. The native
        // responder's Escape action is exercised separately in the unit suite.
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Next result"].waitForNonExistence(timeout: 3))
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Next result"].waitForExistence(timeout: 3))
    }

    func testIPadRealSharePopoverSurvivesRotationAndDismissal() throws {
        try XCTSkipUnless(isIPad)
        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-real-share"]
        app.launch()
        app.buttons["share-pdf-button"].tap()
        let share = app.cells["Copy"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), app.debugDescription)
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForLandscapeWindow()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: readerScreenshot())
        screenshot.name = "iPad native Share PDF popover"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        if share.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.7)).tap() }
        XCTAssertTrue(app.buttons["share-pdf-button"].isHittable)
        app.buttons["share-pdf-button"].tap()
        XCTAssertTrue(share.waitForExistence(timeout: 5))
    }

    func testIPadNativePrintInterfaceUsesThePDF() throws {
        try XCTSkipUnless(isIPad)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Copies"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Paper Size"].exists)
        let screenshot = XCTAttachment(screenshot: readerScreenshot())
        screenshot.name = "iPad PDF print options"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    func testIPadSupportsUpsideDownPortraitAndLargeText() throws {
        try XCTSkipUnless(isIPad)
        app.terminate()
        app.launchArguments = ["-ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCUIDevice.shared.orientation = .portraitUpsideDown
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["share-pdf-button"].waitForExistence(timeout: 5))
        app.textFields["find-field"].tap()
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.buttons["Search options"].isHittable)
        let screenshot = XCTAttachment(screenshot: readerScreenshot())
        screenshot.name = "iPad accessibility text and upside-down portrait"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIPadLinkedDocumentOffersOpenInNewWindow() throws {
        try XCTSkipUnless(isIPad)
        app.terminate()
        app.launchArguments = ["-ui-testing-windows", "-ui-testing-reset-window", "-ui-testing-cloud-status", "checked"]
        app.launch()
        let link = app.links["Linked page"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
        link.press(forDuration: 1.1)
        let open = app.buttons["Open “linked.markdown” in New Window"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)
        open.tap()
        XCTAssertTrue(app.staticTexts["Linked Markdown Page"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: readerScreenshot())
        screenshot.name = "iPad linked document in its own window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIPadShowcaseAndSaveToFiles() throws {
        try XCTSkipUnless(isIPad)
        app.terminate()
        app.launchArguments = ["-ui-testing-store-readiness", "-ui-testing-cloud-status", "checked"]
        app.launch()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Field Notes.md")
        try Data("""
        # Field Notes

        ## A clearer view of your ideas

        Open a Markdown file, settle into a readable layout, and turn your notes into a polished PDF. Everything is processed on your device.

        ### Ready for the way you work

        - **Read comfortably.** Clear typography and a focused reading column.
        - **Find the detail.** Search without leaving your document.
        - **Keep your place.** Independent windows for separate projects.
        - **Share the result.** A searchable PDF, ready to save or print.

        | Document | Status | Next step |
        | :--- | :--- | :--- |
        | Research notes | Reviewed | Share with the team |
        | Project outline | In progress | Refine the milestones |
        | Weekend checklist | Ready | Print a copy |

        > Good notes make room for the next idea.

        ### A small example

        ```swift
        let ideas = ["Read", "Explore", "Create"]
        for idea in ideas {
            print(idea)
        }
        ```

        Use **Command-F** to find a phrase, or the share icon to save and print.
        """.utf8).write(to: source)
        app.open(source)
        XCTAssertTrue(app.staticTexts["Field Notes"].firstMatch.waitForExistence(timeout: 10))
        let portrait = XCTAttachment(screenshot: readerScreenshot())
        portrait.name = "iPad Field Notes portrait"
        portrait.lifetime = .keepAlways
        add(portrait)
        XCUIDevice.shared.orientation = .landscapeRight
        waitForLandscapeWindow()
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["share-pdf-button"].firstMatch.waitForExistence(timeout: 3))
        let landscape = XCTAttachment(screenshot: readerScreenshot())
        landscape.name = "iPad Field Notes landscape"
        landscape.lifetime = .keepAlways
        add(landscape)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["share-pdf-button"].firstMatch.tap()
        let saveToFiles = app.cells["Save to Files"]
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 8), app.debugDescription)
        saveToFiles.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 8), app.debugDescription)
        let save = XCTAttachment(screenshot: readerScreenshot())
        save.name = "iPad native Save to Files"
        save.lifetime = .keepAlways
        add(save)
        app.buttons["Save"].tap()
        if app.buttons["Replace"].waitForExistence(timeout: 1) { app.buttons["Replace"].tap() }
        XCTAssertTrue(app.buttons["share-pdf-button"].firstMatch.waitForExistence(timeout: 8))
    }

    func testIPadReaderAccessibilityDescriptionsAndHeadings() throws {
        try XCTSkipUnless(isIPad)
        XCTAssertTrue(app.staticTexts["Completed"].exists)
        XCTAssertTrue(app.staticTexts["Not completed"].exists)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait]) { issue in
            // Filenames are user content; the language heuristic rejects the literal .md suffix.
            issue.element?.label == "fixture.md"
        }
    }

    func testIPadDarkReaderKeepsTextSelectable() throws {
        try XCTSkipUnless(isIPad)
        app.terminate()
        app.launchArguments = ["-ui-testing", "-ui-testing-dark"]
        app.launch()
        let paragraph = app.staticTexts["The exact search phrase appears here. The exact search phrase appears twice."]
        XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
        paragraph.press(forDuration: 1.2)
        let copyAvailable = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            app.menuItems["Copy"].exists || app.buttons["Copy"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [copyAvailable], timeout: 3), .completed)
        let screenshot = XCTAttachment(screenshot: readerScreenshot())
        screenshot.name = "iPad dark appearance and text selection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIPadWindowResizingKeepsSearchAndShareUsable() throws {
        try XCTSkipUnless(isIPad)
        let original = app.windows.firstMatch.frame
        addTeardownBlock { [self] in
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            let frame = app.windows.firstMatch.frame
            let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: original.maxX - frame.minX - 2, dy: original.maxY - frame.minY - 2))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995)).press(forDuration: 0.25, thenDragTo: end)
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995))
            .press(forDuration: 0.25, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.60)))
        let resized = app.windows.firstMatch.frame
        XCTAssertLessThan(resized.width, original.width)
        XCTAssertTrue(app.buttons["share-pdf-button"].isHittable)
        app.textFields["find-field"].tap()
        app.textFields["find-field"].typeText("exact search phrase")
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        let screenshot = XCTAttachment(screenshot: readerScreenshot())
        screenshot.name = "iPad narrow window with active Find"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIPadRestoresDocumentAndSearchAfterBackgroundRelaunch() throws {
        try XCTSkipUnless(isIPad)
        app.terminate()
        app.launchArguments = ["-ui-testing-windows", "-ui-testing-reset-window", "-ui-testing-cloud-status", "checked"]
        app.launch()
        let find = app.textFields["find-field"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        find.tap()
        if app.buttons["Clear search"].exists { app.buttons["Clear search"].tap() }
        find.typeText("exact search phrase")
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 4))
        app.buttons["Next result"].tap()
        app.buttons["Done"].tap()
        XCUIDevice.shared.press(.home)
        app.launchArguments.removeAll { $0 == "-ui-testing-reset-window" }
        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["find-field"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["find-field"].firstMatch.value as? String, "exact search phrase")
        app.textFields["find-field"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 4))
    }

    func testIPadSameNamedDocumentsKeepIndependentSearchAndReuseTheirWindows() throws {
        try XCTSkipUnless(isIPad)
        app.terminate()
        app.launchArguments = ["-ui-testing-windows", "-ui-testing-reset-window", "-ui-testing-cloud-status", "checked"]
        app.launch()
        let first = app.links["First Project"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 1.1)
        app.buttons["Open “Report.md” in New Window"].firstMatch.tap()
        var currentWindow = app.windows.containing(.navigationBar, identifier: "Report.md").containing(.staticText, identifier: "First Project").firstMatch
        XCTAssertTrue(currentWindow.waitForExistence(timeout: 10))
        let find = currentWindow.textFields["find-field"].firstMatch
        find.tap()
        find.typeText("alpha")
        currentWindow.buttons["Done"].firstMatch.tap()
        for title in ["Second Project", "First Project", "Second Project"] {
            currentWindow.links["Other Project"].firstMatch.press(forDuration: 1.1)
            app.buttons["Open “Report.md” in New Window"].firstMatch.tap()
            currentWindow = app.windows.containing(.navigationBar, identifier: "Report.md").containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(currentWindow.waitForExistence(timeout: 10))
            XCTAssertEqual(currentWindow.textFields["find-field"].firstMatch.value as? String, title == "First Project" ? "alpha" : "")
        }
    }

    private func readerScreenshot() -> XCUIScreenshot {
        // App-bounded captures crop incorrectly after rotation on the 26.5 iPad
        // runtime. A screen capture also preserves the actual windowing context.
        isIPad ? XCUIScreen.main.screenshot() : app.screenshot()
    }

    private func waitForLandscapeWindow() {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    private func openLinkedMarkdown() {
        let link = app.links["Linked page"]
        XCTAssertTrue(link.waitForExistence(timeout: 4))
        link.tap()
        XCTAssertTrue(app.staticTexts["Linked Markdown Page"].waitForExistence(timeout: 5))
    }
}

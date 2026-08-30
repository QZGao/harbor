import XCTest

@MainActor
final class HarborSettingsUITests: HarborUITestCase {
    func testSettingsTabsAndPersistedGeneralControls() {
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])

        let general = app.scrollViews["settings.general"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 10))
        let startImmediately = general.switches.firstMatch
        XCTAssertTrue(startImmediately.waitForExistence(timeout: 10))
        let originalValue = String(describing: startImmediately.value)
        startImmediately.click()

        let toggleChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let toggle = object as? XCUIElement else { return false }
                return String(describing: toggle.value) != originalValue
            },
            object: startImmediately
        )
        XCTAssertEqual(XCTWaiter.wait(for: [toggleChanged], timeout: 5), .completed)
        let toggledValue = String(describing: startImmediately.value)

        app.typeKey("w", modifierFlags: [.command])
        app.terminate()
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])
        let relaunchedGeneral = app.scrollViews["settings.general"].firstMatch
        XCTAssertTrue(relaunchedGeneral.waitForExistence(timeout: 10))
        XCTAssertEqual(String(describing: relaunchedGeneral.switches.firstMatch.value), toggledValue)

        for tab in ["Downloads", "Torrents", "Bandwidth", "Updates", "Acknowledgments"] {
            let button = app.buttons[tab].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing settings tab \(tab)")
            button.click()
        }
        XCTAssertTrue(app.staticTexts["yt-dlp"].exists)
        XCTAssertTrue(app.staticTexts["Deno"].exists)
    }
}

import XCTest

@MainActor
final class HarborSettingsUITests: HarborUITestCase {
    func testSettingsTabsAndPersistedGeneralControls() {
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])
        XCTAssertTrue(app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch.waitForExistence(timeout: 10))

        let startImmediately = app.checkBoxes["Start downloads immediately"].firstMatch
        XCTAssertTrue(startImmediately.waitForExistence(timeout: 5))
        let originalValue = startImmediately.value as? Int
        startImmediately.click()

        app.typeKey("w", modifierFlags: [.command])
        app.terminate()
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])
        XCTAssertNotEqual(app.checkBoxes["Start downloads immediately"].firstMatch.value as? Int, originalValue)

        for tab in ["Downloads", "Torrents", "Bandwidth", "Updates", "Acknowledgments"] {
            let button = app.buttons[tab].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing settings tab \(tab)")
            button.click()
        }
        XCTAssertTrue(app.staticTexts["yt-dlp"].exists)
        XCTAssertTrue(app.staticTexts["Deno"].exists)
    }
}

import XCTest

@MainActor
final class HarborLaunchUITests: HarborUITestCase {
    func testLaunchNavigationSearchAndAddSheet() {
        launchHarbor()

        XCTAssertEqual(app.windows.count, 1, "Harbor must open one window during UI tests")
        XCTAssertTrue(app.staticTexts["No Downloads Yet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["toolbar.new-download"].exists)
        XCTAssertTrue(app.outlines["harbor.sidebar"].exists || app.otherElements["harbor.sidebar"].exists)

        openAddSheet()
        XCTAssertTrue(app.textFields["add-download.source"].exists)
        XCTAssertTrue(app.buttons["add-download.submit"].exists)
        app.buttons["add-download.cancel"].click()
        XCTAssertFalse(app.otherElements["add-download.sheet"].waitForExistence(timeout: 1))
    }

    func testBatchEntryShowsReadyDuplicateAndUnsupportedCounts() {
        launchHarbor()
        openAddSheet()

        let source = app.textFields["add-download.source"].firstMatch
        source.click()
        source.typeText(
            "\(fixtureURL("/direct/small.bin").absoluteString)\n" +
            "not-a-link\n" +
            "\(fixtureURL("/direct/small.bin").absoluteString)"
        )

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ready'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'duplicate'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'unsupported'")).firstMatch.exists)
    }
}

import XCTest

@MainActor
final class HarborDownloadUITests: HarborUITestCase {
    func testDirectDownloadCompletesWithExpectedChecksum() throws {
        launchHarbor()
        let download = addLink(fixtureURL("/direct/small.bin"))

        waitForStatus("Completed", download: download)
        let file = waitForDownloadedFile(named: "small.bin")
        XCTAssertEqual(
            try sha256(of: file),
            "c057102af0d868b2e267e418e9ccbdb821f265a8860d949d9ae2179963bd2cea"
        )
    }

    func testRedirectAndContentDispositionUseFinalPayload() throws {
        launchHarbor()
        let download = addLink(fixtureURL("/direct/renamed"))

        waitForStatus("Completed", download: download)
        let file = waitForDownloadedFile(named: "Harbor Renamed Fixture.bin")
        XCTAssertEqual(
            try sha256(of: file),
            "c057102af0d868b2e267e418e9ccbdb821f265a8860d949d9ae2179963bd2cea"
        )
    }

    func testRedirectIsFollowedAndRecorded() throws {
        launchHarbor()
        let download = addLink(fixtureURL("/direct/redirect"))

        waitForStatus("Completed", download: download)
        _ = waitForDownloadedFile(named: "small.bin")
        XCTAssertTrue(try fixtureRequests(for: "/direct/redirect").contains { $0.method == "GET" })
        XCTAssertTrue(try fixtureRequests(for: "/direct/small.bin").contains { $0.method == "GET" })
    }

    func testSlowDownloadPausesResumesAndSurvivesRelaunch() throws {
        launchHarbor()
        let download = addLink(fixtureURL("/direct/slow.bin"))
        waitForStatus("Downloading", download: download, timeout: 15)
        selectDownload(named: "slow.bin")

        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.click()
        waitForStatus("Paused", download: download, timeout: 15)

        app.terminate()
        launchHarbor()
        waitForStatus("Paused", download: download, timeout: 15)
        selectDownload(named: "slow.bin")
        let resume = app.buttons["Resume"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.click()

        waitForStatus("Completed", download: download, timeout: 45)
        let file = waitForDownloadedFile(named: "slow.bin", timeout: 10)
        XCTAssertEqual(
            try sha256(of: file),
            "2b07811057df887086f06a67edc6ebf911de8b6741156e7a2eb1416a4b8b1b2e"
        )
        let resumedRequests = try fixtureRequests(for: "/direct/slow.bin").filter { $0.range != nil }
        XCTAssertFalse(resumedRequests.isEmpty, "The resumed transfer did not send a Range header.")
        XCTAssertTrue(resumedRequests.contains { $0.ifRange != nil }, "The resumed transfer did not send If-Range.")
    }

    func testHTTPFailureCanRetryAndRemoveFromList() throws {
        launchHarbor()
        let download = addLink(fixtureURL("/errors/404.bin"))
        waitForStatus("Failed", download: download, timeout: 20)
        selectDownload(named: "404.bin")
        let retry = inspectorPage.primaryAction
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let requestCount = try fixtureRequests(for: "/errors/404.bin").count
        retry.click()
        try waitForFixtureRequestCount(for: "/errors/404.bin", atLeast: requestCount + 1)
        waitForStatus("Failed", download: download, timeout: 20)

        app.menuBars.menuBarItems["Downloads"].click()
        let remove = app.menuItems["Remove Selected from List"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertFalse(app.staticTexts["404.bin"].waitForExistence(timeout: 2))
    }

    func testInvalidAndTruncatedResponsesFailWithoutPublishingFiles() {
        launchHarbor()
        let truncatedDownload = addLink(fixtureURL("/errors/truncated.bin"))
        waitForStatus("Failed", download: truncatedDownload, timeout: 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsURL.appendingPathComponent("truncated.bin").path))

        let badRangeDownload = addLink(fixtureURL("/errors/bad-range.bin"))
        waitForStatus("Failed", download: badRangeDownload, timeout: 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadsURL.appendingPathComponent("bad-range.bin").path))
    }
}

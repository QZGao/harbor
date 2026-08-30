import XCTest

@MainActor
final class HarborMediaTorrentUITests: HarborUITestCase {
    func testLocalMediaPreviewAndDownloadUseBundledRuntime() throws {
        launchHarbor()
        openAddSheet()

        let source = app.textFields["add-download.source"].firstMatch
        source.click()
        source.typeText(fixtureURL("/media/page").absoluteString)

        let tryMedia = app.buttons["add-download.try-as-media"].firstMatch
        XCTAssertTrue(tryMedia.waitForExistence(timeout: 5))
        tryMedia.click()
        XCTAssertTrue(app.staticTexts["Harbor Synthetic Media"].waitForExistence(timeout: 120))

        let submit = app.buttons["add-download.submit"].firstMatch
        XCTAssertTrue(submit.isEnabled)
        let existingDownloads = downloadReferences()
        submit.click()
        let download = waitForNewDownload(excluding: existingDownloads)
        waitForStatus("Completed", download: download, timeout: 120)
        let mediaFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: nil)
                .first { $0.pathExtension.lowercased() == "mp4" }
        )
        XCTAssertEqual(
            try sha256(of: mediaFile),
            ProcessInfo.processInfo.environment["HARBOR_FIXTURE_MEDIA_SHA256"]
        )
    }

    func testRemoteTorrentPreviewSupportsPartialSelection() {
        launchHarbor()
        openAddSheet()

        let source = app.textFields["add-download.source"].firstMatch
        source.click()
        source.typeText(fixtureURL("/torrents/multi.torrent").absoluteString)
        let preview = app.buttons["add-download.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()

        XCTAssertTrue(app.otherElements["torrent-contents.sheet"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Harbor UI Fixture"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '2 files'")).firstMatch.exists)
        app.buttons["torrent-contents.select-none"].click()
        XCTAssertFalse(app.buttons["torrent-contents.add"].isEnabled)
        app.buttons["torrent-contents.select-all"].click()
        XCTAssertTrue(app.buttons["torrent-contents.add"].isEnabled)
    }

    func testMagnetPersistsAsPausedDownload() {
        guard let magnet = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=HarborUITestMagnet") else {
            return XCTFail("Invalid fixture magnet")
        }
        launchHarbor()
        let download = addLink(magnet, startImmediately: false)
        waitForStatus("Paused", download: download)
        XCTAssertTrue(app.staticTexts["HarborUITestMagnet"].exists)

        app.terminate()
        launchHarbor()
        waitForStatus("Paused", download: download)
        XCTAssertTrue(app.staticTexts["HarborUITestMagnet"].exists)
    }

    func testHTMLResponseOffersBrowserContinuation() {
        launchHarbor()
        let download = addLink(fixtureURL("/errors/html.bin"))
        waitForStatus("Browser Session Required", download: download, timeout: 30)
        selectDownload(named: "html.bin")
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        app.buttons["Continue"].click()
        let browser = HarborBrowserPage(app: app)
        XCTAssertTrue(browser.sheet.waitForExistence(timeout: 15))
        let fixtureDownloadLink = app.links["Download fixture"].firstMatch
        XCTAssertTrue(fixtureDownloadLink.waitForExistence(timeout: 15))
        fixtureDownloadLink.click()
        waitForStatus("Completed", download: download, timeout: 30)
        XCTAssertFalse(browser.sheet.waitForExistence(timeout: 2))
    }

    func testWebseedTorrentCompletesWithExpectedPayload() throws {
        launchHarbor()
        openAddSheet()
        addDownloadPage.source.click()
        addDownloadPage.source.typeText(fixtureURL("/torrents/webseed.torrent").absoluteString)
        addDownloadPage.preview.click()
        let torrent = HarborTorrentPreviewPage(app: app)
        XCTAssertTrue(torrent.sheet.waitForExistence(timeout: 15))
        let existingDownloads = downloadReferences()
        torrent.add.click()
        let download = waitForNewDownload(excluding: existingDownloads)
        waitForStatus("Completed", download: download, timeout: 60)
        let file = torrentDownloadsURL.appendingPathComponent("harbor-webseed.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(
            try sha256(of: file),
            "c057102af0d868b2e267e418e9ccbdb821f265a8860d949d9ae2179963bd2cea"
        )
    }
}

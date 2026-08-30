import AppKit
import XCTest

@MainActor
final class HarborSystemUITests: HarborUITestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["HARBOR_UI_ALLOW_SYSTEM_INTEGRATIONS"] == "YES" else {
            throw XCTSkip("Set HARBOR_UI_ALLOW_SYSTEM_INTEGRATIONS=YES to run macOS integration tests.")
        }
        guard ProcessInfo.processInfo.environment["HARBOR_UI_NOTIFICATION_PREAPPROVED"] == "YES" else {
            throw NSError(
                domain: "HarborSystemUITests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Preapprove Harbor notifications and set HARBOR_UI_NOTIFICATION_PREAPPROVED=YES."]
            )
        }
        try super.setUpWithError()
    }

    func testClipboardImportAndExternalTorrentOpen() throws {
        let pasteboard = NSPasteboard.general
        let originalText = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let originalText {
                pasteboard.setString(originalText, forType: .string)
            }
        }

        launchHarbor()
        pasteboard.clearContents()
        pasteboard.setString(fixtureURL("/direct/small.bin").absoluteString, forType: .string)
        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.otherElements["add-download.sheet"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.textFields["add-download.source"].firstMatch.value as? String,
            fixtureURL("/direct/small.bin").absoluteString
        )
        app.buttons["add-download.cancel"].click()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", "co.hapy.harbor", fixtureURL("/torrents/multi.torrent").absoluteString]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(app.otherElements["add-download.sheet"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["add-download.source"].exists)
    }

    func testQuickLookFinderAndNativeFolderPanel() {
        launchHarbor()
        let download = addLink(fixtureURL("/direct/small.bin"))
        waitForStatus("Completed", download: download)
        selectDownload(named: "small.bin")

        let quickLook = app.buttons["Quick Look"].firstMatch
        XCTAssertTrue(quickLook.waitForExistence(timeout: 5))
        quickLook.click()
        app.typeKey(.escape, modifierFlags: [])

        let more = app.buttons["More actions"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.click()
        let reveal = app.menuItems["Reveal in Finder"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: 5))
        reveal.click()

        app.typeKey(",", modifierFlags: [.command])
        let downloadsTab = app.buttons["Downloads"].firstMatch
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 10))
        downloadsTab.click()
        let choose = app.buttons["Choose…"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    func testStartAtLoginAndSparkleStateAreRestored() {
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])

        let startAtLogin = app.checkBoxes["Start at Login"].firstMatch
        XCTAssertTrue(startAtLogin.waitForExistence(timeout: 10))
        let originalLoginValue = startAtLogin.value as? Int
        startAtLogin.click()
        defer {
            if startAtLogin.exists, startAtLogin.value as? Int != originalLoginValue {
                startAtLogin.click()
            }
        }

        let updatesTab = app.buttons["Updates"].firstMatch
        updatesTab.click()
        let automaticChecks = app.checkBoxes["Automatically check for updates"].firstMatch
        XCTAssertTrue(automaticChecks.waitForExistence(timeout: 5))
        let originalUpdateValue = automaticChecks.value as? Int
        automaticChecks.click()
        defer {
            if automaticChecks.exists, automaticChecks.value as? Int != originalUpdateValue {
                automaticChecks.click()
            }
        }

        let check = app.buttons["Check for Updates…"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        if check.isEnabled {
            check.click()
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    func testPreapprovedNotificationIsDelivered() throws {
        let uniqueName = "Harbor Notification \(UUID().uuidString)"
        var components = try XCTUnwrap(URLComponents(url: fixtureURL("/direct/renamed"), resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "name", value: uniqueName)]
        let notificationURL = try XCTUnwrap(components.url)

        launchHarbor(extraArguments: ["--harbor-notifications-enabled"])
        let download = addLink(notificationURL)
        waitForStatus("Completed", download: download)

        let notificationCenter = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
        let notification = notificationCenter.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", uniqueName)
        ).firstMatch
        XCTAssertTrue(notification.waitForExistence(timeout: 15), "The completion notification did not appear.")
        notification.hover()
        let close = notificationCenter.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The test notification could not be closed safely.")
        close.click()
    }
}

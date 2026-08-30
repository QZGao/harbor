import CryptoKit
import Foundation
import XCTest

@MainActor
class HarborUITestCase: XCTestCase {
    struct DownloadReference: Hashable {
        let id: String
    }

    struct FixtureRequest: Decodable {
        let method: String
        let path: String
        let range: String?
        let ifRange: String?
    }
    var app: XCUIApplication!
    var runRoot: URL!
    var downloadsURL: URL!
    var torrentDownloadsURL: URL!
    var watchFolderURL: URL!
    var applicationSupportURL: URL!
    var defaultsSuiteName: String!

    var mainWindow: HarborMainWindowPage { HarborMainWindowPage(app: app) }
    var addDownloadPage: HarborAddDownloadPage { HarborAddDownloadPage(app: app) }
    var downloadTablePage: HarborDownloadTablePage { HarborDownloadTablePage(app: app) }
    var inspectorPage: HarborInspectorPage { HarborInspectorPage(app: app) }

    var fixtureBaseURL: URL {
        guard let value = ProcessInfo.processInfo.environment["HARBOR_FIXTURE_BASE_URL"],
              let url = URL(string: value) else {
            XCTFail("Run through Scripts/run-test-suite.sh so the fixture server is available.")
            return URL(string: "http://127.0.0.1:1")!
        }
        return url
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        let identifier = "\(String(describing: type(of: self))).\(name).\(UUID().uuidString)"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborUITests", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        downloadsURL = runRoot.appendingPathComponent("Downloads", isDirectory: true)
        torrentDownloadsURL = runRoot.appendingPathComponent("TorrentDownloads", isDirectory: true)
        watchFolderURL = runRoot.appendingPathComponent("Watch", isDirectory: true)
        applicationSupportURL = runRoot.appendingPathComponent("ApplicationSupport", isDirectory: true)

        for directory in [downloadsURL!, torrentDownloadsURL!, watchFolderURL!, applicationSupportURL!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        defaultsSuiteName = "co.hapy.harbor.ui-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw XCTSkip("Could not create an isolated defaults suite.")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults.set(downloadsURL.path, forKey: "defaultDestinationPath")
        defaults.set(torrentDownloadsURL.path, forKey: "torrentDestinationPath")
        defaults.set(watchFolderURL.path, forKey: "torrentWatchFolderPath")
        defaults.set(true, forKey: "startDownloadsAutomatically")
        defaults.set(false, forKey: "notificationsEnabled")
        defaults.set(false, forKey: "seedNewTorrents")
        defaults.set(false, forKey: "preventSleepWhileDownloading")
        defaults.synchronize()

        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if testRun?.totalFailureCount ?? 0 > 0 {
            attachDiagnostics()
        }

        app?.terminate()
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let runRoot {
            try? FileManager.default.removeItem(at: runRoot)
        }
        app = nil
        try super.tearDownWithError()
    }

    func launchHarbor(extraArguments: [String] = []) {
        app.launchArguments = [
            "--harbor-ui-testing",
            "--harbor-disable-automatic-update-check",
            "--harbor-never-request-notification-authorization",
            "--harbor-user-defaults-suite",
            defaultsSuiteName,
            "--harbor-application-support-directory",
            applicationSupportURL.path,
            "--harbor-default-destination-path",
            downloadsURL.path,
            "--harbor-torrent-destination-path",
            torrentDownloadsURL.path,
            "--harbor-torrent-watch-folder-path",
            watchFolderURL.path,
        ] + extraArguments
        app.launchEnvironment["HARBOR_FIXTURE_BASE_URL"] = fixtureBaseURL.absoluteString
        app.launch()

        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 15),
            "Harbor did not show its main window."
        )
    }

    func fixtureURL(_ path: String) -> URL {
        fixtureBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func openAddSheet() {
        let button = mainWindow.newDownload
        XCTAssertTrue(button.waitForExistence(timeout: 10), "New Download button is unavailable.")
        button.click()
        XCTAssertTrue(addDownloadPage.sheet.waitForExistence(timeout: 10))
    }

    @discardableResult
    func addLink(_ url: URL, startImmediately: Bool = true) -> DownloadReference {
        let existingDownloads = downloadReferences()
        openAddSheet()
        let source = addDownloadPage.source
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.click()
        source.typeText(url.absoluteString)

        let startToggle = addDownloadPage.startImmediately
        if startToggle.exists, (startToggle.value as? Int == 1) != startImmediately {
            startToggle.click()
        }

        let submit = addDownloadPage.submit
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled)
        submit.click()
        return waitForNewDownload(excluding: existingDownloads)
    }

    func selectDownload(named name: String) {
        let text = downloadTablePage.name(name)
        XCTAssertTrue(text.waitForExistence(timeout: 15), "Download \(name) did not appear.")
        text.click()
    }

    func waitForStatus(
        _ status: String,
        download: DownloadReference,
        timeout: TimeInterval = 30
    ) {
        XCTAssertTrue(
            downloadTablePage.status(status, downloadID: download.id).waitForExistence(timeout: timeout),
            "Status \(status) did not appear for download \(download.id)."
        )
    }

    func downloadReferences() -> Set<DownloadReference> {
        let elements = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'downloads.row.'")
        ).allElementsBoundByIndex
        return Set(elements.compactMap { element in
            let prefix = "downloads.row."
            guard element.identifier.hasPrefix(prefix) else { return nil }
            return DownloadReference(id: String(element.identifier.dropFirst(prefix.count)))
        })
    }

    func waitForNewDownload(
        excluding existingDownloads: Set<DownloadReference>,
        timeout: TimeInterval = 15
    ) -> DownloadReference {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let download = downloadReferences().subtracting(existingDownloads).first {
                return download
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("A new download row did not appear.")
        return DownloadReference(id: "missing")
    }

    func waitForFixtureRequestCount(
        for path: String,
        atLeast expectedCount: Int,
        timeout: TimeInterval = 10
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try fixtureRequests(for: path).count >= expectedCount {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Fixture request count for \(path) did not reach \(expectedCount).")
    }

    func waitForDownloadedFile(named name: String, timeout: TimeInterval = 30) -> URL {
        let url = downloadsURL.appendingPathComponent(name)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Downloaded file did not appear at \(url.path)")
        return url
    }

    func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func fixtureRequests(for path: String) throws -> [FixtureRequest] {
        let logPath = try XCTUnwrap(ProcessInfo.processInfo.environment["HARBOR_FIXTURE_LOG"])
        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        return try contents.split(separator: "\n").map { line in
            try JSONDecoder().decode(FixtureRequest.self, from: Data(line.utf8))
        }.filter { $0.path == path }
    }

    func attachDiagnostics() {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Harbor failure screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(string: app?.debugDescription ?? "Harbor was not launched")
        hierarchy.name = "UI hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let downloadsRecord = applicationSupportURL?
            .appendingPathComponent("Harbor", isDirectory: true)
            .appendingPathComponent("downloads.json")
        if let downloadsRecord, FileManager.default.fileExists(atPath: downloadsRecord.path) {
            let attachment = XCTAttachment(contentsOfFile: downloadsRecord)
            attachment.name = "downloads.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        if let fixtureLog = ProcessInfo.processInfo.environment["HARBOR_FIXTURE_LOG"] {
            let url = URL(fileURLWithPath: fixtureLog)
            if FileManager.default.fileExists(atPath: url.path) {
                let attachment = XCTAttachment(contentsOfFile: url)
                attachment.name = "fixture-server.jsonl"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}

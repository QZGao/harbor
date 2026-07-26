import Foundation
import XCTest
@testable import Harbor

@MainActor
final class AppSettingsAndTorrentWatchTests: XCTestCase {
    func testLegacySettingsReceiveTorrentAutomationDefaults() {
        let suiteName = "HarborTests.Settings.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let regularDestinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        userDefaults.set(regularDestinationURL.path, forKey: "defaultDestinationPath")

        let settings = AppSettingsStore(userDefaults: userDefaults)
        let downloadsURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        XCTAssertFalse(settings.torrentWatchFolderEnabled)
        XCTAssertEqual(settings.torrentWatchFolderURL.standardizedFileURL, downloadsURL.standardizedFileURL)
        XCTAssertTrue(settings.seedNewTorrents)
        XCTAssertEqual(
            settings.torrentDestinationURL.standardizedFileURL,
            regularDestinationURL
                .appendingPathComponent("Torrents", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertFalse(settings.globalUploadSpeedLimitEnabled)
        XCTAssertFalse(settings.perDownloadUploadSpeedLimitEnabled)
        XCTAssertNil(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond)
        XCTAssertNil(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond)
    }

    func testDisabledUploadLimitsRetainTheirSavedValues() {
        let suiteName = "HarborTests.UploadLimits.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.globalUploadSpeedLimitKilobytesPerSecond = 900
        settings.perDownloadUploadSpeedLimitKilobytesPerSecond = 300
        settings.globalUploadSpeedLimitEnabled = true
        settings.perDownloadUploadSpeedLimitEnabled = true

        XCTAssertEqual(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond, 900 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond, 300 * 1_024)

        settings.globalUploadSpeedLimitEnabled = false
        settings.perDownloadUploadSpeedLimitEnabled = false

        let restoredSettings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(restoredSettings.globalUploadSpeedLimitEnabled)
        XCTAssertFalse(restoredSettings.perDownloadUploadSpeedLimitEnabled)
        XCTAssertEqual(restoredSettings.globalUploadSpeedLimitKilobytesPerSecond, 900)
        XCTAssertEqual(restoredSettings.perDownloadUploadSpeedLimitKilobytesPerSecond, 300)
        XCTAssertNil(restoredSettings.transferSettings.globalUploadSpeedLimitBytesPerSecond)
        XCTAssertNil(restoredSettings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond)
    }

    func testExistingTorrentIsEmittedOnlyAfterTwoStableScans() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let torrentURL = directoryURL.appendingPathComponent("existing.torrent")
        try Data("stable torrent".utf8).write(to: torrentURL)

        let debounceInterval: TimeInterval = 0.08
        let service = TorrentWatchFolderService(
            fileManager: fileManager,
            debounceInterval: debounceInterval,
            retryInterval: 0.05
        )
        defer {
            service.stop()
            try? fileManager.removeItem(at: directoryURL)
        }

        let emitted = expectation(description: "Existing stable torrent emitted")
        let startedAt = Date()
        var emittedURLs: [URL] = []
        var elapsedAtEmission: TimeInterval?
        service.start(watching: directoryURL) { candidateURL in
            emittedURLs.append(candidateURL)
            elapsedAtEmission = Date().timeIntervalSince(startedAt)
            emitted.fulfill()
        }

        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(emittedURLs.isEmpty)

        await fulfillment(of: [emitted], timeout: 1)
        XCTAssertEqual(emittedURLs, [torrentURL.standardizedFileURL])
        XCTAssertGreaterThanOrEqual(elapsedAtEmission ?? 0, debounceInterval * 0.75)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(emittedURLs.count, 1)
    }

    func testLiveTorrentIsEmittedWhileSubdirectoryTorrentIsIgnored() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let nestedDirectoryURL = directoryURL.appendingPathComponent("Nested", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectoryURL, withIntermediateDirectories: true)
        let nestedTorrentURL = nestedDirectoryURL.appendingPathComponent("ignored.torrent")
        try Data("nested torrent".utf8).write(to: nestedTorrentURL)

        let service = TorrentWatchFolderService(
            fileManager: fileManager,
            debounceInterval: 0.05,
            retryInterval: 0.05
        )
        defer {
            service.stop()
            try? fileManager.removeItem(at: directoryURL)
        }

        let emitted = expectation(description: "Live torrent emitted")
        var emittedURLs: [URL] = []
        service.start(watching: directoryURL) { candidateURL in
            emittedURLs.append(candidateURL)
            emitted.fulfill()
        }

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertTrue(emittedURLs.isEmpty)

        let liveTorrentURL = directoryURL.appendingPathComponent("live.torrent")
        try Data("live torrent".utf8).write(to: liveTorrentURL)

        await fulfillment(of: [emitted], timeout: 1)
        XCTAssertEqual(emittedURLs, [liveTorrentURL.standardizedFileURL])

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(emittedURLs.count, 1)
    }
}

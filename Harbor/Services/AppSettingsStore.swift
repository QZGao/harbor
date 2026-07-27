import AppKit
import Foundation
import Observation

struct DownloadTransferSettings: Equatable, Sendable {
    nonisolated static var `default`: DownloadTransferSettings {
        DownloadTransferSettings(
            maxConcurrentDownloads: 3,
            globalSpeedLimitBytesPerSecond: nil,
            perDownloadSpeedLimitBytesPerSecond: nil,
            globalUploadSpeedLimitBytesPerSecond: nil,
            perDownloadUploadSpeedLimitBytesPerSecond: nil,
            perDownloadConnectionCount: 4
        )
    }

    let maxConcurrentDownloads: Int
    let globalSpeedLimitBytesPerSecond: Int64?
    let perDownloadSpeedLimitBytesPerSecond: Int64?
    let globalUploadSpeedLimitBytesPerSecond: Int64?
    let perDownloadUploadSpeedLimitBytesPerSecond: Int64?
    let perDownloadConnectionCount: Int
}

@Observable
@MainActor
final class AppSettingsStore {
    private enum Keys {
        static let defaultDestinationPath = "defaultDestinationPath"
        static let torrentDestinationPath = "torrentDestinationPath"
        static let torrentWatchFolderPath = "torrentWatchFolderPath"
        static let torrentWatchFolderEnabled = "torrentWatchFolderEnabled"
        static let seedNewTorrents = "seedNewTorrents"
        static let maxConcurrentDownloads = "maxConcurrentDownloads"
        static let startDownloadsAutomatically = "startDownloadsAutomatically"
        static let notificationsEnabled = "notificationsEnabled"
        static let globalSpeedLimitEnabled = "globalSpeedLimitEnabled"
        static let globalSpeedLimitKilobytesPerSecond = "globalSpeedLimitKilobytesPerSecond"
        static let perDownloadSpeedLimitEnabled = "perDownloadSpeedLimitEnabled"
        static let perDownloadSpeedLimitKilobytesPerSecond = "perDownloadSpeedLimitKilobytesPerSecond"
        static let globalUploadSpeedLimitEnabled = "globalUploadSpeedLimitEnabled"
        static let globalUploadSpeedLimitKilobytesPerSecond = "globalUploadSpeedLimitKilobytesPerSecond"
        static let perDownloadUploadSpeedLimitEnabled = "perDownloadUploadSpeedLimitEnabled"
        static let perDownloadUploadSpeedLimitKilobytesPerSecond = "perDownloadUploadSpeedLimitKilobytesPerSecond"
        static let perDownloadConnectionCount = "perDownloadConnectionCount"
    }

    static let maxConcurrentDownloadsRange = 1 ... 16
    static let perDownloadConnectionCountRange = 1 ... 16
    static let speedLimitKilobytesRange = 1 ... 1_048_576

    private let userDefaults: UserDefaults
    @ObservationIgnored var transferSettingsDidChange: ((DownloadTransferSettings) -> Void)?
    @ObservationIgnored var torrentAutomationSettingsDidChange: (() -> Void)?

    var defaultDestinationPath: String {
        didSet {
            userDefaults.set(defaultDestinationPath, forKey: Keys.defaultDestinationPath)
        }
    }

    var torrentDestinationPath: String {
        didSet {
            userDefaults.set(torrentDestinationPath, forKey: Keys.torrentDestinationPath)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    var torrentWatchFolderPath: String {
        didSet {
            userDefaults.set(torrentWatchFolderPath, forKey: Keys.torrentWatchFolderPath)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    var torrentWatchFolderEnabled: Bool {
        didSet {
            userDefaults.set(torrentWatchFolderEnabled, forKey: Keys.torrentWatchFolderEnabled)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    var seedNewTorrents: Bool {
        didSet {
            userDefaults.set(seedNewTorrents, forKey: Keys.seedNewTorrents)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    private(set) var torrentWatchFolderStatus: TorrentWatchFolderStatus = .stopped

    var maxConcurrentDownloads: Int {
        didSet {
            userDefaults.set(maxConcurrentDownloads, forKey: Keys.maxConcurrentDownloads)
            notifyTransferSettingsChanged()
        }
    }

    var startDownloadsAutomatically: Bool {
        didSet {
            userDefaults.set(startDownloadsAutomatically, forKey: Keys.startDownloadsAutomatically)
        }
    }

    var notificationsEnabled: Bool {
        didSet {
            userDefaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        }
    }

    var globalSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(globalSpeedLimitEnabled, forKey: Keys.globalSpeedLimitEnabled)
            notifyTransferSettingsChanged()
        }
    }

    var globalSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(globalSpeedLimitKilobytesPerSecond, forKey: Keys.globalSpeedLimitKilobytesPerSecond)
            notifyTransferSettingsChanged()
        }
    }

    var perDownloadSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(perDownloadSpeedLimitEnabled, forKey: Keys.perDownloadSpeedLimitEnabled)
            notifyTransferSettingsChanged()
        }
    }

    var perDownloadSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(perDownloadSpeedLimitKilobytesPerSecond, forKey: Keys.perDownloadSpeedLimitKilobytesPerSecond)
            notifyTransferSettingsChanged()
        }
    }

    var globalUploadSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(globalUploadSpeedLimitEnabled, forKey: Keys.globalUploadSpeedLimitEnabled)
            notifyTransferSettingsChanged()
        }
    }

    var globalUploadSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(
                globalUploadSpeedLimitKilobytesPerSecond,
                forKey: Keys.globalUploadSpeedLimitKilobytesPerSecond
            )
            notifyTransferSettingsChanged()
        }
    }

    var perDownloadUploadSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(perDownloadUploadSpeedLimitEnabled, forKey: Keys.perDownloadUploadSpeedLimitEnabled)
            notifyTransferSettingsChanged()
        }
    }

    var perDownloadUploadSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(
                perDownloadUploadSpeedLimitKilobytesPerSecond,
                forKey: Keys.perDownloadUploadSpeedLimitKilobytesPerSecond
            )
            notifyTransferSettingsChanged()
        }
    }

    var perDownloadConnectionCount: Int {
        didSet {
            userDefaults.set(perDownloadConnectionCount, forKey: Keys.perDownloadConnectionCount)
            notifyTransferSettingsChanged()
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let defaultDownloadsPath = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first?.path ?? NSHomeDirectory()

        let regularDestinationPath = userDefaults.string(forKey: Keys.defaultDestinationPath) ?? defaultDownloadsPath
        self.defaultDestinationPath = regularDestinationPath
        self.torrentDestinationPath = userDefaults.string(forKey: Keys.torrentDestinationPath)
            ?? URL(fileURLWithPath: regularDestinationPath, isDirectory: true)
                .appendingPathComponent("Torrents", isDirectory: true)
                .path
        self.torrentWatchFolderPath = userDefaults.string(forKey: Keys.torrentWatchFolderPath)
            ?? defaultDownloadsPath
        self.torrentWatchFolderEnabled = userDefaults.bool(forKey: Keys.torrentWatchFolderEnabled)
        if userDefaults.object(forKey: Keys.seedNewTorrents) == nil {
            self.seedNewTorrents = true
        } else {
            self.seedNewTorrents = userDefaults.bool(forKey: Keys.seedNewTorrents)
        }

        let storedConcurrency = userDefaults.integer(forKey: Keys.maxConcurrentDownloads)
        self.maxConcurrentDownloads = Self.clamped(
            storedConcurrency == 0 ? 3 : storedConcurrency,
            to: Self.maxConcurrentDownloadsRange
        )

        if userDefaults.object(forKey: Keys.startDownloadsAutomatically) == nil {
            self.startDownloadsAutomatically = true
        } else {
            self.startDownloadsAutomatically = userDefaults.bool(forKey: Keys.startDownloadsAutomatically)
        }

        if userDefaults.object(forKey: Keys.notificationsEnabled) == nil {
            self.notificationsEnabled = true
        } else {
            self.notificationsEnabled = userDefaults.bool(forKey: Keys.notificationsEnabled)
        }

        self.globalSpeedLimitEnabled = userDefaults.bool(forKey: Keys.globalSpeedLimitEnabled)
        self.globalSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.globalSpeedLimitKilobytesPerSecond) == 0
                ? 25 * 1_024
                : userDefaults.integer(forKey: Keys.globalSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        self.perDownloadSpeedLimitEnabled = userDefaults.bool(forKey: Keys.perDownloadSpeedLimitEnabled)
        self.perDownloadSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.perDownloadSpeedLimitKilobytesPerSecond) == 0
                ? 5 * 1_024
                : userDefaults.integer(forKey: Keys.perDownloadSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        self.globalUploadSpeedLimitEnabled = userDefaults.bool(forKey: Keys.globalUploadSpeedLimitEnabled)
        self.globalUploadSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.globalUploadSpeedLimitKilobytesPerSecond) == 0
                ? 5 * 1_024
                : userDefaults.integer(forKey: Keys.globalUploadSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        self.perDownloadUploadSpeedLimitEnabled = userDefaults.bool(
            forKey: Keys.perDownloadUploadSpeedLimitEnabled
        )
        self.perDownloadUploadSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.perDownloadUploadSpeedLimitKilobytesPerSecond) == 0
                ? 1_024
                : userDefaults.integer(forKey: Keys.perDownloadUploadSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        let storedConnectionCount = userDefaults.integer(forKey: Keys.perDownloadConnectionCount)
        self.perDownloadConnectionCount = Self.clamped(
            storedConnectionCount == 0 ? 4 : storedConnectionCount,
            to: Self.perDownloadConnectionCountRange
        )
    }

    var defaultDestinationURL: URL {
        URL(fileURLWithPath: defaultDestinationPath, isDirectory: true)
    }

    var torrentDestinationURL: URL {
        URL(fileURLWithPath: torrentDestinationPath, isDirectory: true)
    }

    var torrentWatchFolderURL: URL {
        URL(fileURLWithPath: torrentWatchFolderPath, isDirectory: true)
    }

    var transferSettings: DownloadTransferSettings {
        DownloadTransferSettings(
            maxConcurrentDownloads: Self.clamped(maxConcurrentDownloads, to: Self.maxConcurrentDownloadsRange),
            globalSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: globalSpeedLimitEnabled,
                kilobytesPerSecond: globalSpeedLimitKilobytesPerSecond
            ),
            perDownloadSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: perDownloadSpeedLimitEnabled,
                kilobytesPerSecond: perDownloadSpeedLimitKilobytesPerSecond
            ),
            globalUploadSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: globalUploadSpeedLimitEnabled,
                kilobytesPerSecond: globalUploadSpeedLimitKilobytesPerSecond
            ),
            perDownloadUploadSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: perDownloadUploadSpeedLimitEnabled,
                kilobytesPerSecond: perDownloadUploadSpeedLimitKilobytesPerSecond
            ),
            perDownloadConnectionCount: Self.clamped(
                perDownloadConnectionCount,
                to: Self.perDownloadConnectionCountRange
            )
        )
    }

    static func clampedSpeedLimitKilobytes(_ value: Int) -> Int {
        clamped(value, to: speedLimitKilobytesRange)
    }

    func chooseDefaultDestination() {
        guard let folder = FolderSelectionService.chooseFolder(startingAt: defaultDestinationURL) else {
            return
        }

        defaultDestinationPath = folder.path
    }

    func revealDefaultDestination() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: defaultDestinationPath)
    }

    func chooseTorrentDestination() {
        guard let folder = FolderSelectionService.chooseFolder(startingAt: torrentDestinationURL) else {
            return
        }

        torrentDestinationPath = folder.path
    }

    func revealTorrentDestination() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: torrentDestinationPath)
    }

    func chooseTorrentWatchFolder() {
        guard let folder = FolderSelectionService.chooseFolder(startingAt: torrentWatchFolderURL) else {
            return
        }

        torrentWatchFolderPath = folder.path
    }

    func revealTorrentWatchFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: torrentWatchFolderPath)
    }

    func updateTorrentWatchFolderStatus(_ status: TorrentWatchFolderStatus) {
        torrentWatchFolderStatus = status
    }

    private func notifyTransferSettingsChanged() {
        transferSettingsDidChange?(transferSettings)
    }

    private func notifyTorrentAutomationSettingsChanged() {
        torrentAutomationSettingsDidChange?()
    }

    private func speedLimitBytesPerSecond(
        isEnabled: Bool,
        kilobytesPerSecond: Int
    ) -> Int64? {
        guard isEnabled else {
            return nil
        }

        return Int64(Self.clampedSpeedLimitKilobytes(kilobytesPerSecond)) * 1_024
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

import Foundation

enum HarborTestRuntime {
    nonisolated static let isUITesting = CommandLine.arguments.contains("--harbor-ui-testing")

    nonisolated static let disablesAutomaticUpdateCheck = CommandLine.arguments.contains(
        "--harbor-disable-automatic-update-check"
    )

    nonisolated static let preventsNotificationAuthorizationRequest = CommandLine.arguments.contains(
        "--harbor-never-request-notification-authorization"
    )

    static let userDefaults: UserDefaults = {
        guard isUITesting else {
            return .standard
        }

        let suiteName = argumentValue(after: "--harbor-user-defaults-suite")
            ?? "co.hapy.harbor.ui-tests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Harbor UI tests require an isolated user defaults suite.")
        }
        guard let defaultDestinationPath = argumentValue(after: "--harbor-default-destination-path"),
              let torrentDestinationPath = argumentValue(after: "--harbor-torrent-destination-path"),
              let torrentWatchFolderPath = argumentValue(after: "--harbor-torrent-watch-folder-path") else {
            preconditionFailure("Harbor UI tests require isolated download and watch-folder paths.")
        }

        userDefaults.set(defaultDestinationPath, forKey: "defaultDestinationPath")
        userDefaults.set(torrentDestinationPath, forKey: "torrentDestinationPath")
        userDefaults.set(torrentWatchFolderPath, forKey: "torrentWatchFolderPath")
        if userDefaults.object(forKey: "startDownloadsAutomatically") == nil {
            userDefaults.set(true, forKey: "startDownloadsAutomatically")
        }
        if CommandLine.arguments.contains("--harbor-notifications-enabled") {
            userDefaults.set(true, forKey: "notificationsEnabled")
        } else if userDefaults.object(forKey: "notificationsEnabled") == nil {
            userDefaults.set(false, forKey: "notificationsEnabled")
        }
        if userDefaults.object(forKey: "seedNewTorrents") == nil {
            userDefaults.set(false, forKey: "seedNewTorrents")
        }
        if userDefaults.object(forKey: "preventSleepWhileDownloading") == nil {
            userDefaults.set(false, forKey: "preventSleepWhileDownloading")
        }
        return userDefaults
    }()

    private nonisolated static func argumentValue(after argument: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: argument) else {
            return nil
        }

        let valueIndex = CommandLine.arguments.index(after: index)
        guard CommandLine.arguments.indices.contains(valueIndex) else {
            return nil
        }

        let value = CommandLine.arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

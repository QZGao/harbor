import SwiftUI

struct GeneralSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Behavior") {
                Toggle("Start downloads immediately", isOn: $settings.startDownloadsAutomatically)
                Toggle("Send download notifications", isOn: $settings.notificationsEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

struct DownloadsSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        Form {
            Section("Save Locations") {
                DestinationFolderRow(
                    title: "Regular Downloads",
                    path: settings.defaultDestinationPath,
                    choose: settings.chooseDefaultDestination,
                    reveal: settings.revealDefaultDestination
                )

                DestinationFolderRow(
                    title: "Torrent Downloads",
                    path: settings.torrentDestinationPath,
                    choose: settings.chooseTorrentDestination,
                    reveal: settings.revealTorrentDestination
                )
            }
        }
        .formStyle(.grouped)
    }
}

struct TorrentsSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Automation") {
                Toggle("Watch a folder for torrent files", isOn: $settings.torrentWatchFolderEnabled)

                DestinationFolderRow(
                    title: "Watch Folder",
                    path: settings.torrentWatchFolderPath,
                    choose: settings.chooseTorrentWatchFolder,
                    reveal: settings.revealTorrentWatchFolder
                )

                if settings.torrentWatchFolderEnabled {
                    TorrentWatchStatusRow(status: settings.torrentWatchFolderStatus)
                }
            }

            Section("Seeding") {
                Toggle("Seed new torrents after downloading", isOn: $settings.seedNewTorrents)
            }
        }
        .formStyle(.grouped)
    }
}

struct BandwidthSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Connections") {
                Stepper(
                    value: $settings.maxConcurrentDownloads,
                    in: AppSettingsStore.maxConcurrentDownloadsRange
                ) {
                    LabeledContent("Max Active Downloads", value: "\(settings.maxConcurrentDownloads)")
                }

                Stepper(
                    value: $settings.perDownloadConnectionCount,
                    in: AppSettingsStore.perDownloadConnectionCountRange
                ) {
                    LabeledContent("Connections per Download", value: "\(settings.perDownloadConnectionCount)")
                }
            }

            Section("Download Limits") {
                SpeedLimitRow(
                    title: "Global Download Limit",
                    isEnabled: $settings.globalSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.globalSpeedLimitKilobytesPerSecond
                )

                SpeedLimitRow(
                    title: "Default Download Limit",
                    isEnabled: $settings.perDownloadSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.perDownloadSpeedLimitKilobytesPerSecond
                )
            }

            Section("Upload Limits") {
                SpeedLimitRow(
                    title: "Global Upload Limit",
                    isEnabled: $settings.globalUploadSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.globalUploadSpeedLimitKilobytesPerSecond
                )

                SpeedLimitRow(
                    title: "Default Torrent Upload Limit",
                    isEnabled: $settings.perDownloadUploadSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.perDownloadUploadSpeedLimitKilobytesPerSecond
                )
            }
        }
        .formStyle(.grouped)
    }
}

struct UpdatesSettingsTab: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section("Software Update") {
                LabeledContent("Current Version") {
                    Text(updater.currentVersionLabel)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                LabeledContent {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.canCheckForUpdates == false)
                } label: {
                    Text("Updates")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DestinationFolderRow: View {
    let title: LocalizedStringResource
    let path: String
    let choose: () -> Void
    let reveal: () -> Void

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 8) {
                Text(path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)

                HStack(spacing: 8) {
                    Button("Choose…", action: choose)
                    Button("Reveal", action: reveal)
                }
            }
            .frame(maxWidth: 390, alignment: .trailing)
        } label: {
            Text(title)
        }
    }
}

private struct TorrentWatchStatusRow: View {
    let status: TorrentWatchFolderStatus

    var body: some View {
        LabeledContent("Status") {
            Label(message, systemImage: symbolName)
                .foregroundStyle(foregroundStyle)
        }
    }

    private var message: LocalizedStringResource {
        switch status {
        case .stopped:
            "Waiting for the watcher to start"
        case .watching:
            "Watching for new torrent files"
        case .unavailable:
            "Folder unavailable; Harbor will retry"
        }
    }

    private var symbolName: String {
        switch status {
        case .stopped:
            "clock"
        case .watching:
            "eye"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var foregroundStyle: Color {
        switch status {
        case .stopped:
            .secondary
        case .watching:
            .green
        case .unavailable:
            .orange
        }
    }
}

private struct SpeedLimitRow: View {
    let title: LocalizedStringResource
    @Binding var isEnabled: Bool
    @Binding var kilobytesPerSecond: Int

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Toggle("Limit", isOn: $isEnabled)
                    .labelsHidden()

                TextField(
                    "Speed",
                    value: $kilobytesPerSecond,
                    format: .number
                )
                .monospacedDigit()
                .frame(width: 110)
                .disabled(isEnabled == false)

                Text("KB/s")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
                .lineLimit(1)
        }
        .onChange(of: kilobytesPerSecond) { _, newValue in
            let clampedValue = AppSettingsStore.clampedSpeedLimitKilobytes(newValue)
            if clampedValue != newValue {
                kilobytesPerSecond = clampedValue
            }
        }
    }
}

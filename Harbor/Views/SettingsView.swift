import SwiftUI

struct SettingsView: View {
    let settings: AppSettingsStore
    @ObservedObject var updater: AppUpdater

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            DownloadsSettingsTab(settings: settings)
                .tabItem {
                    Label("Downloads", systemImage: "folder")
                }

            TorrentsSettingsTab(settings: settings)
                .tabItem {
                    Label("Torrents", systemImage: "arrow.up.arrow.down.circle")
                }

            BandwidthSettingsTab(settings: settings)
                .tabItem {
                    Label("Bandwidth", systemImage: "speedometer")
                }

            UpdatesSettingsTab(updater: updater)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }

            AcknowledgmentsSettingsTab()
                .tabItem {
                    Label("Acknowledgments", systemImage: "info.circle")
                }
        }
        .frame(width: 640, height: 460)
        .scenePadding()
    }
}

#Preview("Settings") {
    SettingsView(
        settings: HarborPreviewFixtures.makeSettings(),
        updater: AppUpdater.preview()
    )
}

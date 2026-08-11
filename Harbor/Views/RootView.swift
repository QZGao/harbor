import Foundation
import SwiftUI

struct RootView: View {
    let center: DownloadCenter
    let settings: AppSettingsStore
    @State private var isDownloadDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    private enum Layout {
        static let sidebarMinWidth: CGFloat = 200
        static let sidebarIdealWidth: CGFloat = 230
        static let sidebarMaxWidth: CGFloat = 280
        static let contentMinWidth: CGFloat = 500
        static let contentIdealWidth: CGFloat = 680
        static let inspectorMinWidth: CGFloat = 300
        static let inspectorIdealWidth: CGFloat = 340
        static let inspectorMaxWidth: CGFloat = 440
    }

    var body: some View {
        @Bindable var center = center

        NavigationSplitView {
            SidebarView(center: center)
                .navigationSplitViewColumnWidth(
                    min: Layout.sidebarMinWidth,
                    ideal: Layout.sidebarIdealWidth,
                    max: Layout.sidebarMaxWidth
                )
        } detail: {
            DownloadsContentView(center: center)
                .navigationSplitViewColumnWidth(
                    min: Layout.contentMinWidth,
                    ideal: Layout.contentIdealWidth
                )
                .inspector(isPresented: inspectorPresentation) {
                    DownloadDetailView(center: center)
                        .inspectorColumnWidth(
                            min: Layout.inspectorMinWidth,
                            ideal: Layout.inspectorIdealWidth,
                            max: Layout.inspectorMaxWidth
                        )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $center.searchText, placement: .toolbar, prompt: "Search downloads")
        .searchFocused($isSearchFocused)
        .focusedSceneValue(\.focusDownloadSearch, focusSearch)
        .sheet(item: $center.addSheetDraft, onDismiss: {
            center.handleAddSheetDismissal()
        }) { draft in
            AddDownloadSheet(
                settings: settings,
                draft: draft,
                mediaPreviewProvider: { url in
                    try await center.previewMediaDownload(for: url)
                }
            ) { request in
                center.queueDownload(request)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { center.activeBrowserSession != nil },
                set: { isPresented in
                    if isPresented == false {
                        center.dismissBrowserSession()
                    }
                }
            )
        ) {
            if let session = center.activeBrowserSession {
                BrowserDownloadSheet(center: center, session: session)
            }
        }
        .alert(
            center.activeAlert?.title ?? "Alert",
            isPresented: Binding(
                get: { center.activeAlert != nil },
                set: { isPresented in
                    if isPresented == false {
                        center.activeAlert = nil
                    }
                }
            )
        ) {
            if center.canRetryInitialization {
                Button("Retry") {
                    center.activeAlert = nil
                    Task {
                        await center.initializeIfNeeded()
                    }
                }
            } else {
                Button("OK", role: .cancel) {
                    center.activeAlert = nil
                }
            }
        } message: {
            Text(center.activeAlert?.message ?? "")
        }
        // TODO: Revisit customizable toolbars after macOS 26 stops crashing while restoring toolbar items during file opens.
        .toolbar {
            DownloadToolbarContent(center: center, settings: settings)
        }
        .onDrop(
            of: DownloadSourceImportService.supportedContentTypes,
            isTargeted: $isDownloadDropTargeted,
            perform: loadExternalAddSources
        )
        .onPasteCommand(of: DownloadSourceImportService.supportedContentTypes) { providers in
            _ = loadExternalAddSources(providers)
        }
        .overlay {
            if isDownloadDropTargeted {
                DownloadDropTargetOverlay()
                    .allowsHitTesting(false)
            }
        }
    }

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { center.selectedDownload != nil },
            set: { isPresented in
                if isPresented == false {
                    center.selectedDownloadIDs = []
                }
            }
        )
    }

    private func loadExternalAddSources(_ providers: [NSItemProvider]) -> Bool {
        DownloadSourceImportService.loadSupportedURLs(from: providers) { urls in
            center.receiveExternalAddSources(urls)
        }
    }

    private func focusSearch() {
        isSearchFocused = true
    }
}

private struct DownloadDropTargetOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.04))

            Label("Drop to Add Download", systemImage: "arrow.down.doc")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.quaternary)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(14)
        }
    }
}

private struct DownloadToolbarContent: ToolbarContent {
    @Bindable var center: DownloadCenter
    @Bindable var settings: AppSettingsStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("New Download", systemImage: "plus") {
                center.presentAddSheet()
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button(
                center.hasActiveDownloads ? "Pause All" : "Resume All",
                systemImage: center.hasActiveDownloads ? "pause.fill" : "play.fill"
            ) {
                if center.hasActiveDownloads {
                    center.pauseAll()
                } else {
                    center.resumeAll()
                }
            }
            .disabled(
                center.hasActiveDownloads
                    ? center.hasPausableDownloads == false
                    : center.hasResumableDownloads == false
            )
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("Limit Downloads", isOn: $settings.globalSpeedLimitEnabled)

                Text(
                    settings.globalSpeedLimitEnabled
                        ? DownloadFormatting.speedString(Double(settings.globalSpeedLimitKilobytesPerSecond) * 1_024)
                        : String(localized: "Unlimited")
                )
                .foregroundStyle(.secondary)

                Divider()

                Toggle("Limit Uploads", isOn: $settings.globalUploadSpeedLimitEnabled)

                Text(
                    settings.globalUploadSpeedLimitEnabled
                        ? DownloadFormatting.speedString(Double(settings.globalUploadSpeedLimitKilobytesPerSecond) * 1_024)
                        : String(localized: "Unlimited")
                )
                .foregroundStyle(.secondary)

                Divider()

                SettingsLink {
                    Label("Edit Limits…", systemImage: "gearshape")
                }
            } label: {
                Label("Speed Limits", systemImage: "speedometer")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button("Reveal", systemImage: "folder") {
                center.revealSelectedInFinder()
            }
            .disabled(center.selectedDownload == nil)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $center.sortMode) {
                    ForEach(DownloadSortMode.allCases) { sortMode in
                        Text(sortMode.title).tag(sortMode)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down.circle")
            }
            .disabled(center.downloads.isEmpty)
        }
    }
}

#Preview("Harbor Window") {
    let settings = HarborPreviewFixtures.makeSettings()
    let center = HarborPreviewFixtures.makeCenter()

    RootView(center: center, settings: settings)
        .frame(width: 1_320, height: 820)
}

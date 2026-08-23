import SwiftUI

struct DownloadsContentView: View {
    let center: DownloadCenter

    @AppStorage("downloads.table.columnCustomization")
    private var columnCustomization = TableColumnCustomization<DownloadItem>()
    @State private var pendingDataRemovalIDs: Set<UUID> = []

    var body: some View {
        @Bindable var center = center

        VStack(spacing: 0) {
            if center.filteredDownloads.isEmpty {
                emptyState
            } else {
                Table(
                    of: DownloadItem.self,
                    selection: $center.selectedDownloadIDs,
                    columnCustomization: $columnCustomization
                ) {
                    TableColumn("Name") { item in
                        DownloadNameCell(item: item)
                    }
                    .customizationID("name")
                    .defaultVisibility(.visible)
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("Status") { item in
                        DownloadStatusBadge(status: item.status)
                    }
                    .customizationID("status")
                    .defaultVisibility(.visible)

                    TableColumn("Transfer") { item in
                        DownloadTransferCell(item: item)
                    }
                    .customizationID("transfer")
                    .defaultVisibility(.visible)

                    TableColumn("Source") { item in
                        DownloadSourceCell(item: item)
                    }
                    .customizationID("source")
                    .defaultVisibility(.visible)

                    TableColumn("Speed") { item in
                        Text(
                            item.status == .seeding
                                ? DownloadFormatting.throughputString(item.uploadBytesPerSecond)
                                : item.speedText
                        )
                            .monospacedDigit()
                    }
                    .customizationID("speed")
                    .defaultVisibility(.visible)

                    TableColumn("Updated") { item in
                        Text(DownloadFormatting.dateString(item.updatedAt))
                            .font(.caption)
                    }
                    .customizationID("updated")
                    .defaultVisibility(.visible)
                } rows: {
                    ForEach(center.filteredDownloads) { item in
                        TableRow(item)
                            .contextMenu {
                                rowContextMenu(for: item)
                            }
                    }
                }
            }
        }
        .navigationTitle(center.selectedFilter.title)
        .confirmationDialog(
            "Move Download Data to Trash?",
            isPresented: Binding(
                get: { pendingDataRemovalIDs.isEmpty == false },
                set: { isPresented in
                    if isPresented == false {
                        pendingDataRemovalIDs = []
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let ids = pendingDataRemovalIDs
                pendingDataRemovalIDs = []
                center.removeDownloadsAndData(ids: ids)
            }

            Button("Cancel", role: .cancel) {
                pendingDataRemovalIDs = []
            }
        } message: {
            Text(center.dataRemovalConfirmationMessage(ids: pendingDataRemovalIDs))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyImage)
        } description: {
            Text(emptyDescription)
        } actions: {
            Button {
                center.presentAddSheet()
            } label: {
                Label("Add Download", systemImage: "plus")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: LocalizedStringResource {
        switch center.selectedFilter {
        case .all:
            "No Downloads Yet"
        case .active:
            "Nothing Running"
        case .paused:
            "No Paused Downloads"
        case .completed:
            "Nothing Completed"
        case .failed:
            "No Failures"
        case .cancelled:
            "No Cancelled Downloads"
        }
    }

    private var emptyImage: String {
        center.selectedFilter.systemImage
    }

    private var emptyDescription: LocalizedStringResource {
        switch center.selectedFilter {
        case .all:
            "Paste an HTTP or HTTPS URL to start building your queue."
        case .active:
            "Queued and running transfers appear here."
        case .paused:
            "Paused transfers and browser-required downloads stay here until you continue them."
        case .completed:
            "Finished files will stay listed until you clear them."
        case .failed:
            "Network or filesystem errors surface here with retry support."
        case .cancelled:
            "Cancelled items stay in history until you remove them."
        }
    }

    @ViewBuilder
    private func rowContextMenu(for item: DownloadItem) -> some View {
        let targetIDs = center.contextMenuDownloadIDs(for: item.id)

        if center.canContinueInBrowser(ids: targetIDs) {
            Button("Continue in Harbor") {
                center.continueInBrowser(id: item.id)
            }
        }

        if center.canPauseDownloads(ids: targetIDs) {
            Button("Pause") {
                center.pauseDownloads(ids: targetIDs)
            }
        }

        if center.canResumeDownloads(ids: targetIDs) {
            Button("Resume") {
                center.resumeDownloads(ids: targetIDs)
            }
        }

        if center.canRetryDownloads(ids: targetIDs) {
            Button("Retry") {
                center.retryDownloads(ids: targetIDs)
            }
        }

        if center.canOpenDownloads(ids: targetIDs) {
            Button("Open File") {
                center.openDownloads(ids: targetIDs)
            }
        }

        if center.canQuickLookDownloads(ids: targetIDs) {
            Button("Quick Look") {
                center.quickLookDownloads(ids: targetIDs)
            }
        }

        if targetIDs.count == 1, item.backend == .aria2, item.status == .completed {
            Button("Start Seeding") {
                center.startSeeding(id: item.id)
            }
        }

        if targetIDs.count == 1,
           item.backend == .aria2,
           item.status == .seeding || (item.status == .paused && item.finishedAt != nil && item.shouldSeedAfterDownload) {
            Button("Stop Seeding") {
                center.stopSeeding(id: item.id)
            }
        }

        Button("Cancel Download") {
            center.cancelDownloads(ids: targetIDs)
        }
        .disabled(center.canCancelDownloads(ids: targetIDs) == false)

        Divider()

        Button("Reveal in Finder") {
            center.revealInFinder(ids: targetIDs)
        }

        Button("Copy Source URL") {
            center.copySourceURLs(ids: targetIDs)
        }

        Button("Remove from List", role: .destructive) {
            center.removeDownloads(ids: targetIDs)
        }

        if center.canRemoveDownloadedData(ids: targetIDs) {
            Button("Remove and Move Data to Trash…", role: .destructive) {
                pendingDataRemovalIDs = targetIDs
            }
        }
    }
}

private struct DownloadNameCell: View {
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.sourceBadgeImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(item.sourceDisplayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct DownloadTransferCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            progressView

            Text(transferSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var transferSummary: String {
        guard item.status == .seeding else {
            return item.progressText
        }

        return "↑ \(item.uploadedText) • \(item.shareRatioText) ratio"
    }

    @ViewBuilder
    private var progressView: some View {
        if let progressValue = item.progressValue {
            ProgressView(value: progressValue, total: 1)
                .progressViewStyle(.linear)
        } else if item.status == .downloading || item.status == .preparing {
            ProgressView()
                .controlSize(.small)
        } else {
            ProgressView(value: item.progress, total: 1)
                .progressViewStyle(.linear)
        }
    }
}

private struct DownloadSourceCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.sourceBadgeTitle)
                .lineLimit(1)

            Text(item.sourceHost)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview("Downloads List") {
    DownloadsContentView(center: HarborPreviewFixtures.makeCenter())
        .frame(width: 760, height: 520)
}

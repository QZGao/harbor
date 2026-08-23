import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class DownloadCenter {
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let persistence: DownloadPersistence
    @ObservationIgnored private let destinationResolver: DownloadDestinationResolver
    @ObservationIgnored private let notificationService: DownloadNotificationService
    @ObservationIgnored private let dataRemovalService: DownloadDataRemovalService
    @ObservationIgnored private let managedTorrentSourceStore: ManagedTorrentSourceStore
    @ObservationIgnored private let torrentWatchFolderService: TorrentWatchFolderService
    @ObservationIgnored private let sleepPreventionService: any DownloadSleepPreventing
    @ObservationIgnored private let quickLookPreviewService: any QuickLookPreviewing
    @ObservationIgnored private var coordinator: DownloadCoordinator! = nil
    @ObservationIgnored private var browserCoordinator: BrowserDownloadCoordinator! = nil
    @ObservationIgnored private let torrentService: Aria2TorrentService
    @ObservationIgnored private var mediaService: MediaDownloadService! = nil
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var hasInstalledExternalOpenHandler = false
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var torrentRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var hasShownTorrentBinaryAlert = false
    @ObservationIgnored private var hasShownMediaRuntimeAlert = false
    @ObservationIgnored private var hasShownWatchFolderUnavailableAlert = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var isReconcilingSelection = false
    @ObservationIgnored private var mediaStartTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var torrentStartTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingExternalAddSheetDrafts: [AddDownloadSheetDraft] = []

    var downloads: [DownloadItem] = []
    var selectedFilter: DownloadFilter = .all {
        didSet {
            pruneSelectionToVisibleDownloads()
        }
    }
    var selectedDownloadID: UUID? {
        didSet {
            reconcileSelectionFromPrimaryDownload()
        }
    }
    var selectedDownloadIDs: Set<UUID> = [] {
        didSet {
            reconcilePrimaryDownloadFromSelection()
        }
    }
    var searchText = "" {
        didSet {
            pruneSelectionToVisibleDownloads()
        }
    }
    var sortOrder = [KeyPathComparator(\DownloadItem.updatedAt, order: .reverse)]
    var addSheetDraft: AddDownloadSheetDraft?
    var activeBrowserSession: BrowserDownloadSession?
    var activeAlert: UserAlert?

    init(
        settings: AppSettingsStore,
        persistence: DownloadPersistence = DownloadPersistence(),
        destinationResolver: DownloadDestinationResolver = DownloadDestinationResolver(),
        notificationService: DownloadNotificationService = DownloadNotificationService(),
        dataRemovalService: DownloadDataRemovalService = DownloadDataRemovalService(),
        managedTorrentSourceStore: ManagedTorrentSourceStore = ManagedTorrentSourceStore(),
        torrentWatchFolderService: TorrentWatchFolderService? = nil,
        sleepPreventionService: (any DownloadSleepPreventing)? = nil,
        quickLookPreviewService: (any QuickLookPreviewing)? = nil,
        torrentService: Aria2TorrentService? = nil,
        mediaService: MediaDownloadService? = nil
    ) {
        self.settings = settings
        self.persistence = persistence
        self.destinationResolver = destinationResolver
        self.notificationService = notificationService
        self.dataRemovalService = dataRemovalService
        self.managedTorrentSourceStore = managedTorrentSourceStore
        self.torrentWatchFolderService = torrentWatchFolderService ?? TorrentWatchFolderService()
        self.sleepPreventionService = sleepPreventionService ?? DownloadSleepPreventionService()
        self.quickLookPreviewService = quickLookPreviewService ?? QuickLookPreviewService()
        self.torrentService = torrentService ?? Aria2TorrentService(transferSettings: settings.transferSettings)
        self.mediaService = mediaService ?? MediaDownloadService { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        self.coordinator = DownloadCoordinator(transferSettings: settings.transferSettings) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        self.browserCoordinator = BrowserDownloadCoordinator { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        settings.transferSettingsDidChange = { [weak self] transferSettings in
            self?.applyTransferSettings(transferSettings)
        }
        settings.torrentAutomationSettingsDidChange = { [weak self] in
            self?.configureTorrentWatchFolder()
        }
        self.torrentWatchFolderService.statusDidChange = { [weak self] status in
            self?.handleTorrentWatchFolderStatus(status)
        }
        monitorSleepPrevention()
    }

    deinit {
        persistTask?.cancel()
        torrentRefreshTask?.cancel()
        Task { @MainActor [torrentWatchFolderService] in
            torrentWatchFolderService.stop()
        }
        Task { [mediaService] in
            await mediaService?.shutdown()
        }
    }

    func initializeIfNeeded() async {
        guard hasLoaded == false else {
            return
        }

        hasLoaded = true

        do {
            let records = try await persistence.load()
            let restoredItems = records
                .sorted { $0.createdAt > $1.createdAt }
                .map { record in
                    let item = DownloadItem(record: record)
                    item.taskIdentifier = nil
                    item.speedBytesPerSecond = 0

                    if Self.shouldRepairMetadataOnlyMagnetCompletion(
                        sourceKind: item.sourceKind,
                        status: item.status,
                        fileLocationPath: item.fileLocationPath,
                        payloadPaths: item.torrentPayloadPaths
                    ) {
                        item.status = settings.startDownloadsAutomatically ? .queued : .paused
                        item.progress = 0
                        item.bytesWritten = 0
                        item.expectedBytes = 0
                        item.finishedAt = nil
                        item.backendIdentifier = nil
                        item.fileLocationPath = nil
                        item.torrentPayloadPaths = []
                        item.completionNotificationDelivered = false
                        item.activityEvents.removeAll { $0.kind == .completed }
                        item.updatedAt = .now
                        item.lastError = settings.startDownloadsAutomatically
                            ? nil
                            : String(
                                localized: "torrent.metadata.resumeToContinue",
                                defaultValue: "Torrent metadata was restored. Resume to continue downloading the payload.",
                                comment: "Status message shown after repairing a magnet that was previously marked complete after metadata retrieval."
                            )
                    }

                    if item.status == .completed, item.finishedAt == nil {
                        item.finishedAt = item.updatedAt
                    }

                    if item.backend == .ytDlp {
                        item.backendIdentifier = nil
                    }

                    if record.status == .queued || record.status == .preparing || record.status == .downloading {
                        item.status = settings.startDownloadsAutomatically ? .queued : .paused
                        if settings.startDownloadsAutomatically == false {
                            item.lastError = String(
                                localized: "download.restore.pausedAfterRelaunch",
                                defaultValue: "Paused after relaunch.",
                                comment: "Status message shown when a download is restored as paused after app relaunch."
                            )
                        }
                    }

                    return item
                }

            downloads = restoredItems
            selectDownload(downloads.first?.id)
            await backfillLegacyTorrentFingerprints()
            await reconcileRestoredTorrentSession()
            configureTorrentWatchFolder()

            if settings.startDownloadsAutomatically {
                startNextQueuedDownloadsIfNeeded()
            }

            let seedingItems = downloads.filter {
                $0.status == .seeding && $0.shouldSeedAfterDownload
            }
            for item in seedingItems {
                startOrQueueDownload(id: item.id)
            }
            startTorrentRefreshLoopIfNeeded()
        } catch {
            activeAlert = UserAlert(
                title: String(
                    localized: "alert.restoreDownloads.title",
                    defaultValue: "Couldn’t Restore Downloads",
                    comment: "Alert title shown when saved downloads cannot be restored."
                ),
                message: error.localizedDescription
            )
            startTorrentRefreshLoopIfNeeded()
        }
    }

    private func reconcileRestoredTorrentSession() async {
        do {
            let engineGIDs = try await torrentService.allKnownGIDs()
            let persistedTorrentItems = downloads.filter {
                $0.backend == .aria2 && $0.backendIdentifier != nil
            }
            let persistedGIDs = Set(persistedTorrentItems.compactMap(\.backendIdentifier))
            var retainedEngineGIDs = persistedGIDs

            for item in persistedTorrentItems {
                guard let rootGID = item.backendIdentifier else {
                    continue
                }
                let lineage = try await torrentService.followedStatus(for: rootGID)
                retainedEngineGIDs.formUnion(lineage.gids)
            }

            for orphanedGID in Self.orphanedTorrentGIDs(
                engineGIDs: engineGIDs,
                retainedGIDs: retainedEngineGIDs
            ) {
                await torrentService.remove(gid: orphanedGID)
            }

            let restoredItemsByGID = Dictionary(
                uniqueKeysWithValues: persistedTorrentItems.compactMap { item in
                    item.backendIdentifier.map { ($0, torrentTransferOptions(for: item)) }
                }
            )
            await torrentService.updateTransferSettings(
                settings.transferSettings,
                activeGIDs: Array(persistedGIDs.intersection(engineGIDs)),
                transferOptionsByGID: restoredItemsByGID
            )

            for item in persistedTorrentItems where item.status == .paused {
                guard let gid = item.backendIdentifier,
                      engineGIDs.contains(gid) else {
                    continue
                }

                let lineage = try await torrentService.followedStatus(for: gid)
                let snapshot = lineage.currentSnapshot
                if Self.shouldPauseRestoredTorrent(
                    persistedStatus: item.status,
                    engineStatus: snapshot.status
                ) {
                    try await torrentService.pause(gid: gid)
                }
            }
        } catch {
            // Existing stale-GID recovery remains the per-item fallback when the engine cannot reconcile at launch.
        }
    }

    var filteredDownloads: [DownloadItem] {
        let filtered = downloads.filter { item in
            guard selectedFilter.includes(item) else {
                return false
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.isEmpty == false else {
                return true
            }

            return item.displayName.localizedCaseInsensitiveContains(query)
                || item.sourceDisplayText.localizedCaseInsensitiveContains(query)
                || item.sourceHost.localizedCaseInsensitiveContains(query)
        }

        return filtered.sorted(using: sortOrder)
    }

    var selectedDownload: DownloadItem? {
        guard let selectedDownloadID else {
            return nil
        }

        return downloads.first { $0.id == selectedDownloadID }
    }

    var selectedDownloads: [DownloadItem] {
        orderedDownloads(for: selectedDownloadIDs)
    }

    private func reconcileSelectionFromPrimaryDownload() {
        guard isReconcilingSelection == false else {
            return
        }

        isReconcilingSelection = true
        defer {
            isReconcilingSelection = false
        }

        if let selectedDownloadID {
            selectedDownloadIDs = [selectedDownloadID]
        } else {
            selectedDownloadIDs = []
        }
    }

    private func reconcilePrimaryDownloadFromSelection() {
        guard isReconcilingSelection == false else {
            return
        }

        isReconcilingSelection = true
        defer {
            isReconcilingSelection = false
        }

        if let selectedDownloadID,
           selectedDownloadIDs.contains(selectedDownloadID) {
            return
        }

        selectedDownloadID = orderedDownloads(for: selectedDownloadIDs).first?.id
    }

    private func selectDownload(_ id: UUID?) {
        selectedDownloadID = id
    }

    private func pruneSelectionToVisibleDownloads() {
        let visibleIDs = Set(filteredDownloads.map(\.id))
        selectedDownloadIDs.formIntersection(visibleIDs)

        if let selectedDownloadID,
           visibleIDs.contains(selectedDownloadID) == false {
            selectDownload(orderedDownloads(for: selectedDownloadIDs).first?.id)
        }
    }

    private func orderedDownloads(for ids: Set<UUID>) -> [DownloadItem] {
        guard ids.isEmpty == false else {
            return []
        }

        return filteredDownloads.filter { ids.contains($0.id) }
    }

    var totalActiveSpeed: Double {
        downloads
            .filter(\.isRunning)
            .reduce(0) { $0 + $1.speedBytesPerSecond }
    }

    var totalDownloadSpeed: Double {
        downloads.reduce(0) { $0 + $1.speedBytesPerSecond }
    }

    var totalUploadSpeed: Double {
        downloads.reduce(0) { $0 + $1.uploadBytesPerSecond }
    }

    var hasActiveDownloads: Bool {
        downloads.contains { $0.isRunning || $0.status == .seeding }
    }

    var hasPausableDownloads: Bool {
        downloads.contains { item in
            item.canPause || item.status == .queued
        }
    }

    var hasResumableDownloads: Bool {
        downloads.contains(where: \.canResume)
    }

    var hasCompletedDownloads: Bool {
        downloads.contains { $0.status == .completed }
    }

    var hasFailedDownloads: Bool {
        downloads.contains { $0.status == .failed }
    }

    var activeDownloadCount: Int {
        downloads.filter { $0.status == .queued || $0.isRunning }.count
    }

    var canToggleSelectedDownload: Bool {
        selectedDownloads.contains { item in
            item.status == .browserSessionRequired
                || item.canPause
                || item.canResume
                || item.status == .queued
        }
    }

    var canRetrySelectedDownload: Bool {
        selectedDownloads.contains { item in
            item.status == .failed || item.status == .cancelled
        }
    }

    var canCancelSelectedDownload: Bool {
        selectedDownloads.contains { item in
            item.status != .completed
                && item.status != .cancelled
                && item.status != .seeding
                && item.isPausedSeeder == false
        }
    }

    var canOpenSelectedDownload: Bool {
        selectedDownloads.contains { $0.fileLocationURL != nil }
    }

    var canQuickLookSelectedDownloads: Bool {
        canQuickLookDownloads(ids: selectedDownloadIDs)
    }

    func count(for filter: DownloadFilter) -> Int {
        downloads.filter { filter.includes($0) }.count
    }

    func setDownloadLimitOverride(
        _ limitOverride: TransferLimitOverride,
        for id: UUID
    ) {
        guard let item = item(for: id) else {
            return
        }

        item.downloadLimitOverride = limitOverride
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            coordinator.updateSpeedLimitOverride(limitOverride, for: id)
        case .aria2:
            applyTransferSettings(settings.transferSettings)
        case .ytDlp:
            break
        }

        schedulePersist()
    }

    func setUploadLimitOverride(
        _ limitOverride: TransferLimitOverride,
        for id: UUID
    ) {
        guard let item = item(for: id), item.backend == .aria2 else {
            return
        }

        item.uploadLimitOverride = limitOverride
        item.updatedAt = .now
        applyTransferSettings(settings.transferSettings)
        schedulePersist()
    }

    func setMediaFormatPreference(
        _ preference: MediaDownloadFormatPreference,
        for id: UUID
    ) {
        guard let item = item(for: id),
              item.backend == .ytDlp,
              item.status == .failed else {
            return
        }

        switch preference {
        case .bestAvailable:
            item.mediaFormatPreference = .bestAvailable
        case let .specific(selection):
            guard let resolvedSelection = item.mediaMetadata?.capabilities.resolvedSelection(
                matching: selection
            ) else {
                return
            }

            item.mediaFormatPreference = .specific(resolvedSelection)
        }

        item.updatedAt = .now
        schedulePersist()
    }

    func installExternalOpenHandlerIfNeeded() {
        guard hasInstalledExternalOpenHandler == false else {
            return
        }

        hasInstalledExternalOpenHandler = true
        ExternalAddDownloadOpenCoordinator.shared.installHandler { [weak self] urls, errorMessages in
            self?.handleOpenedExternalAddSources(urls)
            self?.handleExternalOpenErrors(errorMessages)
        }
    }

    private func configureTorrentWatchFolder() {
        guard hasLoaded else {
            return
        }

        guard settings.torrentWatchFolderEnabled else {
            torrentWatchFolderService.stop()
            settings.updateTorrentWatchFolderStatus(.stopped)
            return
        }

        torrentWatchFolderService.start(watching: settings.torrentWatchFolderURL) { [weak self] url in
            self?.receiveWatchedTorrent(url)
        }
    }

    private func handleTorrentWatchFolderStatus(_ status: TorrentWatchFolderStatus) {
        settings.updateTorrentWatchFolderStatus(status)

        switch status {
        case .watching:
            hasShownWatchFolderUnavailableAlert = false
        case .unavailable where hasShownWatchFolderUnavailableAlert == false:
            hasShownWatchFolderUnavailableAlert = true
            activeAlert = UserAlert(
                title: String(localized: "Torrent Watch Folder Unavailable"),
                message: String(localized: "Harbor can’t read the selected watch folder right now. It will keep trying while the app is open.")
            )
        case .stopped, .unavailable:
            break
        }
    }

    func receiveWatchedTorrent(_ url: URL) {
        guard isShuttingDown == false else {
            return
        }

        let request = AddDownloadRequest(
            sourceKind: .torrentFile,
            sourceURL: url,
            customFilename: nil,
            destinationFolder: settings.torrentDestinationURL,
            shouldStartImmediately: settings.startDownloadsAutomatically
        )

        Task { @MainActor [weak self] in
            await self?.prepareAndQueueTorrent(request, isWatchedImport: true)
        }
    }

    func presentAddSheet() {
        guard addSheetDraft == nil else {
            return
        }

        addSheetDraft = makeBlankAddSheetDraft()
    }

    func handleAddSheetDismissal() {
        addSheetDraft = nil
        Task { @MainActor [weak self] in
            self?.presentNextQueuedExternalAddSheetIfNeeded()
        }
    }

    private func handleOpenedExternalAddSources(_ urls: [URL]) {
        let drafts = urls.compactMap { makeExternalAddSheetDraft(for: $0) }

        guard drafts.isEmpty == false else {
            return
        }

        pendingExternalAddSheetDrafts.append(contentsOf: drafts)
        presentNextQueuedExternalAddSheetIfNeeded()
    }

    private func handleExternalOpenErrors(_ errorMessages: [String]) {
        guard errorMessages.isEmpty == false else {
            return
        }

        activeAlert = UserAlert(
            title: String(localized: "Couldn’t Open Harbor Link"),
            message: errorMessages.joined(separator: "\n")
        )
    }

    func receiveExternalAddSources(_ urls: [URL]) {
        handleOpenedExternalAddSources(urls)
    }

    func addDownloadSourcesFromPasteboard() {
        receiveExternalAddSources(
            DownloadSourceImportService.supportedURLs(from: .general)
        )
    }

    func shutdownForTermination() async {
        isShuttingDown = true
        sleepPreventionService.stop()
        persistTask?.cancel()
        torrentRefreshTask?.cancel()
        torrentWatchFolderService.stop()

        let restoredStatus: DownloadStatus = settings.startDownloadsAutomatically ? .queued : .paused
        let pausedMessage = String(
            localized: "download.restore.pausedAfterQuit",
            defaultValue: "Paused after quit.",
            comment: "Status message shown when a download is paused because Harbor is quitting."
        )

        let activeItems = downloads.filter { item in
            item.status == .queued || item.status == .preparing || item.isRunning
        }

        for item in activeItems {
            switch item.backend {
            case .urlSession:
                if item.taskIdentifier != nil {
                    coordinator.pauseDownload(id: item.id)
                }
                item.backendIdentifier = nil
            case .aria2:
                if let backendIdentifier = item.backendIdentifier {
                    try? await torrentService.pause(gid: backendIdentifier)
                }
            case .ytDlp:
                await mediaService.pause(id: item.id)
                item.backendIdentifier = nil
            }

            setStatus(for: item, to: restoredStatus)
            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            if restoredStatus == .paused {
                item.lastError = pausedMessage
            }
        }

        let pendingStarts = Array(mediaStartTasks.values) + Array(torrentStartTasks.values)
        for task in pendingStarts {
            await task.value
        }

        await mediaService.shutdown()
        await torrentService.shutdown()
        try? await persistence.save(downloads.map { $0.makeRecord() })
    }

    private func monitorSleepPrevention() {
        withObservationTracking {
            _ = settings.preventSleepWhileDownloading
            _ = downloads.map(\.status)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.updateSleepPrevention()
                self.monitorSleepPrevention()
            }
        }

        updateSleepPrevention()
    }

    private func updateSleepPrevention() {
        // TODO: Extend this policy if seeding sleep prevention becomes configurable.
        sleepPreventionService.update(
            isEnabled: settings.preventSleepWhileDownloading && isShuttingDown == false,
            hasActiveDownloads: downloads.contains { $0.status == .downloading }
        )
    }

    func previewMediaDownload(for url: URL) async throws -> MediaDownloadMetadata? {
        let scheme = url.scheme?.lowercased()
        let isHTTPURL = scheme == "http" || scheme == "https"
        guard url.isFileURL == false,
              isHTTPURL,
              url.pathExtension.lowercased() != "torrent" else {
            return nil
        }

        return try await mediaService.metadata(for: url)
    }

    func refreshMediaFormats(for id: UUID) async {
        guard let currentItem = item(for: id),
              currentItem.backend == .ytDlp,
              currentItem.status == .failed else {
            return
        }

        guard let metadata = try? await mediaService.metadata(for: currentItem.sourceURL),
              let refreshedItem = item(for: id),
              refreshedItem.status == .failed else {
            return
        }

        refreshedItem.mediaMetadata = metadata
        refreshedItem.metadataName = metadata.title
        if case let .specific(selection)? = refreshedItem.mediaFormatPreference,
           let resolvedSelection = metadata.capabilities.resolvedSelection(
               matching: selection
           ) {
            refreshedItem.mediaFormatPreference = .specific(resolvedSelection)
        }
        refreshedItem.updatedAt = .now
        schedulePersist()
    }

    func queueDownloads(_ requests: [AddDownloadRequest]) {
        for request in requests {
            queueDownload(request)
        }
    }

    func queueDownload(_ request: AddDownloadRequest) {
        if request.sourceKind == .torrentFile {
            Task { @MainActor [weak self] in
                await self?.prepareAndQueueTorrent(request, isWatchedImport: false)
            }
            return
        }

        insertDownload(request)
    }

    @discardableResult
    private func insertDownload(
        _ request: AddDownloadRequest,
        managedTorrentSource: ManagedTorrentSource? = nil
    ) -> DownloadItem {
        let backend = backend(for: request.sourceKind)
        let preferredFilename: String?
        if request.sourceKind.supportsCustomFilename {
            preferredFilename = destinationResolver.resolvedFilename(
                custom: request.customFilename,
                responseSuggestedFilename: nil,
                sourceURL: request.sourceURL
            )
        } else {
            preferredFilename = nil
        }

        let item = DownloadItem(
            sourceURL: request.sourceURL,
            sourceKind: request.sourceKind,
            backend: backend,
            preferredFilename: preferredFilename,
            destinationFolderPath: request.destinationFolder.path,
            status: request.shouldStartImmediately ? .queued : .paused,
            metadataName: request.mediaMetadata?.title,
            mediaMetadata: request.mediaMetadata,
            mediaFormatPreference: request.mediaFormatPreference,
            torrentFingerprint: managedTorrentSource?.fingerprint
                ?? Self.normalizedMagnetInfoHash(for: request),
            torrentSourceFingerprint: managedTorrentSource?.sourceFingerprint,
            managedTorrentSourcePath: managedTorrentSource?.managedURL.path,
            shouldSeedAfterDownload: backend == .aria2 ? settings.seedNewTorrents : false
        )

        if request.sourceKind == .magnetLink {
            item.metadataName = MagnetLinkMetadata(url: request.sourceURL).displayName
        }

        downloads.insert(item, at: 0)
        selectDownload(item.id)

        if request.shouldStartImmediately {
            startOrQueueDownload(id: item.id)
        } else {
            schedulePersist()
        }

        return item
    }

    private func prepareAndQueueTorrent(
        _ request: AddDownloadRequest,
        isWatchedImport: Bool
    ) async {
        do {
            let managedSource: ManagedTorrentSource
            if request.sourceURL.isFileURL {
                managedSource = try await managedTorrentSourceStore.prepareLocalTorrent(
                    at: request.sourceURL,
                    originalURL: request.sourceURL
                )
            } else {
                managedSource = try await managedTorrentSourceStore.fetchRemoteTorrent(
                    from: request.sourceURL
                )
            }

            await backfillLegacyTorrentFingerprints()
            guard isShuttingDown == false else {
                return
            }

            if let existingItem = downloads.first(where: {
                Self.torrentIdentity(for: $0) == managedSource.fingerprint
                    || ($0.torrentFingerprint == nil
                        && $0.sourceURL.isFileURL
                        && $0.sourceURL.standardizedFileURL == request.sourceURL.standardizedFileURL)
            }) {
                if isWatchedImport == false {
                    selectDownload(existingItem.id)
                    activeAlert = UserAlert(
                        title: String(localized: "Torrent Already Added"),
                        message: String(localized: "This torrent is already in Harbor.")
                    )
                } else if existingItem.finishedAt != nil,
                          Self.hasExistingTorrentPayload(existingItem) == false {
                    activeAlert = UserAlert(
                        title: String(localized: "Torrent Already Added"),
                        message: String(
                            localized: "Harbor kept the existing download history, but its completed files could not be found. No duplicate download was started."
                        )
                    )
                }
                return
            }

            insertDownload(
                request,
                managedTorrentSource: managedSource
            )
        } catch {
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Import Torrent"),
                message: error.localizedDescription
            )
        }
    }

    private func backfillLegacyTorrentFingerprints() async {
        var didMutate = false

        for item in downloads where item.sourceKind == .torrentFile {
            let candidateURL = item.managedTorrentSourcePath
                .map(URL.init(fileURLWithPath:))
                ?? item.sourceURL
            guard candidateURL.isFileURL,
                  FileManager.default.fileExists(atPath: candidateURL.path),
                  let data = try? Data(contentsOf: candidateURL, options: .mappedIfSafe) else {
                continue
            }

            let fingerprint = ManagedTorrentSourceStore.fingerprint(for: data)
            if item.torrentFingerprint != fingerprint {
                item.torrentFingerprint = fingerprint
                didMutate = true
            }
            let sourceFingerprint = ManagedTorrentSourceStore.sourceFingerprint(for: data)
            if item.torrentSourceFingerprint != sourceFingerprint {
                item.torrentSourceFingerprint = sourceFingerprint
                didMutate = true
            }
        }

        if didMutate {
            schedulePersist()
        }
    }

    private static func normalizedMagnetInfoHash(
        for request: AddDownloadRequest
    ) -> String? {
        guard request.sourceKind == .magnetLink else {
            return nil
        }

        return ManagedTorrentSourceStore.normalizedInfoHash(
            MagnetLinkMetadata(url: request.sourceURL).infoHash
        )
    }

    private static func torrentIdentity(for item: DownloadItem) -> String? {
        if let torrentFingerprint = item.torrentFingerprint {
            return torrentFingerprint.lowercased()
        }

        guard item.sourceKind == .magnetLink else {
            return nil
        }

        return ManagedTorrentSourceStore.normalizedInfoHash(
            MagnetLinkMetadata(url: item.sourceURL).infoHash
        )
    }

    static func hasExistingTorrentPayload(_ item: DownloadItem) -> Bool {
        let payloadPaths = item.torrentPayloadPaths.isEmpty
            ? [item.fileLocationPath].compactMap { $0 }
            : item.torrentPayloadPaths

        return payloadPaths.isEmpty == false
            && payloadPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }
    }

    private func backend(for sourceKind: DownloadSourceKind) -> DownloadBackend {
        switch sourceKind {
        case .directURL:
            .urlSession
        case .magnetLink, .torrentFile:
            .aria2
        case .mediaURL:
            .ytDlp
        }
    }

    func togglePauseResumeForSelection() {
        togglePauseResume(ids: selectedDownloadIDs)
    }

    func togglePauseResume(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) {
            togglePauseResume(id: item.id)
        }
    }

    func togglePauseResume(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        if item.status == .browserSessionRequired {
            continueInBrowser(id: id)
            return
        }

        if item.canPause {
            pauseDownload(id: id)
        } else if item.canResume {
            startOrQueueDownload(id: id)
        }
    }

    func retrySelectedDownload() {
        retryDownloads(ids: selectedDownloadIDs)
    }

    func retryDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) where item.status == .failed || item.status == .cancelled {
            retryDownload(id: item.id)
        }
    }

    func retryDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        item.lastError = nil
        item.finishedAt = nil
        item.completionNotificationDelivered = false
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            item.fileLocationPath = nil
            if item.status == .completed || item.status == .cancelled {
                item.bytesWritten = 0
                item.expectedBytes = 0
                item.progress = 0
                item.resumeData = nil
            }
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    await torrentService.remove(gid: backendIdentifier)
                }
            }

            item.backendIdentifier = nil
            item.fileLocationPath = nil
            item.bytesWritten = 0
            item.expectedBytes = 0
            item.progress = 0
        case .ytDlp:
            Task {
                await mediaService.remove(id: id)
            }
            item.backendIdentifier = nil
            item.fileLocationPath = nil
            item.bytesWritten = 0
            item.expectedBytes = (item.mediaFormatPreference ?? .bestAvailable)
                .initialExpectedBytes(
                    metadataEstimate: item.mediaMetadata?.expectedBytes ?? 0
                )
            item.progress = 0
        }

        startOrQueueDownload(id: id)
    }

    func pauseAll() {
        for item in downloads {
            if item.canPause {
                pauseDownload(id: item.id)
            } else if item.status == .queued {
                setStatus(for: item, to: .paused)
                item.updatedAt = .now
            }
        }

        schedulePersist()
    }

    func resumeAll() {
        downloads
            .filter(\.canResume)
            .forEach { startOrQueueDownload(id: $0.id) }
    }

    func cancelSelectedDownload() {
        cancelDownloads(ids: selectedDownloadIDs)
    }

    func cancelDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids)
        where item.status != .completed
            && item.status != .cancelled
            && item.status != .seeding
            && item.isPausedSeeder == false {
            cancelDownload(id: item.id)
        }
    }

    func cancelDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        if item.isPausedSeeder {
            stopSeeding(id: id)
            return
        }

        let shouldWaitForMediaProcess = item.backend == .ytDlp
            && (item.backendIdentifier != nil || mediaStartTasks[id] != nil)

        if activeBrowserSession?.downloadID == id {
            dismissBrowserSession()
        }

        switch item.backend {
        case .urlSession:
            if item.taskIdentifier != nil {
                coordinator.cancelDownload(id: id)
            }
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    await torrentService.remove(gid: backendIdentifier)
                }
            }
        case .ytDlp:
            Task {
                await mediaService.cancel(id: id)
            }
        }

        item.taskIdentifier = nil
        item.backendIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now
        transitionStatus(for: item, to: .cancelled)
        schedulePersist()
        if shouldWaitForMediaProcess == false {
            startNextQueuedDownloadsIfNeeded()
        }
    }

    func removeSelectedDownload() {
        removeDownloads(ids: selectedDownloadIDs)
    }

    func removeDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) {
            removeDownload(id: item.id)
        }
    }

    func canRemoveDownloadedData(ids: Set<UUID>) -> Bool {
        orderedDownloads(for: ids).contains { item in
            let resolution = dataRemovalService.resolvePayloadURLs(
                destinationFolderPath: item.destinationFolderPath,
                payloadPaths: payloadPaths(for: item)
            )
            return resolution.safeURLs.isEmpty == false
        }
    }

    func dataRemovalConfirmationMessage(ids: Set<UUID>) -> String {
        let items = orderedDownloads(for: ids)
        let payloadCount = items.reduce(0) { count, item in
            count + dataRemovalService.resolvePayloadURLs(
                destinationFolderPath: item.destinationFolderPath,
                payloadPaths: payloadPaths(for: item)
            ).safeURLs.count
        }

        return String(
            format: String(localized: "%lld download(s) and %lld file or folder item(s) will be removed from Harbor and moved to Trash."),
            Int64(items.count),
            Int64(payloadCount)
        )
    }

    func removeDownloadsAndData(ids: Set<UUID>) {
        Task { @MainActor [weak self] in
            await self?.performDownloadDataRemoval(ids: ids)
        }
    }

    private func performDownloadDataRemoval(ids: Set<UUID>) async {
        var failures: [DownloadDataRemovalFailure] = []

        for item in orderedDownloads(for: ids) {
            let statusBeforeStopping = item.status
            let wasSeeding = item.status == .seeding
                || (item.status == .paused && item.finishedAt != nil && item.shouldSeedAfterDownload)
            do {
                try await stopBackendForDataRemoval(item)
            } catch {
                let failure = DownloadDataRemovalFailure(
                    path: item.fileLocationPath ?? item.displayName,
                    message: error.localizedDescription
                )
                failures.append(failure)
                if item.status == .cancelled {
                    item.status = statusBeforeStopping
                }
                item.lastError = failure.message
                item.updatedAt = .now
                continue
            }

            if item.backend == .aria2 {
                item.shouldSeedAfterDownload = false
            }
            let result = dataRemovalService.movePayloadDataToTrash(
                destinationFolderPath: item.destinationFolderPath,
                payloadPaths: payloadPaths(for: item)
            )

            if result.failures.isEmpty {
                removeDownload(id: item.id)
                continue
            }

            failures.append(contentsOf: result.failures)
            item.torrentPayloadPaths = result.remainingPayloadPaths
            item.fileLocationPath = result.remainingPayloadPaths.first
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.backendIdentifier = nil
            item.taskIdentifier = nil
            item.lastError = result.failures.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            item.updatedAt = .now
            item.status = item.finishedAt == nil ? .cancelled : .completed
            if wasSeeding {
                item.recordActivity(.seedingStopped)
            }
        }

        schedulePersist()

        if failures.isEmpty == false {
            activeAlert = UserAlert(
                title: String(localized: "Some Download Data Couldn’t Be Moved to Trash"),
                message: failures.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            )
        }
    }

    private func stopBackendForDataRemoval(_ item: DownloadItem) async throws {
        switch item.backend {
        case .urlSession:
            if item.taskIdentifier != nil {
                coordinator.cancelDownload(id: item.id)
            }
        case .aria2:
            if let startTask = torrentStartTasks[item.id] {
                item.status = .cancelled
                await startTask.value
            }
            if let backendIdentifier = item.backendIdentifier {
                try await torrentService.removeAndConfirmStopped(gid: backendIdentifier)
                item.backendIdentifier = nil
            }
        case .ytDlp:
            if let startTask = mediaStartTasks[item.id] {
                item.status = .cancelled
                await startTask.value
            }
            await mediaService.cancelAndWait(id: item.id)
        }
    }

    private func payloadPaths(for item: DownloadItem) -> [String] {
        if item.torrentPayloadPaths.isEmpty == false {
            return item.torrentPayloadPaths
        }

        return item.fileLocationPath.map { [$0] } ?? []
    }

    func removeDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        let shouldWaitForMediaProcess = item.backend == .ytDlp
            && (item.backendIdentifier != nil || mediaStartTasks[id] != nil)

        if activeBrowserSession?.downloadID == id {
            dismissBrowserSession()
        }

        switch item.backend {
        case .urlSession:
            if item.taskIdentifier != nil {
                coordinator.cancelDownload(id: id)
            }
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    await torrentService.remove(gid: backendIdentifier)
                }
            }
        case .ytDlp:
            Task {
                await mediaService.remove(id: id)
            }
        }

        let removedPrimarySelection = selectedDownloadID == id
        moveOriginalTorrentFileToTrashIfNeeded(for: item)
        removeManagedTorrentSourceIfNeeded(for: item)
        downloads.removeAll { $0.id == id }
        selectedDownloadIDs.remove(id)

        if removedPrimarySelection && selectedDownloadIDs.isEmpty {
            selectDownload(filteredDownloads.first?.id ?? downloads.first?.id)
        }

        schedulePersist()
        if shouldWaitForMediaProcess == false {
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private func moveOriginalTorrentFileToTrashIfNeeded(for item: DownloadItem) {
        guard item.sourceKind == .torrentFile,
              item.sourceURL.isFileURL,
              FileManager.default.fileExists(atPath: item.sourceURL.path) else {
            return
        }

        let didAccessSecurityScopedResource = item.sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                item.sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let expectedFingerprint = item.torrentSourceFingerprint,
              let data = try? Data(contentsOf: item.sourceURL, options: .mappedIfSafe),
              ManagedTorrentSourceStore.sourceFingerprint(for: data) == expectedFingerprint else {
            activeAlert = UserAlert(
                title: String(localized: "Torrent File Was Left in Place"),
                message: String(localized: "The torrent file changed after Harbor imported it, so Harbor left the current file untouched.")
            )
            return
        }

        do {
            try FileManager.default.trashItem(at: item.sourceURL, resultingItemURL: nil)
        } catch {
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Move Torrent File to Trash"),
                message: error.localizedDescription
            )
        }
    }

    private func removeManagedTorrentSourceIfNeeded(for item: DownloadItem) {
        guard let managedTorrentSourcePath = item.managedTorrentSourcePath else {
            return
        }

        try? FileManager.default.removeItem(atPath: managedTorrentSourcePath)
    }

    func clearCompleted() {
        let completedItems = downloads.filter { $0.status == .completed }
        cleanupBackendIdentifiers(for: completedItems)
        completedItems.forEach { moveOriginalTorrentFileToTrashIfNeeded(for: $0) }
        completedItems.forEach { removeManagedTorrentSourceIfNeeded(for: $0) }
        downloads.removeAll { $0.status == .completed }
        selectedDownloadIDs = selectedDownloadIDs.filter { id in
            downloads.contains { $0.id == id }
        }
        if selectedDownloadIDs.isEmpty {
            selectDownload(filteredDownloads.first?.id ?? downloads.first?.id)
        }
        schedulePersist()
    }

    func clearFailed() {
        let failedItems = downloads.filter { $0.status == .failed }
        cleanupBackendIdentifiers(for: failedItems)
        failedItems.forEach { moveOriginalTorrentFileToTrashIfNeeded(for: $0) }
        failedItems.forEach { removeManagedTorrentSourceIfNeeded(for: $0) }
        downloads.removeAll { $0.status == .failed }
        selectedDownloadIDs = selectedDownloadIDs.filter { id in
            downloads.contains { $0.id == id }
        }
        if selectedDownloadIDs.isEmpty {
            selectDownload(filteredDownloads.first?.id ?? downloads.first?.id)
        }
        schedulePersist()
    }

    func revealSelectedInFinder() {
        revealInFinder(ids: selectedDownloadIDs)
    }

    func revealInFinder(ids: Set<UUID>) {
        let items = orderedDownloads(for: ids)
        let fileURLs = items.compactMap(\.fileLocationURL)

        if fileURLs.isEmpty == false {
            NSWorkspace.shared.activateFileViewerSelecting(fileURLs)
        } else if let firstItem = items.first {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: firstItem.destinationFolderPath)
        }
    }

    func revealInFinder(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        if let fileLocationPath = item.fileLocationPath {
            NSWorkspace.shared.selectFile(fileLocationPath, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.destinationFolderPath)
        }
    }

    func openSelectedDownload() {
        openDownloads(ids: selectedDownloadIDs)
    }

    func openDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) {
            guard let url = item.fileLocationURL else {
                continue
            }

            NSWorkspace.shared.open(url)
        }
    }

    func openDownload(id: UUID) {
        guard let url = item(for: id)?.fileLocationURL else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func quickLookSelectedDownloads() {
        quickLookDownloads(ids: selectedDownloadIDs)
    }

    func quickLookDownload(id: UUID) {
        quickLookDownloads(ids: [id])
    }

    func quickLookDownloads(ids: Set<UUID>) {
        let items = orderedDownloads(for: ids)
        let previewURLs = items.compactMap(existingQuickLookURL(for:))

        guard items.isEmpty == false,
              previewURLs.count == items.count else {
            activeAlert = UserAlert(
                title: String(localized: "Quick Look Unavailable"),
                message: String(localized: "The completed file could not be found on this Mac.")
            )
            return
        }

        quickLookPreviewService.preview(urls: previewURLs)
    }

    func copySourceURL(id: UUID) {
        guard let sourceText = item(for: id)?.sourceDisplayText else {
            return
        }

        copySourceText(sourceText)
    }

    func copySourceURLs(ids: Set<UUID>) {
        let sourceText = orderedDownloads(for: ids)
            .map(\.sourceDisplayText)
            .joined(separator: "\n")

        guard sourceText.isEmpty == false else {
            return
        }

        copySourceText(sourceText)
    }

    func contextMenuDownloadIDs(for id: UUID) -> Set<UUID> {
        if selectedDownloadIDs.contains(id) {
            return selectedDownloadIDs
        }

        return [id]
    }

    // TODO: Move batch action eligibility into a small policy type if row actions keep growing.
    func canContinueInBrowser(ids: Set<UUID>) -> Bool {
        let items = orderedDownloads(for: ids)
        return items.count == 1 && items.first?.status == .browserSessionRequired
    }

    func canPauseDownloads(ids: Set<UUID>) -> Bool {
        orderedDownloads(for: ids).contains { item in
            item.canPause || item.status == .queued
        }
    }

    func canResumeDownloads(ids: Set<UUID>) -> Bool {
        orderedDownloads(for: ids).contains(where: \.canResume)
    }

    func canRetryDownloads(ids: Set<UUID>) -> Bool {
        orderedDownloads(for: ids).contains { item in
            item.status == .failed || item.status == .cancelled
        }
    }

    func canCancelDownloads(ids: Set<UUID>) -> Bool {
        orderedDownloads(for: ids).contains { item in
            item.status != .completed
                && item.status != .cancelled
                && item.status != .seeding
                && item.isPausedSeeder == false
        }
    }

    func canOpenDownloads(ids: Set<UUID>) -> Bool {
        orderedDownloads(for: ids).contains { $0.fileLocationURL != nil }
    }

    func canQuickLookDownloads(ids: Set<UUID>) -> Bool {
        let items = orderedDownloads(for: ids)
        return items.isEmpty == false && items.allSatisfy { existingQuickLookURL(for: $0) != nil }
    }

    private func existingQuickLookURL(for item: DownloadItem) -> URL? {
        guard item.status == .completed,
              let url = item.fileLocationURL,
              url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        return url
    }

    func pauseDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) where item.canPause || item.status == .queued {
            pauseDownload(id: item.id)
        }
    }

    func resumeDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) where item.canResume {
            startOrQueueDownload(id: item.id)
        }
    }

    func startSeeding(id: UUID) {
        guard let item = item(for: id),
              item.backend == .aria2,
              item.finishedAt != nil else {
            return
        }

        if item.sourceKind == .magnetLink {
            item.shouldSeedAfterDownload = true
            startOrQueueDownload(id: id)
            return
        }

        let existingManagedSource = item.managedTorrentSourcePath.map(URL.init(fileURLWithPath:))
        if let existingManagedSource,
           FileManager.default.fileExists(atPath: existingManagedSource.path) {
            item.shouldSeedAfterDownload = true
            startOrQueueDownload(id: id)
            return
        }

        let sourceURL: URL
        if item.sourceURL.isFileURL,
           FileManager.default.fileExists(atPath: item.sourceURL.path) == false {
            guard let replacementURL = TorrentFileSelectionService.chooseTorrentFile(
                startingAt: item.destinationFolderURL
            ) else {
                return
            }
            sourceURL = replacementURL
        } else {
            sourceURL = item.sourceURL
        }

        Task { @MainActor [weak self] in
            await self?.prepareExistingTorrentForSeeding(id: id, sourceURL: sourceURL)
        }
    }

    func stopSeeding(id: UUID) {
        guard let item = item(for: id),
              item.backend == .aria2,
              item.finishedAt != nil else {
            return
        }

        guard item.backendIdentifier != nil else {
            finalizeStoppedSeeding(item)
            return
        }

        Task { @MainActor [weak self] in
            await self?.performStopSeeding(id: id)
        }
    }

    private func performStopSeeding(id: UUID) async {
        guard let item = item(for: id),
              item.backend == .aria2,
              item.finishedAt != nil else {
            return
        }

        let backendIdentifier = item.backendIdentifier
        if let backendIdentifier {
            do {
                try await torrentService.removeAndConfirmStopped(gid: backendIdentifier)
            } catch {
                item.lastError = error.localizedDescription
                item.updatedAt = .now
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Stop Seeding"),
                    message: error.localizedDescription
                )
                schedulePersist()
                return
            }
        }

        finalizeStoppedSeeding(item)
    }

    private func finalizeStoppedSeeding(_ item: DownloadItem) {
        item.shouldSeedAfterDownload = false
        item.backendIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.lastError = nil
        item.updatedAt = .now
        item.status = .completed
        item.recordActivity(.seedingStopped)
        schedulePersist()
        startNextQueuedDownloadsIfNeeded()
    }

    private func prepareExistingTorrentForSeeding(id: UUID, sourceURL: URL) async {
        guard let item = item(for: id) else {
            return
        }

        do {
            let managedSource: ManagedTorrentSource
            if sourceURL.isFileURL {
                managedSource = try await managedTorrentSourceStore.prepareLocalTorrent(
                    at: sourceURL,
                    originalURL: sourceURL
                )
            } else {
                managedSource = try await managedTorrentSourceStore.fetchRemoteTorrent(from: sourceURL)
            }

            item.sourceURL = managedSource.originalURL
            item.torrentFingerprint = managedSource.fingerprint
            item.torrentSourceFingerprint = managedSource.sourceFingerprint
            item.managedTorrentSourcePath = managedSource.managedURL.path
            item.shouldSeedAfterDownload = true
            startOrQueueDownload(id: id)
        } catch {
            item.lastError = error.localizedDescription
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Start Seeding"),
                message: error.localizedDescription
            )
            schedulePersist()
        }
    }

    private func copySourceText(_ sourceText: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sourceText, forType: .string)
    }

    func continueInBrowser(id: UUID) {
        guard let item = item(for: id),
              item.sourceKind == .directURL
        else {
            return
        }

        if let activeBrowserSession, activeBrowserSession.downloadID != id {
            activeAlert = UserAlert(
                title: String(
                    localized: "alert.browserSessionAlreadyOpen.title",
                    defaultValue: "Browser Session Already Open",
                    comment: "Alert title shown when another browser-assisted download is already active."
                ),
                message: String(
                    localized: "alert.browserSessionAlreadyOpen.message",
                    defaultValue: "Finish the current browser-assisted download before starting another one.",
                    comment: "Alert message shown when another browser-assisted download is already active."
                )
            )
            return
        }

        let session = browserCoordinator.startSession(
            downloadID: item.id,
            sourceURL: item.sourceURL,
            displayName: item.displayName
        )

        activeBrowserSession = session
        item.updatedAt = .now
        schedulePersist()
    }

    func dismissBrowserSession() {
        browserCoordinator.cancelSession()
        activeBrowserSession = nil
    }

    private func startOrQueueDownload(id: UUID) {
        guard isShuttingDown == false else {
            return
        }

        guard let item = item(for: id) else {
            return
        }

        if item.backend == .urlSession, item.taskIdentifier != nil {
            return
        }

        if item.backend == .aria2, torrentStartTasks[id] != nil {
            return
        }

        if item.backend == .ytDlp, mediaStartTasks[id] != nil {
            return
        }

        let isSeedingContinuation = item.backend == .aria2
            && item.finishedAt != nil
            && item.shouldSeedAfterDownload

        if isSeedingContinuation == false,
           currentRunningDownloadsCount >= settings.transferSettings.maxConcurrentDownloads {
            setStatus(for: item, to: .queued)
            item.updatedAt = .now
            schedulePersist()
            return
        }

        item.lastError = nil
        if isSeedingContinuation == false {
            item.finishedAt = nil
        }
        item.speedBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            setStatus(for: item, to: .preparing)
            item.taskIdentifier = coordinator.startDownload(
                id: item.id,
                sourceURL: item.sourceURL,
                resumeData: item.resumeData,
                speedLimitOverride: item.downloadLimitOverride
            )
            item.resumeData = nil
            item.startedAt = item.startedAt ?? .now
            schedulePersist()

        case .aria2:
            if isSeedingContinuation == false || item.status != .seeding {
                setStatus(for: item, to: .preparing)
            }
            item.startedAt = item.startedAt ?? .now
            schedulePersist()
            torrentStartTasks[id] = Task { @MainActor [weak self] in
                await self?.startTorrentDownload(id: id)
            }

        case .ytDlp:
            setStatus(for: item, to: .preparing)
            item.startedAt = item.startedAt ?? .now
            schedulePersist()
            mediaStartTasks[id] = Task { @MainActor [weak self] in
                await self?.startMediaDownload(id: id)
            }
        }
    }

    private func startMediaDownload(id: UUID) async {
        var waitsForMediaStopEvent = false

        defer {
            mediaStartTasks.removeValue(forKey: id)

            if waitsForMediaStopEvent == false {
                if let item = item(for: id),
                   item.status == .paused || item.status == .cancelled {
                    startNextQueuedDownloadsIfNeeded()
                } else if item(for: id) == nil {
                    startNextQueuedDownloadsIfNeeded()
                }
            }
        }

        guard let currentItem = item(for: id),
              currentItem.status == .preparing else {
            return
        }

        do {
            var validatedMetadata: MediaDownloadMetadata
            let metadataWasProbed: Bool
            if let metadata = currentItem.mediaMetadata,
               metadata.supportsMediaDownload {
                validatedMetadata = metadata
                metadataWasProbed = false
            } else {
                validatedMetadata = try await mediaService.metadata(for: currentItem.sourceURL)
                metadataWasProbed = true

                guard let refreshedItem = item(for: id),
                      refreshedItem.status == .preparing else {
                    return
                }

                refreshedItem.mediaMetadata = validatedMetadata
                refreshedItem.metadataName = validatedMetadata.title
                schedulePersist()
            }

            var requestedFormat = currentItem.mediaFormatPreference
                ?? validatedMetadata.defaultFormatPreference

            if case let .specific(selection) = requestedFormat,
               selection.requiresFormatProbe {
                if metadataWasProbed == false {
                    validatedMetadata = try await mediaService.metadata(for: currentItem.sourceURL)

                    guard let refreshedItem = item(for: id),
                          refreshedItem.status == .preparing else {
                        return
                    }

                    refreshedItem.mediaMetadata = validatedMetadata
                    refreshedItem.metadataName = validatedMetadata.title
                    schedulePersist()
                }

                guard let resolvedSelection = validatedMetadata.capabilities.resolvedSelection(
                    matching: selection
                ) else {
                    throw MediaDownloadError.unsupported(
                        MediaDownloadErrorClassifier.selectedFormatUnavailableMessage
                    )
                }

                requestedFormat = .specific(resolvedSelection)

                guard let refreshedItem = item(for: id),
                      refreshedItem.status == .preparing else {
                    return
                }

                refreshedItem.mediaFormatPreference = requestedFormat
                schedulePersist()
            }

            guard let readyItem = item(for: id),
                  readyItem.status == .preparing else {
                return
            }

            let processIdentifier = try await mediaService.startDownload(
                id: readyItem.id,
                sourceURL: readyItem.sourceURL,
                destinationFolder: readyItem.destinationFolderURL,
                metadata: validatedMetadata,
                formatPreference: requestedFormat,
                speedLimitBytesPerSecond: effectiveMediaDownloadLimit(for: readyItem)
            )

            guard let refreshedItem = item(for: id) else {
                waitsForMediaStopEvent = await mediaService.pause(id: id)
                return
            }

            guard refreshedItem.status == .preparing || refreshedItem.status == .downloading else {
                if refreshedItem.status == .cancelled {
                    waitsForMediaStopEvent = await mediaService.cancel(id: id)
                } else {
                    waitsForMediaStopEvent = await mediaService.pause(id: id)
                }
                return
            }

            refreshedItem.backendIdentifier = String(processIdentifier)
            refreshedItem.updatedAt = .now
            schedulePersist()
        } catch {
            guard let refreshedItem = item(for: id) else {
                return
            }

            guard isShuttingDown == false,
                  (refreshedItem.status == .preparing || refreshedItem.status == .downloading) else {
                return
            }

            refreshedItem.backendIdentifier = nil
            refreshedItem.speedBytesPerSecond = 0
            refreshedItem.uploadBytesPerSecond = 0
            refreshedItem.updatedAt = .now
            refreshedItem.lastError = error.localizedDescription
            transitionStatus(for: refreshedItem, to: .failed)
            presentMediaErrorIfNeeded(error)
            schedulePersist()
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private func startTorrentDownload(id: UUID) async {
        defer {
            torrentStartTasks.removeValue(forKey: id)
        }

        guard let currentItem = item(for: id) else {
            return
        }

        guard currentItem.status == .preparing || currentItem.status == .seeding else {
            return
        }

        let hadBackendIdentifier = currentItem.backendIdentifier != nil
        var activeBackendIdentifier = currentItem.backendIdentifier

        do {
            if let backendIdentifier = currentItem.backendIdentifier {
                do {
                    let lineage = try await torrentService.followedStatus(for: backendIdentifier)
                    let snapshot = lineage.currentSnapshot
                    if snapshot.status == "paused" {
                        try await torrentService.unpause(gid: backendIdentifier)
                    } else if snapshot.status == "removed" || snapshot.status == "error" {
                        throw TorrentEngineError.rpc("GID (backendIdentifier) was not found")
                    }
                } catch {
                    guard isStaleTorrentIdentifierError(error) else {
                        throw error
                    }

                    guard let refreshedItem = item(for: id) else {
                        return
                    }

                    refreshedItem.backendIdentifier = nil
                    let replacementIdentifier = try await torrentService.addDownload(
                        sourceKind: refreshedItem.sourceKind,
                        sourceURL: torrentEngineSourceURL(for: refreshedItem),
                        destinationFolderPath: refreshedItem.destinationFolderPath,
                        transferOptions: torrentTransferOptions(for: refreshedItem)
                    )

                    guard item(for: id) != nil else {
                        await torrentService.remove(gid: replacementIdentifier)
                        return
                    }

                    activeBackendIdentifier = replacementIdentifier
                }
            } else {
                let backendIdentifier = try await torrentService.addDownload(
                    sourceKind: currentItem.sourceKind,
                    sourceURL: torrentEngineSourceURL(for: currentItem),
                    destinationFolderPath: currentItem.destinationFolderPath,
                    transferOptions: torrentTransferOptions(for: currentItem)
                )
                guard item(for: id) != nil else {
                    await torrentService.remove(gid: backendIdentifier)
                    return
                }
                activeBackendIdentifier = backendIdentifier
            }

            guard let refreshedItem = item(for: id),
                  let activeBackendIdentifier else {
                return
            }

            let isSameStartAttempt = (refreshedItem.status == .preparing
                || (refreshedItem.status == .seeding && refreshedItem.finishedAt != nil))
            let isSameTorrentAlreadyObserved = refreshedItem.backendIdentifier == activeBackendIdentifier
                && (refreshedItem.status == .downloading
                    || refreshedItem.status == .queued
                    || refreshedItem.status == .seeding)

            if isSameStartAttempt == false,
               isSameTorrentAlreadyObserved == false {
                await settleStartedTorrent(activeBackendIdentifier, for: refreshedItem)
                return
            }

            refreshedItem.backendIdentifier = activeBackendIdentifier
            setStatus(
                for: refreshedItem,
                to: refreshedItem.finishedAt == nil ? .downloading : .seeding
            )
            refreshedItem.updatedAt = .now
            schedulePersist()
        } catch {
            guard let refreshedItem = item(for: id) else {
                return
            }

            guard isShuttingDown == false,
                  (refreshedItem.status == .preparing || refreshedItem.status == .seeding) else {
                return
            }

            if hadBackendIdentifier, isTransientTorrentEngineError(error) {
                setStatus(for: refreshedItem, to: .paused)
                refreshedItem.speedBytesPerSecond = 0
                refreshedItem.uploadBytesPerSecond = 0
                refreshedItem.updatedAt = .now
                refreshedItem.lastError = error.localizedDescription
                schedulePersist()
                return
            }

            refreshedItem.backendIdentifier = nil
            refreshedItem.speedBytesPerSecond = 0
            refreshedItem.uploadBytesPerSecond = 0
            refreshedItem.updatedAt = .now
            refreshedItem.lastError = error.localizedDescription
            transitionStatus(for: refreshedItem, to: .failed)
            presentTorrentErrorIfNeeded(error)
            schedulePersist()
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private func settleStartedTorrent(
        _ backendIdentifier: String,
        for item: DownloadItem
    ) async {
        switch item.status {
        case .paused:
            item.backendIdentifier = backendIdentifier
            try? await torrentService.pause(gid: backendIdentifier)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            schedulePersist()

        case .cancelled, .completed, .failed, .browserSessionRequired:
            do {
                try await torrentService.removeAndConfirmStopped(gid: backendIdentifier)
                if item.backendIdentifier == backendIdentifier {
                    item.backendIdentifier = nil
                }
            } catch {
                item.backendIdentifier = backendIdentifier
                item.lastError = error.localizedDescription
            }
            schedulePersist()

        case .queued, .preparing, .downloading, .seeding:
            do {
                try await torrentService.removeAndConfirmStopped(gid: backendIdentifier)
                if item.backendIdentifier == backendIdentifier {
                    item.backendIdentifier = nil
                }
            } catch {
                item.backendIdentifier = backendIdentifier
                item.lastError = error.localizedDescription
            }
            schedulePersist()
        }
    }

    private func torrentEngineSourceURL(for item: DownloadItem) -> URL {
        guard let managedTorrentSourcePath = item.managedTorrentSourcePath else {
            return item.sourceURL
        }

        return URL(fileURLWithPath: managedTorrentSourcePath)
    }

    private func pauseDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        if item.status == .seeding, item.finishedAt != nil {
            stopSeeding(id: id)
            return
        }

        let shouldWaitForMediaProcess = item.backend == .ytDlp
            && (item.backendIdentifier != nil || mediaStartTasks[id] != nil)

        setStatus(for: item, to: .paused)
        item.taskIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            coordinator.pauseDownload(id: id)
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    try? await torrentService.pause(gid: backendIdentifier)
                }
            }
        case .ytDlp:
            Task {
                await mediaService.pause(id: id)
            }
        }

        schedulePersist()
        if shouldWaitForMediaProcess == false {
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private var currentRunningDownloadsCount: Int {
        downloads.filter(\.isRunning).count
    }

    private func startNextQueuedDownloadsIfNeeded() {
        guard isShuttingDown == false else {
            return
        }

        let availableSlots = max(settings.transferSettings.maxConcurrentDownloads - currentRunningDownloadsCount, 0)
        guard availableSlots > 0 else {
            return
        }

        let queuedItems = downloads
            .filter { $0.status == .queued }
            .sorted { $0.createdAt < $1.createdAt }

        for item in queuedItems.prefix(availableSlots) {
            startOrQueueDownload(id: item.id)
        }
    }

    private func applyTransferSettings(_ transferSettings: DownloadTransferSettings) {
        coordinator.updateTransferSettings(transferSettings)

        let activeTorrentItems = downloads.filter {
            $0.backend == .aria2 && $0.backendIdentifier != nil
        }
        let activeTorrentIdentifiers = activeTorrentItems.compactMap(\.backendIdentifier)
        let transferOptionsByGID = Dictionary(uniqueKeysWithValues: activeTorrentItems.compactMap { item in
            item.backendIdentifier.map { ($0, torrentTransferOptions(for: item)) }
        })

        Task { [torrentService] in
            await torrentService.updateTransferSettings(
                transferSettings,
                activeGIDs: activeTorrentIdentifiers,
                transferOptionsByGID: transferOptionsByGID
            )
        }

        startNextQueuedDownloadsIfNeeded()
    }

    private func torrentTransferOptions(for item: DownloadItem) -> TorrentTransferOptions {
        TorrentTransferOptions(
            downloadLimitBytesPerSecond: item.downloadLimitOverride.resolvedBytesPerSecond(
                inheriting: settings.transferSettings.perDownloadSpeedLimitBytesPerSecond
            ),
            uploadLimitBytesPerSecond: item.uploadLimitOverride.resolvedBytesPerSecond(
                inheriting: settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond
            ),
            shouldSeed: item.shouldSeedAfterDownload,
            seedRatioLimit: settings.seedingRatioLimit,
            verifyExistingData: item.finishedAt != nil
        )
    }

    private func effectiveMediaDownloadLimit(for item: DownloadItem) -> Int64? {
        var limits: [Int64] = []

        if let globalLimit = settings.transferSettings.globalSpeedLimitBytesPerSecond {
            limits.append(globalLimit)
        }

        if let itemLimit = item.downloadLimitOverride.resolvedBytesPerSecond(
            inheriting: settings.transferSettings.perDownloadSpeedLimitBytesPerSecond
        ) {
            limits.append(itemLimit)
        }

        return limits.min()
    }

    private func startTorrentRefreshLoopIfNeeded() {
        guard torrentRefreshTask == nil else {
            return
        }

        torrentRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                await self?.refreshTorrentDownloads()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshTorrentDownloads() async {
        let torrentItems = downloads.filter {
            $0.backend == .aria2 && $0.backendIdentifier != nil
        }

        guard torrentItems.isEmpty == false else {
            return
        }

        var didMutate = false

        for item in torrentItems {
            guard let backendIdentifier = item.backendIdentifier,
                  torrentStartTasks[item.id] == nil else {
                continue
            }
            let expectedStatus = item.status
            let lifecycleVersion = item.updatedAt

            do {
                let lineage = try await torrentService.followedStatus(for: backendIdentifier)
                guard let refreshedItem = self.item(for: item.id),
                      refreshedItem === item,
                      refreshedItem.backendIdentifier == backendIdentifier,
                      refreshedItem.status == expectedStatus,
                      refreshedItem.updatedAt == lifecycleVersion,
                      torrentStartTasks[item.id] == nil,
                      isShuttingDown == false else {
                    continue
                }
                await apply(lineage: lineage, to: refreshedItem)
                didMutate = true
            } catch {
                guard let refreshedItem = self.item(for: item.id),
                      refreshedItem === item,
                      refreshedItem.backendIdentifier == backendIdentifier,
                      refreshedItem.status == expectedStatus,
                      refreshedItem.updatedAt == lifecycleVersion,
                      torrentStartTasks[item.id] == nil,
                      isShuttingDown == false else {
                    continue
                }

                if isStaleTorrentIdentifierError(error) {
                    refreshedItem.backendIdentifier = nil
                    refreshedItem.speedBytesPerSecond = 0
                    refreshedItem.uploadBytesPerSecond = 0
                    refreshedItem.updatedAt = .now

                    if Self.shouldRestartStaleSeeder(
                        persistedStatus: refreshedItem.status,
                        hasFinishedData: refreshedItem.finishedAt != nil,
                        shouldSeed: refreshedItem.shouldSeedAfterDownload
                    ) {
                        setStatus(for: refreshedItem, to: .preparing)
                        Task { @MainActor [weak self] in
                            self?.startOrQueueDownload(id: refreshedItem.id)
                        }
                        didMutate = true
                        continue
                    }

                    refreshedItem.lastError = String(
                        localized: "torrent.restart.resumeToContinue",
                        defaultValue: "Torrent engine restarted. Resume to continue.",
                        comment: "Status message shown after the torrent engine restarts and a transfer can be resumed."
                    )
                    setStatus(for: refreshedItem, to: .paused)
                    didMutate = true
                    continue
                }

                if isTransientTorrentEngineError(error) {
                    refreshedItem.speedBytesPerSecond = 0
                    refreshedItem.uploadBytesPerSecond = 0
                    refreshedItem.updatedAt = .now
                    refreshedItem.lastError = error.localizedDescription
                    didMutate = true
                    continue
                }

                refreshedItem.backendIdentifier = nil
                refreshedItem.speedBytesPerSecond = 0
                refreshedItem.uploadBytesPerSecond = 0
                refreshedItem.updatedAt = .now
                refreshedItem.lastError = error.localizedDescription
                transitionStatus(for: refreshedItem, to: .failed)
                didMutate = true
            }
        }

        if didMutate {
            schedulePersist()
        }
    }

    nonisolated static func shouldPauseRestoredTorrent(
        persistedStatus: DownloadStatus,
        engineStatus: String
    ) -> Bool {
        persistedStatus == .paused
            && (engineStatus == "active" || engineStatus == "waiting")
    }

    nonisolated static func shouldRestartStaleSeeder(
        persistedStatus: DownloadStatus,
        hasFinishedData: Bool,
        shouldSeed: Bool
    ) -> Bool {
        persistedStatus == .seeding && hasFinishedData && shouldSeed
    }

    nonisolated static func shouldRepairMetadataOnlyMagnetCompletion(
        sourceKind: DownloadSourceKind,
        status: DownloadStatus,
        fileLocationPath: String?,
        payloadPaths: [String]
    ) -> Bool {
        guard sourceKind == .magnetLink, status == .completed else {
            return false
        }

        return ([fileLocationPath].compactMap { $0 } + payloadPaths).contains { path in
            URL(fileURLWithPath: path).lastPathComponent.hasPrefix("[METADATA]")
        }
    }

    nonisolated static func orphanedTorrentGIDs(
        engineGIDs: Set<String>,
        retainedGIDs: Set<String>
    ) -> Set<String> {
        engineGIDs.subtracting(retainedGIDs)
    }

    nonisolated static func shouldAwaitMagnetPayload(
        sourceKind: DownloadSourceKind,
        lineage: TorrentStatusLineage
    ) -> Bool {
        sourceKind == .magnetLink && lineage.isMetadataOnly
    }

    private func apply(lineage: TorrentStatusLineage, to item: DownloadItem) async {
        let snapshot = lineage.currentSnapshot

        if Self.shouldAwaitMagnetPayload(sourceKind: item.sourceKind, lineage: lineage) {
            item.speedBytesPerSecond = snapshot.downloadSpeed
            item.uploadBytesPerSecond = snapshot.uploadSpeed
            item.metadataName = snapshot.metadataName ?? item.metadataName
            item.updatedAt = .now
            item.lastError = nil
            if item.status != .paused {
                setStatus(for: item, to: .downloading)
            }
            return
        }

        if item.status == .paused,
           (snapshot.status == "active" || snapshot.status == "waiting") {
            try? await torrentService.pause(gid: lineage.rootGID)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            return
        }

        item.bytesWritten = snapshot.completedLength
        item.uploadedBytes = max(snapshot.uploadLength, 0)
        item.expectedBytes = max(snapshot.totalLength, 0)
        if snapshot.totalLength > 0 {
            item.progress = Double(snapshot.completedLength) / Double(snapshot.totalLength)
        }
        item.speedBytesPerSecond = snapshot.downloadSpeed
        item.uploadBytesPerSecond = snapshot.uploadSpeed
        item.metadataName = snapshot.metadataName ?? item.metadataName
        if let infoHash = ManagedTorrentSourceStore.normalizedInfoHash(snapshot.infoHash) {
            item.torrentFingerprint = infoHash
        }
        item.torrentPayloadPaths = snapshot.filePaths
        item.updatedAt = .now

        if let primaryPath = snapshot.primaryPath {
            item.fileLocationPath = primaryPath
        }

        switch snapshot.status {
        case "active":
            if snapshot.isSeeder
                || (snapshot.totalLength > 0 && snapshot.completedLength >= snapshot.totalLength && item.finishedAt != nil) {
                await handleTorrentDataCompletion(
                    item,
                    gid: lineage.rootGID,
                    continuesSeeding: item.shouldSeedAfterDownload
                )
            } else {
                setStatus(for: item, to: .downloading)
                item.lastError = nil
            }

        case "waiting":
            setStatus(for: item, to: item.finishedAt == nil ? .queued : .seeding)

        case "paused":
            guard item.status != .preparing else {
                break
            }
            setStatus(for: item, to: .paused)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0

        case "error":
            item.lastError = snapshot.errorMessage ?? String(
                localized: "torrent.error.generic",
                defaultValue: "Torrent engine reported an error.",
                comment: "Fallback error message shown when the torrent engine reports an error without details."
            )
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            let gid = lineage.rootGID
            item.backendIdentifier = nil
            if item.finishedAt != nil {
                item.shouldSeedAfterDownload = false
                setStatus(for: item, to: .completed)
            } else {
                transitionStatus(for: item, to: .failed)
            }
            Task {
                await torrentService.remove(gid: gid)
            }
            startNextQueuedDownloadsIfNeeded()

        case "complete":
            await handleTorrentDataCompletion(
                item,
                gid: lineage.rootGID,
                continuesSeeding: false
            )

        case "removed":
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.backendIdentifier = nil
            transitionStatus(for: item, to: .cancelled)
            startNextQueuedDownloadsIfNeeded()

        default:
            break
        }
    }

    private func handleTorrentDataCompletion(
        _ item: DownloadItem,
        gid: String,
        continuesSeeding: Bool
    ) async {
        let didCompleteNow = item.finishedAt == nil
        item.progress = 1
        item.bytesWritten = max(item.bytesWritten, item.expectedBytes)
        item.finishedAt = item.finishedAt ?? .now
        item.lastError = nil
        item.speedBytesPerSecond = 0

        if continuesSeeding {
            if didCompleteNow {
                item.recordActivity(.completed)
            }
            setStatus(for: item, to: .seeding)
        } else {
            item.uploadBytesPerSecond = 0
            item.backendIdentifier = nil
            if didCompleteNow {
                setStatus(for: item, to: .completed)
            } else {
                setStatus(for: item, to: .completed)
            }
            Task {
                await torrentService.remove(gid: gid)
            }
        }

        await persistCompletionAndNotifyIfNeeded(item)

        startNextQueuedDownloadsIfNeeded()
    }

    private func persistCompletionAndNotifyIfNeeded(_ item: DownloadItem) async {
        guard item.completionNotificationDelivered == false else {
            return
        }

        item.completionNotificationDelivered = true
        persistTask?.cancel()
        persistTask = nil

        do {
            try await persistence.save(downloads.map { $0.makeRecord() })
            guard let currentItem = self.item(for: item.id),
                  currentItem === item,
                  currentItem.completionNotificationDelivered,
                  (currentItem.status == .completed || currentItem.status == .seeding) else {
                return
            }
            deliverNotificationIfEnabled(for: currentItem, status: .completed)
        } catch {
            item.completionNotificationDelivered = false
            schedulePersist()
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Save Completed Torrent"),
                message: error.localizedDescription
            )
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case let .started(id, taskIdentifier):
            guard let item = item(for: id) else {
                return
            }

            item.taskIdentifier = taskIdentifier
            setStatus(for: item, to: .downloading)
            item.updatedAt = .now
            item.uploadBytesPerSecond = 0

        case let .progress(id, bytesWritten, expectedBytes, speedBytesPerSecond):
            guard let item = item(for: id) else {
                return
            }

            item.bytesWritten = bytesWritten
            item.expectedBytes = max(expectedBytes, item.expectedBytes)
            if expectedBytes > 0 {
                item.progress = Double(bytesWritten) / Double(expectedBytes)
            }
            item.speedBytesPerSecond = speedBytesPerSecond
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

        case let .paused(id, resumeData):
            guard let item = item(for: id) else {
                return
            }

            item.resumeData = resumeData
            item.taskIdentifier = nil
            setStatus(for: item, to: .paused)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()

        case let .cancelled(id):
            guard let item = item(for: id) else {
                return
            }

            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .cancelled)
            startNextQueuedDownloadsIfNeeded()

        case let .failed(id, message, resumeData):
            guard let item = item(for: id) else {
                return
            }

            item.taskIdentifier = nil
            item.lastError = message
            item.resumeData = resumeData
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .failed)
            startNextQueuedDownloadsIfNeeded()

        case let .finished(id, temporaryURL, suggestedFilename, responseMimeType, statusCode):
            guard let item = item(for: id) else {
                return
            }

            if DownloadedPayloadClassifier.isTorrent(
                sourceURL: item.sourceURL,
                suggestedFilename: suggestedFilename,
                responseMimeType: responseMimeType,
                statusCode: statusCode
            ) {
                beginDownloadedTorrentHandoff(
                    for: item,
                    temporaryURL: temporaryURL
                )
                return
            }

            do {
                try finalizeFileDownload(
                    for: item,
                    temporaryURL: temporaryURL,
                    suggestedFilename: suggestedFilename,
                    responseMimeType: responseMimeType,
                    statusCode: statusCode
                )
            } catch let error as DirectDownloadValidationError {
                switch error {
                case let .browserSessionRequired(message):
                    markBrowserSessionRequired(item, message: message)
                    try? FileManager.default.removeItem(at: temporaryURL)
                case .invalidResponse:
                    item.lastError = error.localizedDescription
                    transitionStatus(for: item, to: .failed)
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            } catch {
                item.lastError = error.localizedDescription
                transitionStatus(for: item, to: .failed)
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()
        }

        schedulePersist()
    }

    private func handle(_ event: BrowserDownloadEvent) {
        switch event {
        case let .started(id, _, expectedBytes, _, _):
            guard let item = item(for: id) else {
                return
            }

            activeBrowserSession = nil
            setStatus(for: item, to: .downloading)
            item.progress = 0
            item.bytesWritten = 0
            if expectedBytes > 0 {
                item.expectedBytes = max(item.expectedBytes, expectedBytes)
            }
            item.lastError = nil
            item.resumeData = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            item.startedAt = item.startedAt ?? .now

        case let .finished(id, temporaryURL, suggestedFilename, responseMimeType, statusCode, expectedBytes):
            guard let item = item(for: id) else {
                return
            }

            if DownloadedPayloadClassifier.isTorrent(
                sourceURL: item.sourceURL,
                suggestedFilename: suggestedFilename,
                responseMimeType: responseMimeType,
                statusCode: statusCode
            ) {
                beginDownloadedTorrentHandoff(
                    for: item,
                    temporaryURL: temporaryURL
                )
                return
            }

            do {
                try finalizeFileDownload(
                    for: item,
                    temporaryURL: temporaryURL,
                    suggestedFilename: suggestedFilename,
                    responseMimeType: responseMimeType,
                    statusCode: statusCode,
                    expectedBytesOverride: expectedBytes
                )
            } catch {
                item.lastError = error.localizedDescription
                transitionStatus(for: item, to: .failed)
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()

        case let .failed(id, message):
            activeBrowserSession = nil

            guard let item = item(for: id) else {
                return
            }

            item.lastError = message
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .failed)
            startNextQueuedDownloadsIfNeeded()
        }

        schedulePersist()
    }

    private func handle(_ event: MediaDownloadEvent) {
        if let id = mediaDownloadID(from: event),
           item(for: id) == nil {
            if mediaEventReleasesQueueSlot(event) {
                startNextQueuedDownloadsIfNeeded()
            }
            return
        }

        switch event {
        case let .started(id, processIdentifier, expectedBytes, title, _):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = String(processIdentifier)
            item.metadataName = title ?? item.metadataName
            if expectedBytes > 0 {
                item.expectedBytes = max(item.expectedBytes, expectedBytes)
            }
            setStatus(for: item, to: .downloading)
            item.lastError = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

        case let .progress(id, bytesWritten, expectedBytes, speedBytesPerSecond):
            guard let item = item(for: id) else {
                return
            }

            item.bytesWritten = max(item.bytesWritten, bytesWritten)
            item.expectedBytes = max(item.expectedBytes, expectedBytes)
            if item.expectedBytes > 0 {
                item.progress = Double(item.bytesWritten) / Double(item.expectedBytes)
            }
            item.speedBytesPerSecond = speedBytesPerSecond
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

        case let .paused(id):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = nil
            setStatus(for: item, to: .paused)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()

        case let .cancelled(id):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .cancelled)
            startNextQueuedDownloadsIfNeeded()

        case let .finished(id, fileURL, expectedBytes):
            guard let item = item(for: id) else {
                return
            }

            item.fileLocationPath = fileURL.path
            item.preferredFilename = fileURL.lastPathComponent
            item.progress = 1
            item.expectedBytes = max(item.expectedBytes, expectedBytes, item.bytesWritten)
            item.bytesWritten = max(item.bytesWritten, item.expectedBytes)
            item.finishedAt = .now
            item.lastError = nil
            item.backendIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .completed)
            startNextQueuedDownloadsIfNeeded()

        case let .failed(id, message):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = nil
            item.lastError = message
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

            if message == MediaDownloadErrorClassifier.selectedFormatUnavailableMessage {
                item.mediaMetadata = item.mediaMetadata?.persistenceSnapshot
            }

            transitionStatus(for: item, to: .failed)
            startNextQueuedDownloadsIfNeeded()
        }

        schedulePersist()
    }

    private func mediaDownloadID(from event: MediaDownloadEvent) -> UUID? {
        switch event {
        case let .started(id, _, _, _, _),
             let .progress(id, _, _, _),
             let .paused(id),
             let .cancelled(id),
             let .finished(id, _, _),
             let .failed(id, _):
            id
        }
    }

    private func mediaEventReleasesQueueSlot(_ event: MediaDownloadEvent) -> Bool {
        switch event {
        case .paused, .cancelled, .finished, .failed:
            true
        case .started, .progress:
            false
        }
    }

    private func item(for id: UUID) -> DownloadItem? {
        downloads.first { $0.id == id }
    }

    private func finalizeFileDownload(
        for item: DownloadItem,
        temporaryURL: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?,
        expectedBytesOverride: Int64? = nil
    ) throws {
        try validateDownloadedPayload(
            for: item,
            temporaryURL: temporaryURL,
            suggestedFilename: suggestedFilename,
            responseMimeType: responseMimeType,
            statusCode: statusCode
        )

        let destinationURL = try destinationResolver.moveDownloadedFile(
            from: temporaryURL,
            customFilename: item.preferredFilename,
            responseSuggestedFilename: suggestedFilename,
            sourceURL: item.sourceURL,
            into: item.destinationFolderURL
        )

        let expectedBytes = max(item.expectedBytes, expectedBytesOverride ?? 0)

        item.fileLocationPath = destinationURL.path
        item.preferredFilename = destinationURL.lastPathComponent
        item.progress = 1
        item.expectedBytes = max(expectedBytes, item.bytesWritten)
        item.bytesWritten = max(item.bytesWritten, item.expectedBytes)
        item.finishedAt = .now
        item.lastError = nil
        item.resumeData = nil
        transitionStatus(for: item, to: .completed)
    }

    private func beginDownloadedTorrentHandoff(
        for item: DownloadItem,
        temporaryURL: URL
    ) {
        Self.configureDownloadedTorrentHandoff(
            item,
            shouldSeedAfterDownload: settings.seedNewTorrents
        )
        schedulePersist()

        torrentStartTasks[item.id] = Task { @MainActor [weak self] in
            await self?.completeDownloadedTorrentHandoff(
                id: item.id,
                temporaryURL: temporaryURL
            )
        }
    }

    static func configureDownloadedTorrentHandoff(
        _ item: DownloadItem,
        shouldSeedAfterDownload: Bool
    ) {
        item.sourceKind = .torrentFile
        item.backend = .aria2
        item.preferredFilename = nil
        item.fileLocationPath = nil
        item.progress = 0
        item.bytesWritten = 0
        item.expectedBytes = 0
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.finishedAt = nil
        item.lastError = nil
        item.resumeData = nil
        item.taskIdentifier = nil
        item.backendIdentifier = nil
        item.shouldSeedAfterDownload = shouldSeedAfterDownload
        item.completionNotificationDelivered = false
        item.updatedAt = .now

        // Keep the original Started activity. This is one download changing engines, not a second download.
        item.status = .preparing
    }

    private func completeDownloadedTorrentHandoff(
        id: UUID,
        temporaryURL: URL
    ) async {
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
            torrentStartTasks.removeValue(forKey: id)
        }

        guard let currentItem = item(for: id),
              currentItem.sourceKind == .torrentFile,
              currentItem.backend == .aria2 else {
            return
        }

        do {
            let managedSource = try await managedTorrentSourceStore.prepareLocalTorrent(
                at: temporaryURL,
                originalURL: currentItem.sourceURL
            )

            guard let refreshedItem = item(for: id) else {
                return
            }

            refreshedItem.torrentFingerprint = managedSource.fingerprint
            refreshedItem.torrentSourceFingerprint = managedSource.sourceFingerprint
            refreshedItem.managedTorrentSourcePath = managedSource.managedURL.path
            refreshedItem.updatedAt = .now
            schedulePersist()

            guard refreshedItem.status == .preparing,
                  isShuttingDown == false else {
                return
            }

            if let existingItem = downloads.first(where: {
                $0.id != id && Self.torrentIdentity(for: $0) == managedSource.fingerprint
            }) {
                downloads.removeAll { $0.id == id }
                selectedDownloadIDs.remove(id)
                selectDownload(existingItem.id)
                activeAlert = UserAlert(
                    title: String(localized: "Torrent Already Added"),
                    message: String(localized: "This torrent is already in Harbor.")
                )
                schedulePersist()
                startNextQueuedDownloadsIfNeeded()
                return
            }

            await startTorrentDownload(id: id)
        } catch {
            guard let refreshedItem = item(for: id),
                  refreshedItem.status == .preparing else {
                return
            }

            refreshedItem.lastError = error.localizedDescription
            refreshedItem.speedBytesPerSecond = 0
            refreshedItem.uploadBytesPerSecond = 0
            refreshedItem.updatedAt = .now
            transitionStatus(for: refreshedItem, to: .failed)
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Import Torrent"),
                message: error.localizedDescription
            )
            schedulePersist()
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private func markBrowserSessionRequired(_ item: DownloadItem, message: String) {
        item.taskIdentifier = nil
        setStatus(for: item, to: .browserSessionRequired)
        item.progress = 0
        item.bytesWritten = 0
        item.expectedBytes = 0
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.lastError = message
        item.resumeData = nil
        item.updatedAt = .now
    }

    private func validateDownloadedPayload(
        for item: DownloadItem,
        temporaryURL: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?
    ) throws {
        guard item.backend == .urlSession else {
            return
        }

        if let statusCode, (200 ... 299).contains(statusCode) == false {
            let template = String(
                localized: "error.direct.httpStatus",
                defaultValue: "The server returned HTTP %d instead of a downloadable file.",
                comment: "Download validation error. Parameter is an HTTP status code."
            )

            throw DirectDownloadValidationError.invalidResponse(
                String(format: template, statusCode)
            )
        }

        guard shouldAllowHTMLDownload(for: item, suggestedFilename: suggestedFilename) == false else {
            return
        }

        let normalizedMimeType = responseMimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let isHTMLMimeType = normalizedMimeType == "text/html"
            || normalizedMimeType == "application/xhtml+xml"

        if isHTMLMimeType || payloadLooksLikeHTML(at: temporaryURL) {
            throw DirectDownloadValidationError.browserSessionRequired(
                String(
                    localized: "error.direct.browserSessionRequired",
                    defaultValue: "This site requires a browser session before Harbor can download the file.",
                    comment: "Download validation error shown when a site requires browser authentication before downloading."
                )
            )
        }
    }

    private func shouldAllowHTMLDownload(
        for item: DownloadItem,
        suggestedFilename: String?
    ) -> Bool {
        let extensions = [
            item.preferredFilename.flatMap {
                let pathExtension = URL(fileURLWithPath: $0).pathExtension
                return pathExtension.isEmpty ? nil : pathExtension
            },
            suggestedFilename.flatMap {
                let pathExtension = URL(fileURLWithPath: $0).pathExtension
                return pathExtension.isEmpty ? nil : pathExtension
            },
            item.sourceURL.pathExtension.isEmpty ? nil : item.sourceURL.pathExtension
        ]
            .compactMap { $0?.lowercased() }

        return extensions.contains("html") || extensions.contains("htm")
    }

    private func payloadLooksLikeHTML(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }

        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: 1024),
              let sample = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            return false
        }

        return sample.hasPrefix("<!doctype html")
            || sample.hasPrefix("<html")
            || sample.contains("<html")
    }

    private func presentNextQueuedExternalAddSheetIfNeeded() {
        guard addSheetDraft == nil,
              pendingExternalAddSheetDrafts.isEmpty == false
        else {
            return
        }

        addSheetDraft = pendingExternalAddSheetDrafts.removeFirst()
    }

    private func makeBlankAddSheetDraft() -> AddDownloadSheetDraft {
        AddDownloadSheetDraft.blank(
            destinationFolderURL: settings.defaultDestinationURL,
            shouldStartImmediately: settings.startDownloadsAutomatically
        )
    }

    private func makeExternalTorrentDraft(for fileURL: URL) -> AddDownloadSheetDraft {
        AddDownloadSheetDraft.torrentFile(
            fileURL,
            destinationFolderURL: settings.torrentDestinationURL,
            shouldStartImmediately: settings.startDownloadsAutomatically
        )
    }

    private func makeExternalAddSheetDraft(for url: URL) -> AddDownloadSheetDraft? {
        switch DownloadSourceKind.detect(from: url) {
        case .magnetLink:
            AddDownloadSheetDraft.linkOrMagnet(
                url,
                destinationFolderURL: settings.torrentDestinationURL,
                shouldStartImmediately: settings.startDownloadsAutomatically
            )
        case .torrentFile:
            makeExternalTorrentDraft(for: url)
        case .directURL, .mediaURL:
            AddDownloadSheetDraft.linkOrMagnet(
                url,
                destinationFolderURL: settings.defaultDestinationURL,
                shouldStartImmediately: settings.startDownloadsAutomatically
            )
        case nil:
            nil
        }
    }

    private func transitionStatus(
        for item: DownloadItem,
        to status: DownloadStatus
    ) {
        let previousStatus = item.status
        setStatus(for: item, to: status)

        if status == .completed {
            item.completionNotificationDelivered = true
        }

        guard previousStatus != status,
              status == .completed || status == .failed || status == .cancelled
        else {
            return
        }

        deliverNotificationIfEnabled(for: item, status: status)
    }

    private func deliverNotificationIfEnabled(
        for item: DownloadItem,
        status: DownloadStatus
    ) {
        guard settings.notificationsEnabled,
              let payload = notificationPayload(for: item, status: status) else {
            return
        }

        Task { [notificationService] in
            await notificationService.deliver(payload)
        }
    }

    private func setStatus(
        for item: DownloadItem,
        to status: DownloadStatus
    ) {
        let previousStatus = item.status
        item.status = status

        guard previousStatus != status,
              let activityKind = activityKind(from: previousStatus, to: status)
        else {
            return
        }

        item.recordActivity(activityKind)
    }

    private func activityKind(
        from previousStatus: DownloadStatus,
        to status: DownloadStatus
    ) -> DownloadActivityKind? {
        switch status {
        case .queued:
            .queued
        case .preparing:
            if previousStatus == .completed || previousStatus == .seeding {
                nil
            } else {
                previousStatus == .paused || previousStatus == .browserSessionRequired ? .resumed : .started
            }
        case .downloading:
            if previousStatus == .paused || previousStatus == .browserSessionRequired {
                .resumed
            } else if previousStatus == .queued {
                .started
            } else {
                nil
            }
        case .seeding:
            .seedingStarted
        case .browserSessionRequired:
            .browserSessionRequired
        case .paused:
            .paused
        case .completed:
            previousStatus == .seeding ? .seedingStopped : .completed
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    private func notificationPayload(
        for item: DownloadItem,
        status: DownloadStatus
    ) -> DownloadNotificationPayload? {
        let title: String
        let body: String

        switch status {
        case .completed:
            title = String(
                localized: "notification.downloadFinished.title",
                defaultValue: "Download Finished",
                comment: "Notification title for a completed download."
            )
            body = String(
                format: String(
                    localized: "notification.downloadFinished.body",
                    defaultValue: "%@ is ready.",
                    comment: "Notification body for a completed download. Parameter is the download name."
                ),
                item.displayName
            )
        case .failed:
            title = String(
                localized: "notification.downloadFailed.title",
                defaultValue: "Download Failed",
                comment: "Notification title for a failed download."
            )
            body = item.displayLastError ?? String(
                format: String(
                    localized: "notification.downloadFailed.body",
                    defaultValue: "%@ couldn’t be downloaded.",
                    comment: "Notification body for a failed download. Parameter is the download name."
                ),
                item.displayName
            )
        case .cancelled:
            title = String(
                localized: "notification.downloadCancelled.title",
                defaultValue: "Download Cancelled",
                comment: "Notification title for a cancelled download."
            )
            body = String(
                format: String(
                    localized: "notification.downloadCancelled.body",
                    defaultValue: "%@ was cancelled.",
                    comment: "Notification body for a cancelled download. Parameter is the download name."
                ),
                item.displayName
            )
        case .queued, .preparing, .downloading, .seeding, .browserSessionRequired, .paused:
            return nil
        }

        return DownloadNotificationPayload(
            identifier: "download-\(item.id.uuidString)-\(status.rawValue)",
            title: title,
            body: body
        )
    }

    private func cleanupBackendIdentifiers(for items: [DownloadItem]) {
        let backendIdentifiers = items
            .filter { $0.backend == .aria2 }
            .compactMap(\.backendIdentifier)

        let mediaIDs = items
            .filter { $0.backend == .ytDlp }
            .map(\.id)

        guard backendIdentifiers.isEmpty == false || mediaIDs.isEmpty == false else {
            return
        }

        Task {
            for backendIdentifier in backendIdentifiers {
                await torrentService.remove(gid: backendIdentifier)
            }

            for id in mediaIDs {
                await mediaService.remove(id: id)
            }
        }
    }

    private func presentMediaErrorIfNeeded(_ error: Error) {
        if hasShownMediaRuntimeAlert,
           case MediaDownloadError.runtimeNotFound = error {
            return
        }

        if case MediaDownloadError.runtimeNotFound = error {
            hasShownMediaRuntimeAlert = true
        }

        activeAlert = UserAlert(
            title: mediaErrorTitle(for: error),
            message: DownloadItem.displayErrorMessage(from: error.localizedDescription)
        )
    }

    private func presentTorrentErrorIfNeeded(_ error: Error) {
        if hasShownTorrentBinaryAlert,
           case TorrentEngineError.binaryNotFound = error {
            return
        }

        if case TorrentEngineError.binaryNotFound = error {
            hasShownTorrentBinaryAlert = true
        }

        activeAlert = UserAlert(
            title: torrentErrorTitle(for: error),
            message: DownloadItem.displayErrorMessage(from: error.localizedDescription)
        )
    }

    private func isTransientTorrentEngineError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                break
            }
        }

        if case let TorrentEngineError.startupFailed(message) = error {
            return message.localizedCaseInsensitiveContains("timed out")
        }

        return false
    }

    private func isStaleTorrentIdentifierError(_ error: Error) -> Bool {
        guard case let TorrentEngineError.rpc(message) = error else {
            return false
        }

        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("gid")
            && (
                normalizedMessage.contains("not found")
                    || normalizedMessage.contains("no such")
                    || normalizedMessage.contains("not exist")
            )
    }

    private func mediaErrorTitle(for error: Error) -> String {
        if case MediaDownloadError.runtimeNotFound = error {
            return String(
                localized: "alert.media.missingRuntime.title",
                defaultValue: "Media Support Needs yt-dlp",
                comment: "Alert title shown when the bundled yt-dlp media runtime cannot be found."
            )
        }

        return String(
            localized: "alert.media.engineError.title",
            defaultValue: "Media Engine Error",
            comment: "Alert title shown when the media backend reports an error."
        )
    }

    private func torrentErrorTitle(for error: Error) -> String {
        if case TorrentEngineError.binaryNotFound = error {
            return String(
                localized: "alert.torrent.missingAria2.title",
                defaultValue: "Torrent Support Needs aria2",
                comment: "Alert title shown when the bundled aria2 torrent runtime cannot be found."
            )
        }

        return String(
            localized: "alert.torrent.engineError.title",
            defaultValue: "Torrent Engine Error",
            comment: "Alert title shown when the torrent backend reports an error."
        )
    }

    private func schedulePersist() {
        let records = downloads.map { $0.makeRecord() }

        persistTask?.cancel()
        persistTask = Task { [persistence] in
            try? await Task.sleep(for: .milliseconds(250))
            try? await persistence.save(records)
        }
    }
}

private enum DirectDownloadValidationError: LocalizedError {
    case invalidResponse(String)
    case browserSessionRequired(String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(message), let .browserSessionRequired(message):
            message
        }
    }
}

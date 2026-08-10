import AppKit
import Foundation
import Observation

private struct DownloadRecoveryQuiescenceError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private enum DownloadCenterDurableMutationContext {
    @TaskLocal static var token: UUID?
}

@Observable
@MainActor
final class DownloadCenter {
    private struct PersistenceGateWaiter {
        let id: UUID
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum AttemptState: Equatable {
        case active(UUID)
        case pausing(UUID)
        case cancelling(UUID)
        case terminal(UUID)

        var identifier: UUID {
            switch self {
            case let .active(identifier),
                 let .pausing(identifier),
                 let .cancelling(identifier),
                 let .terminal(identifier):
                identifier
            }
        }
    }

    private enum PendingDirectPauseFailure {
        case direct(DirectDownloadFailure)
        case browser(DirectDownloadFailure)
    }

    private enum CompletedDirectPauseResult {
        case direct(DirectDownloadPauseResult)
        case browser(BrowserDownloadQuiescence)
    }

    private enum CompletedHandoffLookup: Sendable {
        case available(CompletedDownloadHandoff)
        case unavailable(String)
        case none
    }

    private enum PendingBrowserWriterMutation {
        case cancel
        case remove(removingData: Bool)
    }

    typealias DirectPauseOperation = @Sendable (
        DownloadCoordinator,
        UUID
    ) async -> DirectDownloadPauseResult
    typealias MediaCleanupOperation = @Sendable (MediaDownloadService, UUID) async throws -> Void
    typealias MediaPauseOperation = @Sendable (MediaDownloadService, UUID) async -> Void
    typealias TorrentPauseOperation = @Sendable (
        Aria2TorrentService,
        String
    ) async throws -> Void
    typealias TorrentStartOperation = @Sendable (
        Aria2TorrentService,
        UUID,
        DownloadSourceKind,
        URL,
        String,
        TorrentTransferOptions
    ) async throws -> String
    typealias TorrentRemoveOperation = @Sendable (
        Aria2TorrentService,
        String
    ) async throws -> Void
    typealias TorrentShutdownOperation = @Sendable (
        Aria2TorrentService
    ) async throws -> Void
    typealias BrowserQuiescenceOperation = @MainActor @Sendable (
        BrowserDownloadCoordinator,
        UUID
    ) async -> BrowserDownloadQuiescence?
    typealias URLSessionCleanupOperation = @MainActor @Sendable (
        DownloadCoordinator,
        BrowserDownloadCoordinator,
        UUID
    ) throws -> Void
    typealias RecordSaveOperation = @Sendable (
        DownloadPersistence,
        [DownloadRecord],
        DownloadPersistenceRevision
    ) async throws -> Void

    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let persistence: DownloadPersistence
    @ObservationIgnored private let destinationResolver: DownloadDestinationResolver
    @ObservationIgnored private let notificationService: DownloadNotificationService
    @ObservationIgnored private let dataRemovalService: DownloadDataRemovalService
    @ObservationIgnored private let managedTorrentSourceStore: ManagedTorrentSourceStore
    @ObservationIgnored private let torrentWatchFolderService: TorrentWatchFolderService
    @ObservationIgnored private let directPauseOperation: DirectPauseOperation
    @ObservationIgnored private let mediaCleanupOperation: MediaCleanupOperation
    @ObservationIgnored private let mediaPauseOperation: MediaPauseOperation
    @ObservationIgnored private let torrentPauseOperation: TorrentPauseOperation
    @ObservationIgnored private let torrentStartOperation: TorrentStartOperation
    @ObservationIgnored private let torrentRemoveOperation: TorrentRemoveOperation
    @ObservationIgnored private let torrentShutdownOperation: TorrentShutdownOperation
    @ObservationIgnored private let browserQuiescenceOperation: BrowserQuiescenceOperation
    @ObservationIgnored private let urlSessionCleanupOperation: URLSessionCleanupOperation
    @ObservationIgnored private let recordSaveOperation: RecordSaveOperation
    @ObservationIgnored private let completedHandoffStore: CompletedDownloadHandoffStore
    @ObservationIgnored private let pendingDataRemovalStore: PendingDownloadDataRemovalStore
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
    @ObservationIgnored private var pendingMediaRecoveryResets: Set<UUID> = []
    @ObservationIgnored private var torrentStartTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var torrentPauseTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var torrentStopSeedingTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingTorrentPauseIDs: Set<UUID> = []
    @ObservationIgnored private var pendingTorrentSeedingRestartIDs: Set<UUID> = []
    @ObservationIgnored private var orphanedTorrentCleanupTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingRemovalReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var directRetryTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var directRetryAttempts: [UUID: Int] = [:]
    @ObservationIgnored private var readyDirectRetries: [UUID: Bool] = [:]
    @ObservationIgnored private var directPauseTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var directAttemptStates: [UUID: AttemptState] = [:]
    @ObservationIgnored private var pendingDirectPauseFailures: [UUID: PendingDirectPauseFailure] = [:]
    @ObservationIgnored private var completedDirectPauseResults: [UUID: CompletedDirectPauseResult] = [:]
    @ObservationIgnored private var browserCancellationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingBrowserWriterMutations: [UUID: PendingBrowserWriterMutation] = [:]
    @ObservationIgnored private var browserReservedIDs: Set<UUID> = []
    @ObservationIgnored private var pendingBrowserContinuationIDs: Set<UUID> = []
    @ObservationIgnored private var mediaPauseTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingMediaResumeIDs: Set<UUID> = []
    @ObservationIgnored private var mediaCleanupTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingMediaCleanupIDs: Set<UUID> = []
    @ObservationIgnored private var pendingMediaRetryAfterCleanupIDs: Set<UUID> = []
    @ObservationIgnored private var pendingMediaStartAfterCleanupIDs: Set<UUID> = []
    @ObservationIgnored private var completionTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var completionLookupTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cancellationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var removalTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingRetryAfterCancellationIDs: Set<UUID> = []
    @ObservationIgnored private var activeMediaAttemptIdentifiers: [UUID: UUID] = [:]
    @ObservationIgnored private var pendingExternalAddSheetDrafts: [AddDownloadSheetDraft] = []
    @ObservationIgnored private var isDrainingDownloadQueue = false
    @ObservationIgnored private var persistenceRevision: UInt64 = 0
    @ObservationIgnored private let persistenceWriterIdentifier = UUID()
    @ObservationIgnored private var persistenceGateOwner: UUID?
    @ObservationIgnored private var persistenceGateWaiters: [PersistenceGateWaiter] = []
#if DEBUG
    @ObservationIgnored private var persistenceGateGrantHookForTesting: (() -> Void)?
#endif

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
    var sortMode: DownloadSortMode = .newest
    var addSheetDraft: AddDownloadSheetDraft?
    var activeBrowserSession: BrowserDownloadSession?
    var activeAlert: UserAlert?

    init(
        settings: AppSettingsStore,
        persistence: DownloadPersistence = DownloadPersistence(),
        directRecoveryDirectoryURL: URL? = nil,
        completedHandoffDirectoryURL: URL? = nil,
        browserRecoveryDirectoryURL: URL? = nil,
        pendingDataRemovalDirectoryURL: URL? = nil,
        destinationResolver: DownloadDestinationResolver = DownloadDestinationResolver(),
        notificationService: DownloadNotificationService = DownloadNotificationService(),
        dataRemovalService: DownloadDataRemovalService = DownloadDataRemovalService(),
        managedTorrentSourceStore: ManagedTorrentSourceStore = ManagedTorrentSourceStore(),
        torrentWatchFolderService: TorrentWatchFolderService? = nil,
        torrentService: Aria2TorrentService? = nil,
        mediaService: MediaDownloadService? = nil,
        directPauseOperation: @escaping DirectPauseOperation = { coordinator, id in
            await coordinator.pauseDownloadAndWait(id: id)
        },
        mediaCleanupOperation: @escaping MediaCleanupOperation = { service, id in
            try await service.cancelAndDiscardRecoveryData(id: id)
        },
        mediaPauseOperation: @escaping MediaPauseOperation = { service, id in
            await service.pauseAndWait(id: id)
        },
        torrentPauseOperation: @escaping TorrentPauseOperation = { service, gid in
            try await service.pause(gid: gid)
        },
        torrentStartOperation: @escaping TorrentStartOperation = {
            service, ownerDownloadID, sourceKind, sourceURL, destinationFolderPath, transferOptions in
            try await service.addDownload(
                ownerDownloadID: ownerDownloadID,
                sourceKind: sourceKind,
                sourceURL: sourceURL,
                destinationFolderPath: destinationFolderPath,
                transferOptions: transferOptions
            )
        },
        torrentRemoveOperation: @escaping TorrentRemoveOperation = { service, gid in
            try await service.removeAndConfirmStopped(gid: gid)
        },
        torrentShutdownOperation: @escaping TorrentShutdownOperation = { service in
            try await service.shutdown()
        },
        browserQuiescenceOperation: @escaping BrowserQuiescenceOperation = { coordinator, id in
            await coordinator.quiesceDownload(id: id, cancelling: true)
        },
        urlSessionCleanupOperation: @escaping URLSessionCleanupOperation = { coordinator, browserCoordinator, id in
            try browserCoordinator.discardRecoveryDataOrThrow(id: id)
            try coordinator.discardRecoveryDataOrThrow(id: id)
        },
        recordSaveOperation: @escaping RecordSaveOperation = { persistence, records, revision in
            try persistence.save(records, revision: revision)
        }
    ) {
        let completedHandoffStore = CompletedDownloadHandoffStore(
            directoryURL: completedHandoffDirectoryURL
        )
        let pendingDataRemovalStore = PendingDownloadDataRemovalStore(
            directoryURL: pendingDataRemovalDirectoryURL
        )
        self.settings = settings
        self.persistence = persistence
        self.destinationResolver = destinationResolver
        self.notificationService = notificationService
        self.dataRemovalService = dataRemovalService
        self.managedTorrentSourceStore = managedTorrentSourceStore
        self.torrentWatchFolderService = torrentWatchFolderService ?? TorrentWatchFolderService()
        self.torrentService = torrentService ?? Aria2TorrentService(transferSettings: settings.transferSettings)
        self.directPauseOperation = directPauseOperation
        self.mediaCleanupOperation = mediaCleanupOperation
        self.mediaPauseOperation = mediaPauseOperation
        self.torrentPauseOperation = torrentPauseOperation
        self.torrentStartOperation = torrentStartOperation
        self.torrentRemoveOperation = torrentRemoveOperation
        self.torrentShutdownOperation = torrentShutdownOperation
        self.browserQuiescenceOperation = browserQuiescenceOperation
        self.urlSessionCleanupOperation = urlSessionCleanupOperation
        self.recordSaveOperation = recordSaveOperation
        self.completedHandoffStore = completedHandoffStore
        self.pendingDataRemovalStore = pendingDataRemovalStore
        self.mediaService = mediaService ?? MediaDownloadService { [weak self] attemptIdentifier, event in
            Task { @MainActor [weak self] in
                self?.handle(event, attemptIdentifier: attemptIdentifier)
            }
        }
        self.coordinator = DownloadCoordinator(
            transferSettings: settings.transferSettings,
            eventHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handle(event)
                }
            },
            recoveryDirectoryURL: directRecoveryDirectoryURL,
            completedHandoffStore: completedHandoffStore
        )
        self.browserCoordinator = BrowserDownloadCoordinator(
            temporaryDirectory: browserRecoveryDirectoryURL,
            completedHandoffStore: completedHandoffStore
        ) { [weak self] event in
            self?.handleBrowserDownloadEvent(event)
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
    }

    deinit {
        persistTask?.cancel()
        torrentRefreshTask?.cancel()
        directRetryTasks.values.forEach { $0.cancel() }
        orphanedTorrentCleanupTasks.values.forEach { $0.cancel() }
        pendingRemovalReconciliationTask?.cancel()
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
            try await mediaService.terminateOrphanedMediaProcesses()
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

                    if record.status == .queued
                        || record.status == .preparing
                        || record.status == .waitingToRetry
                        || record.status == .downloading {
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
            try await reconcilePendingDataRemovals()
            try await reconcileCompletedMediaDownloads()
            let browserCompletionRecoveryFailures: [UUID: String]
            do {
                browserCompletionRecoveryFailures = try await browserCoordinator
                    .recoverCompletedTemporaryFiles()
            } catch {
                browserCompletionRecoveryFailures = [:]
                let message = completedHandoffUnavailableMessage(
                    error.localizedDescription
                )
                for item in downloads
                where item.backend == .urlSession && item.status.isTerminal == false {
                    item.taskIdentifier = nil
                    item.speedBytesPerSecond = 0
                    item.uploadBytesPerSecond = 0
                    item.lastError = message
                    setStatus(for: item, to: .failed)
                    item.updatedAt = .now
                }
            }
            for (id, message) in browserCompletionRecoveryFailures {
                guard let item = item(for: id),
                      item.backend == .urlSession,
                      item.status.isTerminal == false else {
                    continue
                }
                item.taskIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.lastError = completedHandoffUnavailableMessage(message)
                setStatus(for: item, to: .failed)
                item.updatedAt = .now
            }
            try await reconcileCompletedHandoffs()
            let directDownloadIDs = Set(
                downloads
                    .filter {
                        $0.backend == .urlSession
                            && $0.status != .completed
                            && $0.status != .cancelled
                    }
                    .map(\.id)
            )
            coordinator.discardOrphanedRecoveryData(retaining: directDownloadIDs)
            for item in downloads
            where item.backend == .urlSession && item.status.isTerminal == false {
                if item.browserResumeData != nil {
                    coordinator.discardOwnedRecoveryData(id: item.id)
                    continue
                }

                switch coordinator.recoveryLookup(
                    id: item.id,
                    sourceURL: item.sourceURL
                ) {
                case let .available(recovery):
                    item.resumeData = nil
                    item.bytesWritten = recovery.bytesWritten
                    item.expectedBytes = recovery.metadata.expectedBytes
                    item.progress = item.expectedBytes > 0
                        ? min(Double(item.bytesWritten) / Double(item.expectedBytes), 1)
                        : 0
                case .absent:
                    if let resumeData = item.resumeData {
                        item.bytesWritten = DownloadCoordinator.legacyResumeByteCount(
                            from: resumeData
                        ) ?? 0
                        item.expectedBytes = max(item.expectedBytes, item.bytesWritten)
                        item.progress = item.expectedBytes > 0
                            ? min(Double(item.bytesWritten) / Double(item.expectedBytes), 1)
                            : 0
                    } else {
                        item.bytesWritten = 0
                        item.expectedBytes = 0
                        item.progress = 0
                    }
                case let .unavailable(message):
                    item.taskIdentifier = nil
                    item.speedBytesPerSecond = 0
                    item.uploadBytesPerSecond = 0
                    item.lastError = directRecoveryUnavailableMessage(message)
                    setStatus(for: item, to: .failed)
                    item.updatedAt = .now
                }
            }
            for item in downloads
            where item.backend == .ytDlp && item.status.isTerminal == false {
                if let recoveredBytes = await mediaService.recoverableByteCount(id: item.id) {
                    item.bytesWritten = recoveredBytes
                    item.expectedBytes = max(item.expectedBytes, recoveredBytes)
                    if item.expectedBytes > 0 {
                        item.progress = min(
                            Double(recoveredBytes) / Double(item.expectedBytes),
                            1
                        )
                    } else {
                        item.progress = 0
                    }
                } else {
                    item.bytesWritten = 0
                    item.progress = 0
                }
            }
            for item in downloads
            where item.backend == .ytDlp && item.requiresMediaRecoveryReset {
                do {
                    try await mediaCleanupOperation(mediaService, item.id)
                    await performSerializedDurableMutation { [weak self, weak item] in
                        guard let self,
                              let item,
                              self.item(for: item.id) === item,
                              item.requiresMediaRecoveryReset else {
                            return
                        }
                        item.requiresMediaRecoveryReset = false
                        item.backendIdentifier = nil
                        item.bytesWritten = 0
                        item.expectedBytes = 0
                        item.progress = 0
                        item.updatedAt = .now
                        do {
                            // The cleared barrier must reach disk before this
                            // item can become startable. Mutation, save, and
                            // rollback share the persistence gate so another
                            // user action cannot capture the transient clear.
                            try await self.saveRecordsNow()
                        } catch {
                            item.requiresMediaRecoveryReset = true
                            self.pendingMediaCleanupIDs.insert(item.id)
                            item.lastError = error.localizedDescription
                            item.updatedAt = .now
                            if item.status.isTerminal == false {
                                self.setStatus(for: item, to: .failed)
                            }
                        }
                    }
                } catch {
                    // Keep the durable barrier set. A retry must never pass
                    // stale yt-dlp fragments to --continue merely because the
                    // process that first requested cleanup no longer exists.
                    pendingMediaCleanupIDs.insert(item.id)
                    item.backendIdentifier = nil
                    item.lastError = error.localizedDescription
                    item.updatedAt = .now
                    if item.status.isTerminal == false {
                        setStatus(for: item, to: .failed)
                    }
                }
            }
            coordinator.discardOrphanedTemporaryFiles()
            let retainedCompletionIDs = Set(downloads.map(\.id))
            browserCoordinator.discardOrphanedTemporaryFiles(
                retaining: retainedCompletionIDs
            )
            let completedHandoffStore = completedHandoffStore
            await Task.detached(priority: .utility) {
                completedHandoffStore.discardOrphans(
                    retaining: retainedCompletionIDs
                )
            }.value
            try await mediaService.discardOrphanedRecoveryData(
                retaining: Self.retainedMediaRecoveryIDs(in: downloads)
            )
            try await saveRecordsNow()
            selectDownload(downloads.first?.id)
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

    private func reconcileCompletedHandoffs() async throws {
        let completedHandoffStore = completedHandoffStore
        let entries = try await Task.detached(priority: .utility) {
            try completedHandoffStore.entries()
        }.value
        var validHandoffsByID: [UUID: [CompletedDownloadHandoff]] = [:]
        var invalidPackages: [(url: URL, id: UUID?)] = []
        var unavailablePackages: [(url: URL, id: UUID?, errorDescription: String)] = []

        for entry in entries {
            switch entry {
            case let .valid(handoff):
                validHandoffsByID[handoff.manifest.downloadID, default: []].append(handoff)
            case let .invalid(packageURL, downloadID):
                invalidPackages.append((packageURL, downloadID))
            case let .unavailable(packageURL, downloadID, errorDescription):
                unavailablePackages.append((packageURL, downloadID, errorDescription))
            }
        }

        for invalidPackage in invalidPackages {
            if let id = invalidPackage.id,
               validHandoffsByID[id]?.isEmpty == false {
                // A valid package is authoritative for this download. An
                // incomplete or corrupt sibling must never downgrade the item
                // before the valid completion has a chance to reconcile.
                completedHandoffStore.discardPackage(at: invalidPackage.url)
                continue
            }

            guard let id = invalidPackage.id,
                  let item = item(for: id),
                  item.backend == .urlSession,
                  item.status.isTerminal == false else {
                completedHandoffStore.discardPackage(at: invalidPackage.url)
                continue
            }

            let originalRecord = item.makeRecord()
            item.fileLocationPath = nil
            item.progress = 0
            item.bytesWritten = 0
            item.expectedBytes = 0
            item.finishedAt = nil
            item.completionNotificationDelivered = false
            item.lastError = CompletedDownloadHandoffError.invalidManifest.localizedDescription
            setStatus(for: item, to: .failed)
            item.updatedAt = .now

            do {
                try await saveRecordsNow()
                completedHandoffStore.discardPackage(at: invalidPackage.url)
            } catch {
                replaceItem(id: id, with: originalRecord, reporting: error)
                item.taskIdentifier = nil
                item.backendIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
                setStatus(for: item, to: .failed)
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Reconcile a Completed Download"),
                    message: error.localizedDescription
                )
                schedulePersist()
            }
        }

        for unavailablePackage in unavailablePackages {
            guard let id = unavailablePackage.id,
                  validHandoffsByID[id]?.isEmpty != false,
                  let item = item(for: id),
                  item.backend == .urlSession,
                  item.status.isTerminal == false else {
                // A valid sibling remains authoritative. Otherwise terminal or
                // orphan cleanup can retry removing the inaccessible package;
                // never classify an I/O failure as payload corruption.
                continue
            }

            let originalRecord = item.makeRecord()
            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.finishedAt = nil
            item.completionNotificationDelivered = false
            item.lastError = String(
                localized: "download.completedHandoff.unavailable",
                defaultValue: "Harbor could not verify the completed download: \(unavailablePackage.errorDescription)",
                comment: "Failure shown when a durable completed download package is temporarily inaccessible."
            )
            setStatus(for: item, to: .failed)
            item.updatedAt = .now

            do {
                try await saveRecordsNow()
            } catch {
                replaceItem(id: id, with: originalRecord, reporting: error)
                item.taskIdentifier = nil
                item.backendIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
                setStatus(for: item, to: .failed)
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Reconcile a Completed Download"),
                    message: error.localizedDescription
                )
                schedulePersist()
            }
        }

        for (id, candidates) in validHandoffsByID {
            guard let item = item(for: id),
                  item.backend == .urlSession,
                  item.status != .cancelled else {
                for candidate in candidates {
                    completedHandoffStore.discardPackage(at: candidate.packageURL)
                }
                continue
            }

            let matchingCandidates = candidates.filter {
                $0.manifest.sourceURL == item.sourceURL
            }
            for staleCandidate in candidates where staleCandidate.manifest.sourceURL != item.sourceURL {
                completedHandoffStore.discardPackage(at: staleCandidate.packageURL)
            }
            let orderedCandidates = matchingCandidates.sorted {
                $0.manifest.createdAt > $1.manifest.createdAt
            }
            guard let selected = orderedCandidates.first else {
                continue
            }

            let didFinalize = await finalizeCompletedHandoff(
                selected,
                for: item,
                reportPersistenceFailure: true
            )
            if didFinalize {
                for superseded in orderedCandidates.dropFirst() {
                    completedHandoffStore.discardPackage(at: superseded.packageURL)
                }
            }
        }
    }

    private func reconcileCompletedMediaDownloads() async throws {
        let entries = try await mediaService.completedDownloadEntries()
        for entry in entries {
            switch entry {
            case let .valid(manifest):
                guard let item = item(for: manifest.downloadID),
                      mediaCompletion(manifest, belongsTo: item),
                      item.status != .cancelled else {
                    await acknowledgeStaleMediaCompletion(manifest)
                    continue
                }
                _ = await commitMediaCompletion(manifest, to: item)

            case let .invalid(downloadID, message):
                guard let item = item(for: downloadID),
                      item.backend == .ytDlp,
                      item.status != .cancelled,
                      item.status != .completed else {
                    await discardInvalidMediaCompletionMarker(id: downloadID)
                    continue
                }
                let didPersistFailure = await persistMediaCompletionFailure(
                    message,
                    for: item
                )
                if didPersistFailure {
                    await discardInvalidMediaCompletionMarker(id: downloadID)
                }

            case let .unavailable(downloadID, message):
                guard let item = item(for: downloadID),
                      item.backend == .ytDlp,
                      item.status != .cancelled,
                      item.status != .completed else {
                    continue
                }
                _ = await persistMediaCompletionFailure(
                    String(
                    localized: "download.media.completionUnavailable",
                    defaultValue: "Harbor could not verify the completed media: \(message)",
                    comment: "Failure shown when a durable media-completion journal is temporarily inaccessible."
                    ),
                    for: item
                )
            }
        }
    }

    private func mediaCompletion(
        _ manifest: MediaCompletionManifest,
        belongsTo item: DownloadItem
    ) -> Bool {
        item.id == manifest.downloadID
            && item.backend == .ytDlp
            && item.sourceURL == manifest.sourceURL
            && item.destinationFolderURL.standardizedFileURL.path
                == URL(fileURLWithPath: manifest.destinationFolderPath)
                    .standardizedFileURL.path
    }

    @discardableResult
    private func commitMediaCompletion(
        _ manifest: MediaCompletionManifest,
        to item: DownloadItem
    ) async -> Bool {
        guard mediaCompletion(manifest, belongsTo: item),
              item.status != .cancelled else {
            return false
        }

        let shouldNotify = item.status != .completed
            && item.completionNotificationDelivered == false
        var didPersistCompletion = false
        var persistenceFailure: Error?
        await performSerializedDurableMutation { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item(for: item.id) === item,
                  self.mediaCompletion(manifest, belongsTo: item),
                  item.status != .cancelled else {
                return
            }
            let recordBeforeCompletion = item.makeRecord()
            self.applyMediaCompletion(manifest, to: item)
            do {
                try await self.saveRecordsNow()
                didPersistCompletion = true
            } catch {
                persistenceFailure = error
                self.replaceItem(
                    id: item.id,
                    with: recordBeforeCompletion,
                    reporting: error
                )
                if recordBeforeCompletion.status != .completed {
                    item.backendIdentifier = nil
                    item.speedBytesPerSecond = 0
                    item.uploadBytesPerSecond = 0
                    item.updatedAt = .now
                    self.setStatus(for: item, to: .failed)
                }
            }
        }

        guard didPersistCompletion else {
            if let persistenceFailure {
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Completed Download"),
                    message: persistenceFailure.localizedDescription
                )
                schedulePersist()
            }
            return false
        }

        do {
            try await mediaService.acknowledgeCompletion(
                id: manifest.downloadID,
                attemptIdentifier: manifest.attemptIdentifier
            )
        } catch {
            // The durable record now owns the completion. Retain the journal
            // as an idempotent cleanup retry rather than rolling the record
            // back or suppressing the user notification.
            activeAlert = UserAlert(
                title: String(localized: "Completed Download Cleanup Pending"),
                message: error.localizedDescription
            )
        }
        if shouldNotify {
            deliverNotificationIfEnabled(for: item, status: .completed)
        }
        return true
    }

    @discardableResult
    private func persistMediaCompletionFailure(
        _ message: String,
        for item: DownloadItem
    ) async -> Bool {
        var didPersistFailure = false
        var persistenceFailure: Error?
        await performSerializedDurableMutation { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item(for: item.id) === item,
                  item.backend == .ytDlp,
                  item.status != .cancelled,
                  item.status != .completed else {
                return
            }
            let originalRecord = item.makeRecord()
            item.backendIdentifier = nil
            item.lastError = message
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            self.setStatus(for: item, to: .failed)
            do {
                try await self.saveRecordsNow()
                didPersistFailure = true
            } catch {
                persistenceFailure = error
                self.replaceItem(id: item.id, with: originalRecord, reporting: error)
                // The durable record still describes the pre-terminal state,
                // but this process/lookup is already gone. Leaving that state
                // as preparing or downloading in memory would reserve a slot
                // forever with no task capable of producing another event.
                item.backendIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
                self.setStatus(for: item, to: .failed)
            }
        }
        if let persistenceFailure {
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Save Media Recovery State"),
                message: persistenceFailure.localizedDescription
            )
            schedulePersist()
        }
        return didPersistFailure
    }

    private func acknowledgeStaleMediaCompletion(
        _ manifest: MediaCompletionManifest
    ) async {
        do {
            try await mediaService.acknowledgeCompletion(
                id: manifest.downloadID,
                attemptIdentifier: manifest.attemptIdentifier
            )
        } catch {
            activeAlert = UserAlert(
                title: String(localized: "Completed Download Cleanup Pending"),
                message: error.localizedDescription
            )
        }
    }

    private func discardInvalidMediaCompletionMarker(id: UUID) async {
        do {
            try await mediaService.discardCompletionMarker(id: id)
        } catch {
            activeAlert = UserAlert(
                title: String(localized: "Completed Download Cleanup Pending"),
                message: error.localizedDescription
            )
        }
    }

    private func reconcilePendingDataRemovals() async throws {
        let pendingDataRemovalStore = pendingDataRemovalStore
        let manifests = try await Task.detached(priority: .utility) {
            try pendingDataRemovalStore.entries()
        }.value

        for originalManifest in manifests.sorted(by: { $0.createdAt < $1.createdAt }) {
            var manifest = originalManifest
            let record = manifest.record

            if manifest.phase == .payloadPending {
                manifest = try pendingDataRemovalStore.markPayloadDeletionStarted(
                    downloadID: record.id
                )
                let result = dataRemovalService.movePayloadDataToTrash(
                    destinationFolderPath: record.destinationFolderPath,
                    payloadPaths: Self.payloadPaths(for: record)
                )
                if result.failures.isEmpty == false {
                    let trackedItem = trackedItemRestoringIfNeeded(from: record)
                    applyPartialDataRemovalResult(result, to: trackedItem)
                    try await saveRecordsNow()
                    pendingDataRemovalStore.acknowledge(downloadID: record.id)
                    continue
                }
                manifest = try pendingDataRemovalStore.markBackendCleanup(
                    downloadID: record.id
                )
            } else if manifest.phase == .payloadDeletionStarted {
                let inspection = dataRemovalService.inspectPayloadData(
                    destinationFolderPath: record.destinationFolderPath,
                    payloadPaths: Self.payloadPaths(for: record)
                )
                if inspection.existingPaths.isEmpty == false
                    || inspection.failures.isEmpty == false {
                    // A crash may have happened immediately before or after a
                    // Trash operation. An extant pathname can now name a
                    // replacement file, so preserve it and restore the record
                    // instead of replaying a destructive path-only intent.
                    let trackedItem = trackedItemRestoringIfNeeded(from: record)
                    applyInterruptedDataRemovalInspection(inspection, to: trackedItem)
                    try await saveRecordsNow()
                    try pendingDataRemovalStore.acknowledgeOrThrow(downloadID: record.id)
                    activeAlert = UserAlert(
                        title: String(localized: "Download Data Was Left in Place"),
                        message: trackedItem.lastError ?? ""
                    )
                    continue
                }
                manifest = try pendingDataRemovalStore.markBackendCleanup(
                    downloadID: record.id
                )
            }

            guard manifest.phase == .backendCleanup else {
                throw CocoaError(.fileReadCorruptFile)
            }
            downloads.removeAll { $0.id == record.id }
            try await saveRecordsNow()

            let cleanupItem = DownloadItem(record: record)
            do {
                try await discardBackendRecovery(
                    for: cleanupItem,
                    backendIdentifier: record.backendIdentifier
                )
                moveOriginalTorrentFileToTrashIfNeeded(for: cleanupItem)
                removeManagedTorrentSourceIfNeeded(for: cleanupItem)
                pendingDataRemovalStore.acknowledge(downloadID: record.id)
            } catch {
                // This phase contains no payload mutation. Retaining it is
                // safe even if a different file later appears at the old path.
                activeAlert = UserAlert(
                    title: String(localized: "Download Removed; Backend Cleanup Pending"),
                    message: error.localizedDescription
                )
                schedulePendingRemovalReconciliation()
            }
        }
    }

    private func trackedItemRestoringIfNeeded(
        from record: DownloadRecord
    ) -> DownloadItem {
        if let existing = item(for: record.id) {
            return existing
        }
        let restored = DownloadItem(record: record)
        downloads.append(restored)
        return restored
    }

    private func schedulePendingRemovalReconciliation() {
        guard pendingRemovalReconciliationTask == nil,
              isShuttingDown == false else {
            return
        }
        pendingRemovalReconciliationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer { self.pendingRemovalReconciliationTask = nil }
            for delay in [Duration.seconds(2), .seconds(10), .seconds(30)] {
                do {
                    try await Task.sleep(for: delay)
                    guard self.isShuttingDown == false else {
                        return
                    }
                    try await self.reconcilePendingDataRemovals()
                    let entries = try self.pendingDataRemovalStore.entries()
                    if entries.isEmpty {
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.activeAlert = UserAlert(
                        title: String(localized: "Download Cleanup Still Pending"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private nonisolated static func payloadPaths(for record: DownloadRecord) -> [String] {
        if record.torrentPayloadPaths.isEmpty == false {
            return record.torrentPayloadPaths
        }
        return record.fileLocationPath.map { [$0] } ?? []
    }

    private func applyPartialDataRemovalResult(
        _ result: DownloadDataRemovalResult,
        to item: DownloadItem
    ) {
        item.torrentPayloadPaths = result.remainingPayloadPaths
        item.fileLocationPath = result.remainingPayloadPaths.first
        item.taskIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.shouldSeedAfterDownload = false
        item.status = item.finishedAt == nil ? .cancelled : .completed
        item.lastError = result.failures
            .map { "\($0.path): \($0.message)" }
            .joined(separator: "\n")
        item.updatedAt = .now
    }

    private func applyInterruptedDataRemovalInspection(
        _ inspection: DownloadPayloadInspection,
        to item: DownloadItem
    ) {
        let retainedPaths = Array(
            Set(inspection.existingPaths + inspection.failures.map(\.path))
        ).sorted()
        item.torrentPayloadPaths = retainedPaths
        if let currentPath = item.fileLocationPath,
           retainedPaths.contains(currentPath) {
            item.fileLocationPath = currentPath
        } else {
            item.fileLocationPath = retainedPaths.first
        }
        item.taskIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.shouldSeedAfterDownload = false
        item.status = item.finishedAt == nil ? .cancelled : .completed
        item.lastError = String(
            localized: "download.removeData.interrupted",
            defaultValue: "Harbor could not prove that the files remaining at the original paths still belong to this download after an interrupted removal, so it left them in place. Already removed paths were retired from this record.",
            comment: "Safety message shown when an interrupted removal could otherwise delete replacement files."
        )
        if inspection.failures.isEmpty == false {
            item.lastError = ([item.lastError] + inspection.failures.map {
                "\($0.path): \($0.message)"
            })
            .compactMap { $0 }
            .joined(separator: "\n")
        }
        item.updatedAt = .now
    }

    private func applyMediaCompletion(
        _ manifest: MediaCompletionManifest,
        to item: DownloadItem
    ) {
        item.fileLocationPath = manifest.fileLocationPath
        item.torrentPayloadPaths = manifest.payloads.map(\.path)
        item.preferredFilename = URL(fileURLWithPath: manifest.fileLocationPath)
            .lastPathComponent
        item.progress = 1
        item.expectedBytes = manifest.actualBytes
        item.bytesWritten = manifest.actualBytes
        item.finishedAt = item.finishedAt ?? .now
        item.lastError = nil
        item.backendIdentifier = nil
        item.requiresMediaRecoveryReset = false
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now
        item.completionNotificationDelivered = true
        setStatus(for: item, to: .completed)
    }

    @discardableResult
    private func finalizeCompletedHandoff(
        _ initialHandoff: CompletedDownloadHandoff,
        for item: DownloadItem,
        reportPersistenceFailure: Bool
    ) async -> Bool {
        guard item.id == initialHandoff.manifest.downloadID,
              item.backend == .urlSession,
              item.sourceURL == initialHandoff.manifest.sourceURL,
              downloads.contains(where: { $0 === item }) else {
            completedHandoffStore.discardPackage(at: initialHandoff.packageURL)
            return false
        }

        do {
            let payloadURL = try requireHandoffPayload(initialHandoff)
            try validateDownloadedPayload(
                for: item,
                temporaryURL: payloadURL,
                suggestedFilename: initialHandoff.manifest.suggestedFilename,
                responseMimeType: initialHandoff.manifest.mimeType,
                statusCode: initialHandoff.manifest.statusCode
            )
            let destinationURL = try await placeCompletedHandoff(initialHandoff, for: item)
            let shouldNotify = item.status != .completed
                && item.completionNotificationDelivered == false
            var didPersistCompletion = false
            var persistenceFailure: Error?
            await performSerializedDurableMutation { [weak self, weak item] in
                guard let self,
                      let item,
                      self.item(for: item.id) === item else {
                    return
                }
                let recordBeforeCompletion = item.makeRecord()
                item.fileLocationPath = destinationURL.path
                item.preferredFilename = destinationURL.lastPathComponent
                item.progress = 1
                item.expectedBytes = initialHandoff.manifest.actualBytes
                item.bytesWritten = initialHandoff.manifest.actualBytes
                item.finishedAt = item.finishedAt ?? .now
                item.lastError = nil
                item.resumeData = nil
                item.browserResumeData = nil
                item.taskIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
                item.completionNotificationDelivered = true
                self.setStatus(for: item, to: .completed)

                do {
                    try await self.saveRecordsNow()
                    didPersistCompletion = true
                } catch {
                    persistenceFailure = error
                    self.replaceItem(
                        id: item.id,
                        with: recordBeforeCompletion,
                        reporting: error
                    )
                    if recordBeforeCompletion.status != .completed {
                        item.taskIdentifier = nil
                        item.backendIdentifier = nil
                        item.speedBytesPerSecond = 0
                        item.uploadBytesPerSecond = 0
                        item.updatedAt = .now
                        self.setStatus(for: item, to: .failed)
                    }
                }
            }
            guard didPersistCompletion else {
                if let persistenceFailure {
                    if reportPersistenceFailure {
                        activeAlert = UserAlert(
                            title: String(localized: "Couldn’t Save Completed Download"),
                            message: persistenceFailure.localizedDescription
                        )
                    }
                    schedulePersist()
                }
                return false
            }

            completedHandoffStore.acknowledge(initialHandoff)
            // The durable completed record and validated destination now own
            // the result. Remove any older ready/staging packages for this
            // download so a superseded attempt cannot be reconciled later.
            completedHandoffStore.discard(downloadID: item.id)
            coordinator.discardOwnedRecoveryData(id: item.id)
            browserCoordinator.discardPartialRecoveryData(id: item.id)
            if shouldNotify {
                deliverNotificationIfEnabled(for: item, status: .completed)
            }
            return true
        } catch let validationError as DirectDownloadValidationError {
            var didPersistRejection = false
            var persistenceFailure: Error?
            await performSerializedDurableMutation { [weak self, weak item] in
                guard let self,
                      let item,
                      self.item(for: item.id) === item else {
                    return
                }
                let recordBeforeRejection = item.makeRecord()
                switch validationError {
                case let .browserSessionRequired(message):
                    self.markBrowserSessionRequired(item, message: message)
                case .invalidResponse:
                    item.progress = 0
                    item.bytesWritten = 0
                    item.expectedBytes = 0
                    item.finishedAt = nil
                    item.lastError = validationError.localizedDescription
                    self.setStatus(for: item, to: .failed)
                }
                item.completionNotificationDelivered = false
                do {
                    try await self.saveRecordsNow()
                    didPersistRejection = true
                } catch {
                    persistenceFailure = error
                    self.replaceItem(
                        id: item.id,
                        with: recordBeforeRejection,
                        reporting: error
                    )
                    if recordBeforeRejection.status != .completed {
                        item.taskIdentifier = nil
                        item.backendIdentifier = nil
                        item.speedBytesPerSecond = 0
                        item.uploadBytesPerSecond = 0
                        item.updatedAt = .now
                        self.setStatus(for: item, to: .failed)
                    }
                }
            }
            // The handoff contains a response that Harbor has already
            // rejected (for example an HTML sign-in page), not resumable
            // payload data. Do not leave that stale package available to
            // supersede a later browser/direct retry merely because the
            // record write failed.
            completedHandoffStore.discardPackage(at: initialHandoff.packageURL)
            if didPersistRejection == false, let persistenceFailure {
                if reportPersistenceFailure {
                    activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Save Download State"),
                        message: persistenceFailure.localizedDescription
                    )
                }
                schedulePersist()
            }
            return false
        } catch {
            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.lastError = error.localizedDescription
            item.updatedAt = .now
            setStatus(for: item, to: .failed)
            schedulePersist()
            if reportPersistenceFailure {
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Finalize Download"),
                    message: error.localizedDescription
                )
            }
            return false
        }
    }

    private func requireHandoffPayload(_ handoff: CompletedDownloadHandoff) throws -> URL {
        guard let payloadURL = handoff.availablePayloadURL else {
            throw CompletedDownloadHandoffError.destinationUnavailable
        }
        return payloadURL
    }

    private func placeCompletedHandoff(
        _ initialHandoff: CompletedDownloadHandoff,
        for item: DownloadItem
    ) async throws -> URL {
        let completedHandoffStore = completedHandoffStore
        let destinationResolver = destinationResolver
        let preferredFilename = item.preferredFilename
        let sourceURL = item.sourceURL
        let destinationFolderURL = item.destinationFolderURL
        return try await Task.detached(priority: .utility) {
            try Self.placeCompletedHandoffOffMainActor(
                initialHandoff,
                preferredFilename: preferredFilename,
                sourceURL: sourceURL,
                destinationFolderURL: destinationFolderURL,
                completedHandoffStore: completedHandoffStore,
                destinationResolver: destinationResolver
            )
        }.value
    }

    private nonisolated static func placeCompletedHandoffOffMainActor(
        _ initialHandoff: CompletedDownloadHandoff,
        preferredFilename: String?,
        sourceURL: URL,
        destinationFolderURL: URL,
        completedHandoffStore: CompletedDownloadHandoffStore,
        destinationResolver: DownloadDestinationResolver
    ) throws -> URL {
        if let destinationURL = initialHandoff.destinationURL {
            // A visible pathname is not yet a durable placement. Re-run the
            // file and parent-directory barriers before allowing the journal
            // to be acknowledged.
            try destinationResolver.synchronizePlacedFile(at: destinationURL)
            return destinationURL
        }

        guard let payloadURL = initialHandoff.payloadURL else {
            throw CompletedDownloadHandoffError.destinationUnavailable
        }

        var handoff = initialHandoff
        if let stagingURL = handoff.placementStagingURL,
           FileManager.default.fileExists(atPath: stagingURL.path) {
            do {
                try completedHandoffStore.validatePlacementStaging(for: handoff)
                guard let destinationPath = handoff.manifest.destinationPath else {
                    throw CompletedDownloadHandoffError.invalidManifest
                }
                let destinationURL = URL(fileURLWithPath: destinationPath)
                try destinationResolver.moveDownloadedFile(
                    from: stagingURL,
                    to: destinationURL
                )
                guard completedHandoffStore.handoff(
                    downloadID: handoff.manifest.downloadID,
                    attemptIdentifier: handoff.manifest.attemptIdentifier
                ) != nil else {
                    throw CompletedDownloadHandoffError.destinationUnavailable
                }
                try destinationResolver.synchronizePlacedFile(at: destinationURL)
                // Keep the immutable package payload until the completed
                // record is durable. If that save fails, the visible
                // destination may be replaced before reconciliation and must
                // not become the journal's only remaining copy.
                return destinationURL
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                if let reconciled = completedHandoffStore.handoff(
                    downloadID: handoff.manifest.downloadID,
                    attemptIdentifier: handoff.manifest.attemptIdentifier
                ), let destinationURL = reconciled.destinationURL {
                    try destinationResolver.synchronizePlacedFile(at: destinationURL)
                    return destinationURL
                }
                completedHandoffStore.discardPlacementStaging(for: handoff)
            } catch {
                if let reconciled = completedHandoffStore.handoff(
                    downloadID: handoff.manifest.downloadID,
                    attemptIdentifier: handoff.manifest.attemptIdentifier
                ), let destinationURL = reconciled.destinationURL {
                    // A rename may have committed before fsync failed. Retry
                    // that barrier now, but retain the package if it still
                    // fails; visibility alone is not durable completion.
                    try destinationResolver.synchronizePlacedFile(at: destinationURL)
                    return destinationURL
                }
                completedHandoffStore.discardPlacementStaging(for: handoff)
                throw error
            }
        }

        for _ in 0 ..< 10_000 {
            let destinationURL = try destinationResolver.destinationURL(
                customFilename: preferredFilename,
                responseSuggestedFilename: handoff.manifest.suggestedFilename,
                sourceURL: sourceURL,
                in: destinationFolderURL
            )
            handoff = try completedHandoffStore.recordDestination(
                destinationURL,
                for: handoff
            )
            guard let stagingURL = handoff.placementStagingURL else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            do {
                try destinationResolver.copyDownloadedFile(
                    from: payloadURL,
                    to: stagingURL
                )
                try completedHandoffStore.validatePlacementStaging(for: handoff)
                try destinationResolver.moveDownloadedFile(from: stagingURL, to: destinationURL)
                guard completedHandoffStore.handoff(
                    downloadID: handoff.manifest.downloadID,
                    attemptIdentifier: handoff.manifest.attemptIdentifier
                ) != nil else {
                    throw CompletedDownloadHandoffError.destinationUnavailable
                }
                try destinationResolver.synchronizePlacedFile(at: destinationURL)
                return destinationURL
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                if let reconciled = completedHandoffStore.handoff(
                    downloadID: handoff.manifest.downloadID,
                    attemptIdentifier: handoff.manifest.attemptIdentifier
                ), let destinationURL = reconciled.destinationURL {
                    try destinationResolver.synchronizePlacedFile(at: destinationURL)
                    return destinationURL
                }
                if (try? completedHandoffStore.validatePlacementStaging(for: handoff)) != nil {
                    completedHandoffStore.discardPlacementStaging(for: handoff)
                }
                continue
            } catch {
                if let reconciled = completedHandoffStore.handoff(
                    downloadID: handoff.manifest.downloadID,
                    attemptIdentifier: handoff.manifest.attemptIdentifier
                ), let destinationURL = reconciled.destinationURL {
                    try destinationResolver.synchronizePlacedFile(at: destinationURL)
                    return destinationURL
                }
                completedHandoffStore.discardPlacementStaging(for: handoff)
                throw error
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    private func replaceItem(
        id: UUID,
        with record: DownloadRecord,
        reporting error: Error
    ) {
        guard let item = item(for: id), record.id == id else {
            return
        }
        item.restorePersistedState(from: record)
        item.lastError = error.localizedDescription
    }

    private func reconcileRestoredTorrentSession(
        knownEngineGIDs: Set<String>? = nil,
        stopsAfterReservationAdoption: Bool = false
    ) async {
        let reservations: [TorrentSubmissionReservation]
        let pendingRemovalIDs: Set<UUID>
        var engineGIDs: Set<String>
        do {
            reservations = try await torrentService.pendingSubmissionReservations()
            let pendingDataRemovalStore = pendingDataRemovalStore
            pendingRemovalIDs = try await Task.detached(priority: .utility) {
                Set(try pendingDataRemovalStore.entries().map { $0.record.id })
            }.value
        } catch {
            // Reservation enumeration is part of ownership recovery. If it is
            // unreadable, orphan deletion must fail closed: one of those GIDs
            // may belong to a record whose save was interrupted.
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Restore Torrent Ownership"),
                message: error.localizedDescription
            )
            return
        }
        if let knownEngineGIDs {
            engineGIDs = knownEngineGIDs
        } else {
            do {
                engineGIDs = try await torrentService.allKnownGIDs()
            } catch {
                // Preserve the previous best-effort behavior when there is no
                // unresolved reservation ownership. In particular, do not
                // replace a more actionable startup alert from another
                // recovery subsystem merely because aria2 is unavailable.
                if reservations.isEmpty == false {
                    activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Restore Torrent Ownership"),
                        message: error.localizedDescription
                    )
                }
                return
            }
        }

        var didAdoptReservation = false
        var reservationsToAcknowledge: [TorrentSubmissionReservation] = []
        var pendingRemovalReservationGIDs: Set<String> = []
        for reservation in reservations {
            if pendingRemovalIDs.contains(reservation.ownerDownloadID) {
                do {
                    if engineGIDs.contains(reservation.gid) {
                        try await torrentRemoveOperation(torrentService, reservation.gid)
                        engineGIDs.remove(reservation.gid)
                    }
                    try await torrentService.acknowledgeSubmission(
                        ownerDownloadID: reservation.ownerDownloadID,
                        gid: reservation.gid
                    )
                } catch {
                    // A durable removal journal supersedes reconstruction.
                    // Keep the reservation out of normal adoption/orphan
                    // handling and let confirmed cleanup retry it instead.
                    pendingRemovalReservationGIDs.insert(reservation.gid)
                    scheduleOrphanedTorrentCleanup(gid: reservation.gid)
                    activeAlert = UserAlert(
                        title: String(localized: "Download Removed; Backend Cleanup Pending"),
                        message: error.localizedDescription
                    )
                }
                continue
            }

            let sourceKind = reservation.sourceKind
                ?? (reservation.sourceURL.scheme?.lowercased() == "magnet"
                    ? .magnetLink
                    : .torrentFile)
            guard sourceKind == .magnetLink || sourceKind == .torrentFile else {
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Restore Torrent Ownership"),
                    message: "A pending torrent reservation has an invalid source type."
                )
                return
            }

            if let item = item(for: reservation.ownerDownloadID) {
                guard torrentReservation(
                    reservation,
                    matches: item,
                    sourceKind: sourceKind
                ) else {
                    if engineGIDs.contains(reservation.gid) {
                        activeAlert = UserAlert(
                            title: String(localized: "Couldn’t Restore Torrent Ownership"),
                            message: "A live torrent reservation conflicts with its saved download record."
                        )
                        return
                    }
                    reservationsToAcknowledge.append(reservation)
                    continue
                }

                if let persistedGID = item.backendIdentifier,
                   persistedGID != reservation.gid {
                    if engineGIDs.contains(reservation.gid) {
                        activeAlert = UserAlert(
                            title: String(localized: "Couldn’t Restore Torrent Ownership"),
                            message: "Two torrent identifiers claim the same saved download."
                        )
                        return
                    }
                    reservationsToAcknowledge.append(reservation)
                    continue
                }

                let isTerminalCleanup = item.status == .cancelled
                    || (item.status == .completed && item.shouldSeedAfterDownload == false)
                if engineGIDs.contains(reservation.gid) {
                    if item.backendIdentifier == nil {
                        item.backendIdentifier = reservation.gid
                        item.updatedAt = .now
                        didAdoptReservation = true
                    }
                    if isTerminalCleanup == false {
                        reservationsToAcknowledge.append(reservation)
                    }
                } else if isTerminalCleanup {
                    reservationsToAcknowledge.append(reservation)
                }
                continue
            }

            let item = DownloadItem(
                id: reservation.ownerDownloadID,
                createdAt: reservation.createdAt,
                sourceURL: reservation.sourceURL,
                sourceKind: sourceKind,
                backend: .aria2,
                preferredFilename: nil,
                destinationFolderPath: reservation.destinationFolderPath,
                status: settings.startDownloadsAutomatically ? .queued : .paused,
                backendIdentifier: engineGIDs.contains(reservation.gid)
                    ? reservation.gid
                    : nil,
                metadataName: sourceKind == .magnetLink
                    ? MagnetLinkMetadata(url: reservation.sourceURL).displayName
                    : nil,
                managedTorrentSourcePath: sourceKind == .torrentFile
                    && reservation.sourceURL.isFileURL
                    ? reservation.sourceURL.path
                    : nil,
                shouldSeedAfterDownload: reservation.shouldSeedAfterDownload
                    ?? settings.seedNewTorrents
            )
            downloads.append(item)
            didAdoptReservation = true
            if engineGIDs.contains(reservation.gid) {
                reservationsToAcknowledge.append(reservation)
            }
        }

        if didAdoptReservation {
            downloads.sort { $0.createdAt > $1.createdAt }
            do {
                try await saveRecordsNow()
            } catch {
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Torrent Ownership"),
                    message: error.localizedDescription
                )
                return
            }
        }

        for reservation in reservationsToAcknowledge {
            do {
                try await torrentService.acknowledgeSubmission(
                    ownerDownloadID: reservation.ownerDownloadID,
                    gid: reservation.gid
                )
            } catch {
                // Ownership is already durable (or the reservation was proven
                // absent from aria2). Leaving the reservation in place is safe
                // and lets a later launch retry acknowledgement.
                activeAlert = UserAlert(
                    title: String(localized: "Torrent Ownership Cleanup Pending"),
                    message: error.localizedDescription
                )
            }
        }

        if stopsAfterReservationAdoption {
            return
        }

        var didClearTerminalIdentifier = false
        for item in downloads where item.backend == .aria2
            && item.backendIdentifier != nil
            && (item.status == .cancelled
                || (item.status == .completed && item.shouldSeedAfterDownload == false)) {
            guard let gid = item.backendIdentifier else {
                continue
            }
            do {
                try await torrentRemoveOperation(torrentService, gid)
                engineGIDs.remove(gid)
                item.backendIdentifier = nil
                item.lastError = nil
                item.updatedAt = .now
                didClearTerminalIdentifier = true
            } catch {
                item.lastError = error.localizedDescription
                item.updatedAt = .now
            }
        }
        if didClearTerminalIdentifier {
            do {
                try await saveRecordsNow()
            } catch {
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Torrent Cleanup"),
                    message: error.localizedDescription
                )
                return
            }
            for reservation in reservations {
                guard let item = item(for: reservation.ownerDownloadID),
                      item.backendIdentifier == nil,
                      item.status == .cancelled
                        || (item.status == .completed
                            && item.shouldSeedAfterDownload == false) else {
                    continue
                }
                do {
                    try await torrentService.acknowledgeSubmission(
                        ownerDownloadID: reservation.ownerDownloadID,
                        gid: reservation.gid
                    )
                } catch {
                    activeAlert = UserAlert(
                        title: String(localized: "Torrent Ownership Cleanup Pending"),
                        message: error.localizedDescription
                    )
                }
            }
        }

        let persistedTorrentItems = downloads.filter {
            $0.backend == .aria2 && $0.backendIdentifier != nil
        }
        let persistedGIDs = Set(persistedTorrentItems.compactMap(\.backendIdentifier))
        var retainedEngineGIDs = persistedGIDs
        retainedEngineGIDs.formUnion(pendingRemovalReservationGIDs)
        var completedOwnershipExpansion = true

        for item in persistedTorrentItems {
            guard let rootGID = item.backendIdentifier else {
                continue
            }
            do {
                let lineage = try await torrentService.followedStatus(for: rootGID)
                retainedEngineGIDs.formUnion(lineage.gids)
            } catch {
                item.lastError = error.localizedDescription
                completedOwnershipExpansion = false
            }
        }

        if completedOwnershipExpansion {
            for orphanedGID in Self.orphanedTorrentGIDs(
                engineGIDs: engineGIDs,
                retainedGIDs: retainedEngineGIDs
            ) {
                do {
                    try await torrentRemoveOperation(torrentService, orphanedGID)
                } catch {
                    scheduleOrphanedTorrentCleanup(gid: orphanedGID)
                }
            }
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
                  engineGIDs.contains(gid),
                  let lineage = try? await torrentService.followedStatus(for: gid) else {
                continue
            }

            let snapshot = lineage.currentSnapshot
            if Self.shouldPauseRestoredTorrent(
                persistedStatus: item.status,
                engineStatus: snapshot.status
            ) {
                do {
                    try await torrentPauseOperation(torrentService, gid)
                } catch {
                    reflectActiveTorrentAfterPauseFailure(
                        item,
                        snapshot: snapshot,
                        error: error
                    )
                    schedulePersist()
                }
            }
        }
    }

    private func torrentReservation(
        _ reservation: TorrentSubmissionReservation,
        matches item: DownloadItem,
        sourceKind: DownloadSourceKind
    ) -> Bool {
        guard item.backend == .aria2,
              item.sourceKind == sourceKind,
              URL(fileURLWithPath: item.destinationFolderPath).standardizedFileURL.path
                == URL(fileURLWithPath: reservation.destinationFolderPath).standardizedFileURL.path else {
            return false
        }

        let itemSource = torrentEngineSourceURL(for: item)
        if itemSource.isFileURL || reservation.sourceURL.isFileURL {
            return itemSource.standardizedFileURL.path
                == reservation.sourceURL.standardizedFileURL.path
        }
        return itemSource.absoluteString == reservation.sourceURL.absoluteString
    }

    static func retainedMediaRecoveryIDs(in items: [DownloadItem]) -> Set<UUID> {
        Set(
            items.lazy
                .filter {
                    $0.backend == .ytDlp
                        && ($0.requiresMediaRecoveryReset
                            || ($0.status != .completed && $0.status != .cancelled))
                }
                .map(\.id)
        )
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

        switch sortMode {
        case .newest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        case .name:
            return filtered.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .progress:
            return filtered.sorted { lhs, rhs in
                (lhs.progressValue ?? 0) > (rhs.progressValue ?? 0)
            }
        case .speed:
            return filtered.sorted { lhs, rhs in
                lhs.speedBytesPerSecond > rhs.speedBytesPerSecond
            }
        }
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
        guard isShuttingDown == false,
              let item = item(for: id),
              item.backend == .ytDlp,
              item.status == .failed else {
            return
        }

        let previousPreference = item.mediaFormatPreference
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

        if item.mediaFormatPreference != previousPreference {
            item.bytesWritten = 0
            item.expectedBytes = 0
            item.progress = 0
            item.requiresMediaRecoveryReset = true
            pendingMediaRecoveryResets.insert(id)
            scheduleMediaCleanup(id: id)
        }

        item.updatedAt = .now
        schedulePersist()
    }

    func installExternalOpenHandlerIfNeeded() {
        guard hasInstalledExternalOpenHandler == false else {
            return
        }

        hasInstalledExternalOpenHandler = true
        ExternalAddDownloadOpenCoordinator.shared.installHandler { [weak self] urls in
            self?.handleOpenedExternalAddSources(urls)
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

    func receiveExternalAddSources(_ urls: [URL]) {
        handleOpenedExternalAddSources(urls)
    }

    func addDownloadSourcesFromPasteboard() {
        receiveExternalAddSources(
            DownloadSourceImportService.supportedURLs(from: .general)
        )
    }

    @discardableResult
    func shutdownForTermination() async -> Bool {
        isShuttingDown = true
        let pendingRemovalReconciliation = pendingRemovalReconciliationTask
        pendingRemovalReconciliationTask = nil
        pendingRemovalReconciliation?.cancel()
        await cancelPendingPersistenceAndWait()
        let pendingTorrentRefresh = torrentRefreshTask
        torrentRefreshTask = nil
        pendingTorrentRefresh?.cancel()
        mediaStartTasks.values.forEach { $0.cancel() }
        torrentStartTasks.values.forEach { $0.cancel() }
        directRetryTasks.values.forEach { $0.cancel() }
        directRetryTasks.removeAll()
        readyDirectRetries.removeAll()
        torrentWatchFolderService.stop()

        await pendingTorrentRefresh?.value
        await pendingRemovalReconciliation?.value
        await cancelOrphanedTorrentCleanupTasksAndWait()

        for task in Array(cancellationTasks.values) {
            await task.value
        }
        for task in Array(removalTasks.values) {
            await task.value
        }
        for task in Array(torrentStopSeedingTasks.values) {
            await task.value
        }
        for task in Array(completionLookupTasks.values) {
            await task.value
        }
        for task in Array(completionTasks.values) {
            await task.value
        }

        let browserResults = await browserCoordinator.quiesceForShutdown()
        let browserWriterFailures = browserResults.filter {
            $0.value.writerQuiescenceUnavailableMessage != nil
        }
        for (id, result) in browserResults {
            guard let item = item(for: id),
                  directAttemptStates[id]?.identifier == result.attemptIdentifier else {
                continue
            }
            if let message = result.writerQuiescenceUnavailableMessage {
                directAttemptStates[id] = .active(result.attemptIdentifier)
                setStatus(for: item, to: .downloading)
                item.lastError = message
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
                continue
            }
            await reconcileCompletionAfterQuiescence(
                for: item,
                attemptIdentifier: result.attemptIdentifier
            )
            guard self.item(for: id) === item,
                  item.status != .completed else {
                continue
            }
            if let message = result.completionUnavailableMessage {
                item.taskIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.lastError = completedHandoffUnavailableMessage(message)
                item.updatedAt = .now
                setStatus(for: item, to: .failed)
                directAttemptStates.removeValue(forKey: id)
                continue
            }
            storeBrowserPauseResult(result.resumeData, for: item)
            directAttemptStates.removeValue(forKey: id)
            browserReservedIDs.remove(id)
            pendingBrowserContinuationIDs.remove(id)
            clearActiveBrowserSession(
                matching: id,
                attemptIdentifier: result.attemptIdentifier
            )
        }
        await drainDurableTerminalMutationTasksForShutdown()
        let remainingBrowserWriterFailures = browserWriterFailures.filter {
            browserCoordinator.hasActiveDownload(id: $0.key)
        }
        if remainingBrowserWriterFailures.isEmpty == false {
            let writerMessage = remainingBrowserWriterFailures.values
                .compactMap(\.writerQuiescenceUnavailableMessage)
                .first
                ?? String(localized: "The browser download is still writing.")
            do {
                try await saveRecordsNow()
            } catch {
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Browser Recovery Before Quitting"),
                    message: error.localizedDescription
                )
                browserCoordinator.resumeAfterFailedShutdown()
                isShuttingDown = false
                resumeDeferredSeedersAfterFailedShutdown()
                configureTorrentWatchFolder()
                startTorrentRefreshLoopIfNeeded()
                startNextQueuedDownloadsIfNeeded()
                return false
            }
            activeAlert = UserAlert(
                title: String(localized: "Browser Download Is Still Stopping"),
                message: writerMessage
            )
            browserCoordinator.resumeAfterFailedShutdown()
            isShuttingDown = false
            resumeDeferredSeedersAfterFailedShutdown()
            configureTorrentWatchFolder()
            startTorrentRefreshLoopIfNeeded()
            startNextQueuedDownloadsIfNeeded()
            return false
        }
        activeBrowserSession = nil
        browserReservedIDs.removeAll()
        pendingBrowserContinuationIDs.removeAll()

        let pendingStarts = Array(mediaStartTasks.values) + Array(torrentStartTasks.values)
        for task in pendingStarts {
            await task.value
        }

        let restoredStatus: DownloadStatus = settings.startDownloadsAutomatically ? .queued : .paused
        let pausedMessage = String(
            localized: "download.restore.pausedAfterQuit",
            defaultValue: "Paused after quit.",
            comment: "Status message shown when a download is paused because Harbor is quitting."
        )

        let activeItems = downloads.filter { item in
            item.status == .queued || item.status == .preparing || item.status == .waitingToRetry || item.isRunning
        }

        for item in activeItems {
            if item.backend == .aria2,
               item.status == .seeding,
               item.finishedAt != nil,
               item.shouldSeedAfterDownload,
               item.backendIdentifier == nil {
                // A Stop -> Start Seeding request completed its removal while
                // shutdown was already quiescing. Preserve the restart intent;
                // there is no live daemon GID left to pause.
                continue
            }
            switch item.backend {
            case .urlSession:
                if let pauseTask = directPauseTasks[item.id] {
                    await pauseTask.value
                } else if item.taskIdentifier != nil {
                    let attemptIdentifier = directAttemptStates[item.id]?.identifier
                    let pauseResult = await coordinator.pauseDownloadAndWait(id: item.id)
                    await reconcileCompletionAfterQuiescence(
                        for: item,
                        attemptIdentifier: attemptIdentifier
                    )
                    guard self.item(for: item.id) === item,
                          item.status != .completed else {
                        continue
                    }
                    storeURLSessionPauseResult(pauseResult, for: item)
                    if let message = pauseResult.recoveryUnavailableMessage {
                        item.lastError = directRecoveryUnavailableMessage(message)
                        setStatus(for: item, to: .failed)
                    }
                }
                item.backendIdentifier = nil
                directAttemptStates.removeValue(forKey: item.id)
            case .aria2:
                if let pauseTask = torrentPauseTasks[item.id] {
                    await pauseTask.value
                }
                if let backendIdentifier = item.backendIdentifier {
                    try? await torrentPauseOperation(torrentService, backendIdentifier)
                }
            case .ytDlp:
                if let pauseTask = mediaPauseTasks[item.id] {
                    await pauseTask.value
                } else {
                    await mediaService.pauseAndWait(id: item.id)
                }
                if let outcome = await mediaService.terminalOutcome(id: item.id),
                   activeMediaAttemptIdentifiers[item.id] == outcome.attemptIdentifier {
                    handle(outcome.event, attemptIdentifier: outcome.attemptIdentifier)
                }
                item.backendIdentifier = nil
            }

            guard item.status.isTerminal == false else {
                continue
            }
            setStatus(for: item, to: restoredStatus)
            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            if restoredStatus == .paused, item.lastError == nil {
                item.lastError = pausedMessage
            }
        }

        for task in Array(directPauseTasks.values) {
            await task.value
        }

        for task in Array(browserCancellationTasks.values) {
            await task.value
        }

        for task in Array(mediaPauseTasks.values) {
            await task.value
        }

        for task in Array(torrentPauseTasks.values) {
            await task.value
        }

        for task in Array(mediaCleanupTasks.values) {
            await task.value
        }

        // Cancellation/removal/stop-seeding tasks above are cleanup producers.
        // Drain again after they quiesce so no aria2 work can outlive daemon
        // shutdown or the final persistence snapshot.
        await cancelOrphanedTorrentCleanupTasksAndWait()

        await mediaService.shutdown()
        do {
            try await torrentShutdownOperation(torrentService)
        } catch {
            // The daemon may still be writing if its recovery session could not
            // be saved. Keep every owned GID slot-occupying until the refresh
            // loop can prove its authoritative state after termination is
            // cancelled.
            for item in downloads
            where item.backend == .aria2 && item.backendIdentifier != nil {
                setStatus(
                    for: item,
                    to: item.finishedAt == nil ? .downloading : .seeding
                )
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.lastError = error.localizedDescription
                item.updatedAt = .now
            }
            do {
                try await saveRecordsNow()
            } catch {
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Downloads Before Quitting"),
                    message: error.localizedDescription
                )
                isShuttingDown = false
                resumeDeferredSeedersAfterFailedShutdown()
                configureTorrentWatchFolder()
                startTorrentRefreshLoopIfNeeded()
                startNextQueuedDownloadsIfNeeded()
                return false
            }
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Save Torrent Recovery Before Quitting"),
                message: error.localizedDescription
            )
            isShuttingDown = false
            resumeDeferredSeedersAfterFailedShutdown()
            configureTorrentWatchFolder()
            startTorrentRefreshLoopIfNeeded()
            startNextQueuedDownloadsIfNeeded()
            return false
        }
        // A backend can finish while its shutdown pause is being quiesced.
        // Wait for completion work created after the earlier barrier before
        // taking the final durable snapshot.
        for task in Array(completionTasks.values) {
            await task.value
        }
        do {
            try await saveRecordsNow()
        } catch {
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Save Downloads Before Quitting"),
                message: error.localizedDescription
            )
            isShuttingDown = false
            resumeDeferredSeedersAfterFailedShutdown()
            configureTorrentWatchFolder()
            startTorrentRefreshLoopIfNeeded()
            startNextQueuedDownloadsIfNeeded()
            return false
        }
        return true
    }

    private func drainDurableTerminalMutationTasksForShutdown() async {
        while true {
            let pendingTasks = Array(cancellationTasks.values)
                + Array(removalTasks.values)
            guard pendingTasks.isEmpty == false else {
                return
            }
            for task in pendingTasks {
                await task.value
            }
        }
    }

    private func cancelOrphanedTorrentCleanupTasksAndWait() async {
        let tasks = Array(orphanedTorrentCleanupTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        orphanedTorrentCleanupTasks.removeAll()
    }

    private func resumeDeferredSeedersAfterFailedShutdown() {
        for item in downloads
        where item.backend == .aria2
            && item.backendIdentifier != nil
            && (item.status == .cancelled
                || (item.status == .completed && item.shouldSeedAfterDownload == false)) {
            if let gid = item.backendIdentifier {
                scheduleOrphanedTorrentCleanup(
                    gid: gid,
                    ownerDownloadID: item.id
                )
            }
        }

        let deferredIDs = downloads.lazy
            .filter {
                $0.backend == .aria2
                    && $0.status == .seeding
                    && $0.finishedAt != nil
                    && $0.shouldSeedAfterDownload
                    && $0.backendIdentifier == nil
                    && self.torrentStopSeedingTasks[$0.id] == nil
                    && self.torrentStartTasks[$0.id] == nil
            }
            .map(\.id)
        for id in deferredIDs {
            startOrQueueDownload(id: id)
        }
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
            torrentFingerprint: managedTorrentSource?.fingerprint,
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
                $0.torrentFingerprint == managedSource.fingerprint
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

        for item in downloads where item.sourceKind == .torrentFile && item.torrentFingerprint == nil {
            let candidateURL = item.managedTorrentSourcePath
                .map(URL.init(fileURLWithPath:))
                ?? item.sourceURL
            guard candidateURL.isFileURL,
                  FileManager.default.fileExists(atPath: candidateURL.path),
                  let fingerprint = try? await managedTorrentSourceStore.fingerprint(forTorrentAt: candidateURL) else {
                continue
            }

            item.torrentFingerprint = fingerprint
            didMutate = true
        }

        if didMutate {
            schedulePersist()
        }
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

        guard directPauseTasks[id] == nil,
              completionLookupTasks[id] == nil else {
            return
        }

        if item.status == .browserSessionRequired {
            continueInBrowser(id: id)
            return
        }

        if item.canResume, item.browserResumeData != nil {
            continueInBrowser(id: id)
            return
        }

        if item.canPause {
            pauseDownload(id: id)
        } else if item.canResume {
            resumeDownload(item)
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
        guard isShuttingDown == false,
              let item = item(for: id) else {
            return
        }

        guard completionTasks[id] == nil,
              completionLookupTasks[id] == nil else {
            return
        }

        if cancellationTasks[id] != nil {
            pendingRetryAfterCancellationIDs.insert(id)
            return
        }

        guard item.status == .failed || item.status == .cancelled else {
            return
        }

        guard directPauseTasks[id] == nil else {
            return
        }

        if item.backend == .urlSession,
           let cancellationTask = browserCancellationTasks[id] {
            let requestedStatus = item.status
            Task { @MainActor [weak self, weak item] in
                await cancellationTask.value

                guard let self,
                      let item,
                      self.isShuttingDown == false,
                      self.item(for: id) === item,
                      item.status == requestedStatus else {
                    return
                }

                self.retryDownload(id: id)
            }
            return
        }

        if item.backend == .ytDlp,
           mediaCleanupTasks[id] != nil
            || pendingMediaCleanupIDs.contains(id)
            || item.requiresMediaRecoveryReset {
            pendingMediaRetryAfterCleanupIDs.insert(id)
            scheduleMediaCleanup(id: id)
            return
        }

        if item.backend == .aria2,
           let backendIdentifier = item.backendIdentifier {
            if let cleanupTask = orphanedTorrentCleanupTasks[backendIdentifier] {
                cleanupTask.cancel()
                Task { @MainActor [weak self, weak item] in
                    await cleanupTask.value
                    guard let self,
                          let item,
                          self.item(for: id) === item,
                          self.isShuttingDown == false,
                          item.status == .failed || item.status == .cancelled else {
                        return
                    }
                    self.retryDownload(id: id)
                }
                return
            }
            beginTorrentRetryAfterConfirmedCleanup(
                item,
                backendIdentifier: backendIdentifier
            )
            return
        }

        if item.backend == .urlSession {
            beginDirectRetryAfterCompletionLookup(item)
            return
        }

        if item.backend == .ytDlp {
            beginMediaRetryAfterCompletionLookup(item)
            return
        }

        performRetry(of: item)
    }

    private func performRetry(of item: DownloadItem) {
        let id = item.id
        guard self.item(for: id) === item,
              item.status == .failed || item.status == .cancelled else {
            return
        }
        let statusBeforeRetry = item.status
        resetDirectRetryState(for: id)
        item.lastError = nil
        item.finishedAt = nil
        item.completionNotificationDelivered = false
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            item.fileLocationPath = nil
            if statusBeforeRetry == .cancelled {
                item.bytesWritten = 0
                item.expectedBytes = 0
                item.progress = 0
                item.resumeData = nil
                item.browserResumeData = nil
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
            item.backendIdentifier = nil
            item.fileLocationPath = nil
            if statusBeforeRetry == .cancelled {
                item.bytesWritten = 0
                item.progress = 0
            }
            item.expectedBytes = (item.mediaFormatPreference ?? .bestAvailable)
                .initialExpectedBytes(
                    metadataEstimate: item.mediaMetadata?.expectedBytes ?? 0
                )
            if item.expectedBytes > 0 {
                item.progress = min(
                    Double(item.bytesWritten) / Double(item.expectedBytes),
                    1
                )
            }
        }

        if item.backend == .urlSession, item.browserResumeData != nil {
            continueInBrowser(id: id)
        } else {
            startOrQueueDownload(id: id)
        }
    }

    private func beginTorrentRetryAfterConfirmedCleanup(
        _ item: DownloadItem,
        backendIdentifier: String
    ) {
        let id = item.id
        guard torrentStartTasks[id] == nil,
              torrentPauseTasks[id] == nil else {
            return
        }

        let retryStatus = item.status
        item.status = .preparing
        item.lastError = nil
        item.updatedAt = .now
        schedulePersist()

        let torrentService = torrentService
        let torrentRemoveOperation = torrentRemoveOperation
        torrentStartTasks[id] = Task {
            @MainActor [weak self, weak item, torrentService, torrentRemoveOperation] in
            do {
                try await torrentRemoveOperation(torrentService, backendIdentifier)
                guard let self else {
                    return
                }
                self.torrentStartTasks.removeValue(forKey: id)
                guard let item,
                      self.item(for: id) === item else {
                    self.startNextQueuedDownloadsIfNeeded()
                    return
                }

                if item.backendIdentifier == backendIdentifier {
                    item.backendIdentifier = nil
                }
                if self.pendingTorrentPauseIDs.remove(id) != nil {
                    self.torrentStartTasks.removeValue(forKey: id)
                    self.setStatus(for: item, to: .paused)
                    item.speedBytesPerSecond = 0
                    item.uploadBytesPerSecond = 0
                    item.updatedAt = .now
                    self.schedulePersist()
                    self.startNextQueuedDownloadsIfNeeded()
                    return
                }
                guard item.status == .preparing,
                      self.cancellationTasks[id] == nil,
                      self.removalTasks[id] == nil else {
                    self.schedulePersist()
                    self.startNextQueuedDownloadsIfNeeded()
                    return
                }

                item.status = retryStatus
                self.retryDownload(id: id)
            } catch {
                guard let self else {
                    return
                }
                self.torrentStartTasks.removeValue(forKey: id)
                if let item, self.item(for: id) === item {
                    let shouldPause = self.pendingTorrentPauseIDs.remove(id) != nil
                    if shouldPause {
                        item.status = .downloading
                    } else if item.status == .preparing {
                        item.status = retryStatus
                    }
                    item.backendIdentifier = backendIdentifier
                    item.lastError = error.localizedDescription
                    item.updatedAt = .now
                    self.schedulePersist()
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Restart Torrent"),
                        message: error.localizedDescription
                    )
                    if shouldPause {
                        self.pauseDownload(id: id)
                    }
                }
                self.startNextQueuedDownloadsIfNeeded()
            }
        }
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
            .forEach { resumeDownload($0) }
    }

    func cancelSelectedDownload() {
        cancelDownloads(ids: selectedDownloadIDs)
    }

    func cancelDownloads(ids: Set<UUID>) {
        guard isShuttingDown == false else {
            return
        }
        for item in orderedDownloads(for: ids)
        where item.status != .completed
            && item.status != .cancelled
            && item.status != .seeding
            && item.isPausedSeeder == false {
            cancelDownload(id: item.id)
        }
    }

    func cancelDownload(id: UUID) {
        guard let item = item(for: id),
              item.status != .completed,
              item.status != .cancelled,
              item.status != .seeding,
              completionTasks[id] == nil,
              cancellationTasks[id] == nil,
              removalTasks[id] == nil else {
            return
        }

        if item.isPausedSeeder {
            stopSeeding(id: id)
            return
        }

        if let attemptIdentifier = directAttemptStates[id]?.identifier {
            directAttemptStates[id] = .cancelling(attemptIdentifier)
        }
        if browserCoordinator.hasActiveDownload(id: id) {
            pendingBrowserWriterMutations[id] = .cancel
        }

        let task = Task { @MainActor [weak self, weak item] in
            guard let self, let item, self.item(for: id) === item else {
                self?.cancellationTasks.removeValue(forKey: id)
                return
            }
            await self.performDurableCancellation(of: item)
            self.cancellationTasks.removeValue(forKey: id)
            if self.resumePendingBrowserWriterMutationIfPossible(id: id) {
                return
            }
            let shouldRetry = self.pendingRetryAfterCancellationIDs.remove(id) != nil
            if shouldRetry,
               self.isShuttingDown == false,
               self.item(for: id) === item,
               item.status == .cancelled {
                self.retryDownload(id: id)
            } else {
                self.startNextQueuedDownloadsIfNeeded()
            }
        }
        cancellationTasks[id] = task
    }

    private func performDurableCancellation(of item: DownloadItem) async {
        let id = item.id
        let directAttemptIdentifier = directAttemptStates[id]?.identifier
        if let completionLookupTask = completionLookupTasks[id] {
            await completionLookupTask.value
            guard let currentItem = self.item(for: id),
                  currentItem === item,
                  currentItem.status != .completed else {
                return
            }
        }
        if let completionTask = completionTasks[id] {
            await completionTask.value
            guard let currentItem = self.item(for: id),
                  currentItem === item,
                  currentItem.status != .completed else {
                return
            }
        }

        let originalRecord = item.makeRecord()
        let originalActivityEvents = item.activityEvents
        let backendIdentifierBeforeQuiescence = item.backendIdentifier
        do {
            try await stopBackendPreservingRecovery(for: item)
            pendingBrowserWriterMutations.removeValue(forKey: id)
        } catch {
            if item.backend == .urlSession {
                if pendingBrowserWriterMutations[id] == nil,
                   browserCoordinator.hasActiveDownload(id: id) {
                    pendingBrowserWriterMutations[id] = .cancel
                }
            } else {
                pendingBrowserWriterMutations.removeValue(forKey: id)
            }
            item.status = backendStopFailureStatus(
                for: item,
                originalStatus: originalRecord.status
            )
            item.lastError = error.localizedDescription
            item.updatedAt = .now
            restoreDirectAttemptAfterStopFailure(id: id)
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Stop Download"),
                message: error.localizedDescription
            )
            return
        }

        await reconcileCompletionAfterQuiescence(
            for: item,
            attemptIdentifier: directAttemptIdentifier
        )
        if let completionTask = completionTasks[id] {
            await completionTask.value
        }
        guard let currentItem = self.item(for: id),
              currentItem === item,
              currentItem.status != .completed else {
            return
        }
        let backendIdentifier = item.backendIdentifier ?? backendIdentifierBeforeQuiescence

        var didPersistCancellation = false
        await performSerializedDurableMutation { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item(for: id) === item,
                  item.status != .completed,
                  self.completionTasks[id] == nil else {
                return
            }

            let preservedResumeData = item.resumeData
            let preservedBrowserResumeData = item.browserResumeData
            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.resumeData = nil
            item.browserResumeData = nil
            item.progress = 0
            item.bytesWritten = 0
            item.expectedBytes = 0
            item.lastError = nil
            item.updatedAt = .now
            if item.backend == .ytDlp {
                // Cleanup is a post-commit side effect. Persist a barrier in
                // the cancellation record first so a crash cannot make stale
                // fragments resumable again on the next launch.
                item.requiresMediaRecoveryReset = true
            }
            self.setStatus(for: item, to: .cancelled)

            do {
                try await self.saveRecordsNow()
                didPersistCancellation = true
            } catch {
                item.status = self.durableMutationFailureStatus(from: originalRecord.status)
                item.activityEvents = originalActivityEvents
                item.resumeData = preservedResumeData
                item.browserResumeData = preservedBrowserResumeData
                item.progress = originalRecord.progress
                item.bytesWritten = originalRecord.bytesWritten
                item.expectedBytes = originalRecord.expectedBytes
                item.requiresMediaRecoveryReset = originalRecord.requiresMediaRecoveryReset
                item.lastError = error.localizedDescription
                item.updatedAt = .now
                self.directAttemptStates.removeValue(forKey: id)
                self.activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Cancel Download"),
                    message: error.localizedDescription
                )
            }
        }

        guard didPersistCancellation else {
            pendingBrowserWriterMutations.removeValue(forKey: id)
            if let completionTask = completionTasks[id] {
                await completionTask.value
            }
            return
        }

        // A completion event may have arrived while the cancellation record
        // was being saved. Let its validated handoff win before discarding
        // backend recovery or delivering a cancellation notification.
        if let completionTask = completionTasks[id] {
            await completionTask.value
            if item.status == .completed {
                return
            }
        }

        do {
            try await discardBackendRecovery(for: item, backendIdentifier: backendIdentifier)
        } catch {
            item.lastError = error.localizedDescription
            item.updatedAt = .now
            if let backendIdentifier, item.backend == .aria2 {
                scheduleOrphanedTorrentCleanup(
                    gid: backendIdentifier,
                    ownerDownloadID: item.id
                )
            } else if item.backend == .ytDlp {
                pendingMediaCleanupIDs.insert(id)
                scheduleMediaCleanup(id: id)
            }
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Finish Cancelling Download"),
                message: error.localizedDescription
            )
            try? await saveRecordsNow()
            restoreDirectAttemptAfterStopFailure(id: id)
            activeMediaAttemptIdentifiers.removeValue(forKey: id)
            return
        }
        if item.backend == .ytDlp, item.requiresMediaRecoveryReset {
            var didPersistCleanup = false
            await performSerializedDurableMutation { [weak self, weak item] in
                guard let self,
                      let item,
                      self.item(for: id) === item,
                      item.status == .cancelled else {
                    return
                }
                item.requiresMediaRecoveryReset = false
                item.updatedAt = .now
                do {
                    try await self.saveRecordsNow()
                    didPersistCleanup = true
                } catch {
                    // The cleanup itself is idempotent. Keep the durable
                    // barrier conservative until its cleared state can be
                    // saved, then let the tracked cleanup task retry both.
                    item.requiresMediaRecoveryReset = true
                    item.lastError = error.localizedDescription
                    item.updatedAt = .now
                    self.pendingMediaCleanupIDs.insert(id)
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Save Media Cleanup"),
                        message: error.localizedDescription
                    )
                }
            }
            guard didPersistCleanup else {
                scheduleMediaCleanup(id: id)
                activeMediaAttemptIdentifiers.removeValue(forKey: id)
                return
            }
            pendingMediaCleanupIDs.remove(id)
            pendingMediaRecoveryResets.remove(id)
        }
        directAttemptStates.removeValue(forKey: id)
        pendingBrowserWriterMutations.removeValue(forKey: id)
        activeMediaAttemptIdentifiers.removeValue(forKey: id)
        if item.backend == .aria2, item.backendIdentifier != nil {
            await performSerializedDurableMutation { [weak self, weak item] in
                guard let self,
                      let item,
                      self.item(for: id) === item,
                      let removedIdentifier = item.backendIdentifier else {
                    return
                }
                item.backendIdentifier = nil
                do {
                    try await self.saveRecordsNow()
                } catch {
                    item.backendIdentifier = removedIdentifier
                    item.lastError = error.localizedDescription
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Save Torrent Cleanup"),
                        message: error.localizedDescription
                    )
                }
            }
        }
        deliverNotificationIfEnabled(for: item, status: .cancelled)
    }

    private func stopBackendPreservingRecovery(for item: DownloadItem) async throws {
        let id = item.id
        resetDirectRetryState(for: id)
        browserReservedIDs.remove(id)
        pendingBrowserContinuationIDs.remove(id)

        switch item.backend {
        case .urlSession:
            var consumedTrackedPause = false
            if let pauseTask = directPauseTasks[id] {
                await pauseTask.value
            }
            if let trackedResult = completedDirectPauseResults.removeValue(forKey: id) {
                consumedTrackedPause = true
                switch trackedResult {
                case let .browser(result):
                    if let message = result.writerQuiescenceUnavailableMessage {
                        throw DownloadRecoveryQuiescenceError(message: message)
                    }
                    storeBrowserPauseResult(result.resumeData, for: item)
                    if let message = result.completionUnavailableMessage {
                        let handoff = await completedHandoff(
                            downloadID: id,
                            attemptIdentifier: result.attemptIdentifier
                        )
                        if handoff == nil {
                            throw DownloadRecoveryQuiescenceError(message: message)
                        }
                    }
                case let .direct(result):
                    storeURLSessionPauseResult(result, for: item)
                    if let message = result.recoveryUnavailableMessage,
                       let attemptIdentifier = result.attemptIdentifier {
                        let handoff = await completedHandoff(
                            downloadID: id,
                            attemptIdentifier: attemptIdentifier
                        )
                        if handoff == nil {
                            throw DownloadRecoveryQuiescenceError(message: message)
                        }
                    }
                }
            }
            if let browserTask = browserCancellationTasks[id] {
                await browserTask.value
            }
            if consumedTrackedPause == false,
               let quiescence = await browserQuiescenceOperation(browserCoordinator, id) {
                if let message = quiescence.writerQuiescenceUnavailableMessage {
                    throw DownloadRecoveryQuiescenceError(message: message)
                }
                storeBrowserPauseResult(quiescence.resumeData, for: item)
                if let message = quiescence.completionUnavailableMessage {
                    _ = try await browserCoordinator.recoverCompletedTemporaryFiles(
                        downloadID: id
                    )
                    if await completedHandoff(
                        downloadID: id,
                        attemptIdentifier: quiescence.attemptIdentifier
                    ) == nil {
                        throw DownloadRecoveryQuiescenceError(message: message)
                    }
                }
            } else if consumedTrackedPause == false, item.taskIdentifier != nil {
                let pauseResult = await coordinator.pauseDownloadAndWait(id: id)
                storeURLSessionPauseResult(pauseResult, for: item)
                if let message = pauseResult.recoveryUnavailableMessage,
                   let attemptIdentifier = pauseResult.attemptIdentifier {
                    let handoff = await completedHandoff(
                        downloadID: id,
                        attemptIdentifier: attemptIdentifier
                    )
                    if handoff == nil {
                        throw DownloadRecoveryQuiescenceError(message: message)
                    }
                }
            }
            clearActiveBrowserSession(matching: id)
            item.taskIdentifier = nil

        case .aria2:
            if let startTask = torrentStartTasks[id] {
                await startTask.value
            }
            if let pauseTask = torrentPauseTasks[id] {
                await pauseTask.value
            }
            if let backendIdentifier = item.backendIdentifier {
                try await torrentPauseOperation(torrentService, backendIdentifier)
            }

        case .ytDlp:
            pendingMediaResumeIDs.remove(id)
            let startTask = mediaStartTasks[id]
            startTask?.cancel()
            await startTask?.value
            if let pauseTask = mediaPauseTasks[id] {
                await pauseTask.value
            } else {
                await mediaPauseOperation(mediaService, id)
            }
            if let outcome = await mediaService.terminalOutcome(id: id),
               activeMediaAttemptIdentifiers[id] == outcome.attemptIdentifier {
                handle(outcome.event, attemptIdentifier: outcome.attemptIdentifier)
            }
        }
    }

    private func discardBackendRecovery(
        for item: DownloadItem,
        backendIdentifier: String?
    ) async throws {
        switch item.backend {
        case .urlSession:
            try urlSessionCleanupOperation(
                coordinator,
                browserCoordinator,
                item.id
            )
        case .aria2:
            if let backendIdentifier {
                try await torrentRemoveOperation(torrentService, backendIdentifier)
            }
            try await torrentService.discardPendingSubmission(
                ownerDownloadID: item.id
            )
        case .ytDlp:
            try await mediaCleanupOperation(mediaService, item.id)
        }
    }

    private func durableMutationFailureStatus(from originalStatus: DownloadStatus) -> DownloadStatus {
        switch originalStatus {
        case .failed, .browserSessionRequired, .paused, .completed, .cancelled:
            originalStatus
        case .queued, .preparing, .waitingToRetry, .downloading, .seeding:
            .paused
        }
    }

    private func backendStopFailureStatus(
        for item: DownloadItem,
        originalStatus: DownloadStatus
    ) -> DownloadStatus {
        if item.backend == .urlSession,
           browserCoordinator.hasActiveDownload(id: item.id) {
            // A WebKit timeout is not writer quiescence. Retain the active
            // slot until a late delegate or cancel callback proves it stopped.
            return .downloading
        }
        guard item.backend == .aria2, item.backendIdentifier != nil else {
            return durableMutationFailureStatus(from: originalStatus)
        }

        // A failed aria2 pause leaves the engine's transfer state unknown.
        // Keep the item slot-occupying until refresh proves that the GID is
        // paused or gone; reporting it as paused could start another transfer
        // while aria2 is still writing.
        if item.finishedAt != nil, item.shouldSeedAfterDownload {
            return .seeding
        }
        return .downloading
    }

    private func restoreDirectAttemptAfterStopFailure(id: UUID) {
        if browserCoordinator.hasActiveDownload(id: id),
           let attemptIdentifier = directAttemptStates[id]?.identifier {
            directAttemptStates[id] = .active(attemptIdentifier)
        } else {
            directAttemptStates.removeValue(forKey: id)
        }
    }

    @discardableResult
    private func resumePendingBrowserWriterMutationIfPossible(id: UUID) -> Bool {
        guard browserCoordinator.hasActiveDownload(id: id) == false,
              let pending = pendingBrowserWriterMutations[id] else {
            return false
        }
        guard let item = item(for: id), item.status != .completed else {
            pendingBrowserWriterMutations.removeValue(forKey: id)
            return false
        }

        switch pending {
        case .cancel:
            guard cancellationTasks[id] == nil, removalTasks[id] == nil else {
                return false
            }
            pendingBrowserWriterMutations.removeValue(forKey: id)
            cancelDownload(id: id)
        case let .remove(removingData):
            guard cancellationTasks[id] == nil, removalTasks[id] == nil else {
                return false
            }
            pendingBrowserWriterMutations.removeValue(forKey: id)
            beginDurableRemoval(id: id, removingData: removingData)
        }
        return true
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
        guard isShuttingDown == false else {
            return
        }
        for item in orderedDownloads(for: ids) {
            beginDurableRemoval(id: item.id, removingData: true)
        }
    }

    private func payloadPaths(for item: DownloadItem) -> [String] {
        if item.torrentPayloadPaths.isEmpty == false {
            return item.torrentPayloadPaths
        }

        return item.fileLocationPath.map { [$0] } ?? []
    }

    func removeDownload(id: UUID) {
        guard isShuttingDown == false else {
            return
        }
        beginDurableRemoval(id: id, removingData: false)
    }

    private func beginDurableRemoval(id: UUID, removingData: Bool) {
        guard item(for: id) != nil,
              removalTasks[id] == nil else {
            return
        }

        if let attemptIdentifier = directAttemptStates[id]?.identifier {
            directAttemptStates[id] = .cancelling(attemptIdentifier)
        }
        if browserCoordinator.hasActiveDownload(id: id) {
            pendingBrowserWriterMutations[id] = .remove(removingData: removingData)
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if let cancellationTask = self.cancellationTasks[id] {
                await cancellationTask.value
            }
            guard let item = self.item(for: id) else {
                self.removalTasks.removeValue(forKey: id)
                return
            }
            await self.performDurableRemoval(of: item, removingData: removingData)
            self.removalTasks.removeValue(forKey: id)
            if self.resumePendingBrowserWriterMutationIfPossible(id: id) {
                return
            }
            self.startNextQueuedDownloadsIfNeeded()
        }
        removalTasks[id] = task
    }

    private func performDurableRemoval(
        of item: DownloadItem,
        removingData: Bool
    ) async {
        let id = item.id
        if let stopSeedingTask = torrentStopSeedingTasks[id] {
            await stopSeedingTask.value
        }
        guard self.item(for: id) === item else {
            return
        }
        let directAttemptIdentifier = directAttemptStates[id]?.identifier
        if let completionLookupTask = completionLookupTasks[id] {
            await completionLookupTask.value
        }
        guard self.item(for: id) === item else {
            return
        }
        if let completionTask = completionTasks[id] {
            await completionTask.value
        }
        guard self.item(for: id) === item else {
            return
        }

        let originalIndex = downloads.firstIndex { $0.id == id } ?? downloads.endIndex
        let statusBeforeQuiescence = item.status
        let backendIdentifierBeforeQuiescence = item.backendIdentifier
        let previousSelectedIDs = selectedDownloadIDs
        let previousSelectedID = selectedDownloadID

        do {
            try await stopBackendPreservingRecovery(for: item)
            pendingBrowserWriterMutations.removeValue(forKey: id)
        } catch {
            if item.backend == .urlSession {
                if pendingBrowserWriterMutations[id] == nil,
                   browserCoordinator.hasActiveDownload(id: id) {
                    pendingBrowserWriterMutations[id] = .remove(removingData: removingData)
                }
            } else {
                pendingBrowserWriterMutations.removeValue(forKey: id)
            }
            item.status = backendStopFailureStatus(
                for: item,
                originalStatus: statusBeforeQuiescence
            )
            item.lastError = error.localizedDescription
            item.updatedAt = .now
            restoreDirectAttemptAfterStopFailure(id: id)
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Stop Download"),
                message: error.localizedDescription
            )
            return
        }

        await reconcileCompletionAfterQuiescence(
            for: item,
            attemptIdentifier: directAttemptIdentifier
        )
        if let completionTask = completionTasks[id] {
            await completionTask.value
        }
        guard self.item(for: id) === item else {
            return
        }
        let rollbackStatus = item.status
        let backendIdentifier = item.backendIdentifier ?? backendIdentifierBeforeQuiescence

        let removalManifest: PendingDownloadDataRemovalManifest
        do {
            removalManifest = try pendingDataRemovalStore.publish(
                record: item.makeRecord(),
                removingData: removingData
            )
        } catch {
            item.status = durableMutationFailureStatus(from: rollbackStatus)
            item.lastError = error.localizedDescription
            item.updatedAt = .now
            directAttemptStates.removeValue(forKey: id)
            activeAlert = UserAlert(
                title: removingData
                    ? String(localized: "Couldn’t Prepare Download Data Removal")
                    : String(localized: "Couldn’t Prepare Download Removal"),
                message: error.localizedDescription
            )
            return
        }

        if removalManifest.removesPayload,
           removalManifest.phase == .payloadDeletionStarted {
            let inspection = dataRemovalService.inspectPayloadData(
                destinationFolderPath: removalManifest.record.destinationFolderPath,
                payloadPaths: Self.payloadPaths(for: removalManifest.record)
            )
            if inspection.existingPaths.isEmpty == false
                || inspection.failures.isEmpty == false {
                applyInterruptedDataRemovalInspection(inspection, to: item)
                do {
                    try await saveRecordsNow()
                    try pendingDataRemovalStore.acknowledgeOrThrow(downloadID: id)
                } catch {
                    item.lastError = [item.lastError, error.localizedDescription]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                }
                activeAlert = UserAlert(
                    title: String(localized: "Download Data Was Left in Place"),
                    message: item.lastError ?? ""
                )
                directAttemptStates.removeValue(forKey: id)
                return
            }
        }

        if removalManifest.removesPayload,
           removalManifest.phase == .payloadPending {
            do {
                _ = try pendingDataRemovalStore.markPayloadDeletionStarted(downloadID: id)
            } catch {
                item.status = durableMutationFailureStatus(from: rollbackStatus)
                item.lastError = error.localizedDescription
                item.updatedAt = .now
                directAttemptStates.removeValue(forKey: id)
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Prepare Download Data Removal"),
                    message: error.localizedDescription
                )
                return
            }
            let result = dataRemovalService.movePayloadDataToTrash(
                destinationFolderPath: item.destinationFolderPath,
                payloadPaths: payloadPaths(for: item)
            )
            if result.failures.isEmpty == false {
                applyPartialDataRemovalResult(result, to: item)
                do {
                    try await saveRecordsNow()
                    try pendingDataRemovalStore.acknowledgeOrThrow(downloadID: id)
                } catch {
                    item.lastError = [item.lastError, error.localizedDescription]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                }
                activeAlert = UserAlert(
                    title: String(localized: "Some Download Data Couldn’t Be Moved to Trash"),
                    message: item.lastError ?? String(localized: "The remaining payload is still tracked by Harbor.")
                )
                directAttemptStates.removeValue(forKey: id)
                return
            }
        }

        if removalManifest.removesPayload,
           removalManifest.phase != .backendCleanup {
            do {
                _ = try pendingDataRemovalStore.markBackendCleanup(downloadID: id)
            } catch {
                item.status = durableMutationFailureStatus(from: rollbackStatus)
                item.lastError = error.localizedDescription
                item.updatedAt = .now
                directAttemptStates.removeValue(forKey: id)
                activeAlert = UserAlert(
                    title: String(localized: "Download Data Removed; Record Cleanup Pending"),
                    message: error.localizedDescription
                )
                schedulePendingRemovalReconciliation()
                return
            }
        }

        var shouldContinueBackendCleanup = false
        await performSerializedDurableMutation { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item(for: id) === item else {
                return
            }

            self.downloads.removeAll { $0.id == id }
            self.selectedDownloadIDs.remove(id)
            if self.selectedDownloadID == id || self.selectedDownloadIDs.isEmpty {
                self.selectDownload(self.orderedDownloads(for: self.selectedDownloadIDs).first?.id
                    ?? self.filteredDownloads.first?.id
                    ?? self.downloads.first?.id)
            }

            do {
                try await self.saveRecordsNow()
                shouldContinueBackendCleanup = true
            } catch {
                self.directAttemptStates.removeValue(forKey: id)
                if removalManifest.removesPayload {
                    self.activeAlert = UserAlert(
                        title: String(localized: "Download Data Removed; Record Cleanup Pending"),
                        message: error.localizedDescription
                    )
                    self.schedulePendingRemovalReconciliation()
                } else {
                    do {
                        try self.pendingDataRemovalStore.acknowledgeOrThrow(downloadID: id)
                        self.downloads.insert(
                            item,
                            at: min(originalIndex, self.downloads.endIndex)
                        )
                        self.restoreSelection(
                            selectedIDs: previousSelectedIDs,
                            selectedID: previousSelectedID
                        )
                        item.status = self.durableMutationFailureStatus(from: rollbackStatus)
                        item.lastError = error.localizedDescription
                        item.updatedAt = .now
                        self.activeAlert = UserAlert(
                            title: String(localized: "Couldn’t Remove Download"),
                            message: error.localizedDescription
                        )
                    } catch let journalError {
                        self.activeAlert = UserAlert(
                            title: String(localized: "Download Removal Pending"),
                            message: [error.localizedDescription, journalError.localizedDescription]
                                .joined(separator: "\n")
                        )
                        self.schedulePendingRemovalReconciliation()
                    }
                }
            }
        }

        guard shouldContinueBackendCleanup else {
            return
        }

        var didCompleteBackendCleanup = false
        do {
            try await discardBackendRecovery(for: item, backendIdentifier: backendIdentifier)
            didCompleteBackendCleanup = true
        } catch {
            if let backendIdentifier, item.backend == .aria2 {
                scheduleOrphanedTorrentCleanup(gid: backendIdentifier)
            }
            activeAlert = UserAlert(
                title: String(localized: "Download Removed; Backend Cleanup Pending"),
                message: error.localizedDescription
            )
            schedulePendingRemovalReconciliation()
        }
        directAttemptStates.removeValue(forKey: id)
        activeMediaAttemptIdentifiers.removeValue(forKey: id)
        moveOriginalTorrentFileToTrashIfNeeded(for: item)
        removeManagedTorrentSourceIfNeeded(for: item)
        if didCompleteBackendCleanup {
            pendingDataRemovalStore.acknowledge(downloadID: id)
        }
    }

    private func restoreSelection(selectedIDs: Set<UUID>, selectedID: UUID?) {
        let availableIDs = Set(downloads.map(\.id))
        isReconcilingSelection = true
        selectedDownloadIDs = selectedIDs.intersection(availableIDs)
        selectedDownloadID = selectedID.flatMap { availableIDs.contains($0) ? $0 : nil }
            ?? orderedDownloads(for: selectedDownloadIDs).first?.id
        isReconcilingSelection = false
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

        guard let expectedFingerprint = item.torrentFingerprint,
              let data = try? Data(contentsOf: item.sourceURL, options: .mappedIfSafe),
              ManagedTorrentSourceStore.fingerprint(for: data) == expectedFingerprint else {
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
        Task { @MainActor [weak self] in
            await self?.performClearCompleted()
        }
    }

    private func performClearCompleted() async {
        for task in Array(completionLookupTasks.values) {
            await task.value
        }
        for task in Array(completionTasks.values) {
            await task.value
        }
        for task in Array(torrentStopSeedingTasks.values) {
            await task.value
        }
        let completedItems = downloads.filter { $0.status == .completed }
        for completedItem in completedItems {
            guard item(for: completedItem.id) === completedItem,
                  completedItem.status == .completed else {
                continue
            }
            await performDurableRemoval(of: completedItem, removingData: false)
        }
    }

    func clearFailed() async {
        await cancelPendingPersistenceAndWait()
        let failedItems = downloads.filter { $0.status == .failed }
        for failedItem in failedItems {
            guard item(for: failedItem.id) === failedItem,
                  failedItem.status == .failed else {
                continue
            }
            await performDurableRemoval(of: failedItem, removingData: false)
        }
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

    func pauseDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) where item.canPause || item.status == .queued {
            pauseDownload(id: item.id)
        }
    }

    func resumeDownloads(ids: Set<UUID>) {
        for item in orderedDownloads(for: ids) where item.canResume {
            resumeDownload(item)
        }
    }

    private func resumeDownload(_ item: DownloadItem) {
        guard directPauseTasks[item.id] == nil else {
            return
        }

        if item.backend == .ytDlp, mediaPauseTasks[item.id] != nil {
            pendingMediaResumeIDs.insert(item.id)
            return
        }

        if item.backend == .urlSession, item.browserResumeData != nil {
            continueInBrowser(id: item.id)
        } else {
            startOrQueueDownload(id: item.id)
        }
    }

    func startSeeding(id: UUID) {
        guard let item = item(for: id),
              item.backend == .aria2,
              item.finishedAt != nil else {
            return
        }

        if torrentStopSeedingTasks[id] != nil {
            pendingTorrentSeedingRestartIDs.insert(id)
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
        guard isShuttingDown == false,
              let item = item(for: id),
              item.backend == .aria2,
              item.finishedAt != nil,
              item.shouldSeedAfterDownload,
              torrentStopSeedingTasks[id] == nil else {
            return
        }

        guard item.backendIdentifier != nil else {
            finalizeStoppedSeeding(item)
            return
        }

        let task = Task { @MainActor [weak self] in
            await self?.performStopSeeding(id: id)
            guard let self else {
                return
            }
            self.torrentStopSeedingTasks.removeValue(forKey: id)
            if self.pendingTorrentSeedingRestartIDs.remove(id) != nil {
                if self.isShuttingDown,
                   let item = self.item(for: id),
                   item.finishedAt != nil {
                    item.shouldSeedAfterDownload = true
                    item.status = .seeding
                    item.lastError = nil
                    item.updatedAt = .now
                } else {
                    self.startSeeding(id: id)
                }
            }
        }
        torrentStopSeedingTasks[id] = task
    }

    private func performStopSeeding(id: UUID) async {
        guard let item = item(for: id),
              item.backend == .aria2,
              item.finishedAt != nil,
              item.shouldSeedAfterDownload else {
            return
        }

        guard let backendIdentifier = item.backendIdentifier else {
            finalizeStoppedSeeding(item)
            return
        }

        var didPersistStopIntent = false
        await performSerializedDurableMutation { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item(for: id) === item,
                  item.backendIdentifier == backendIdentifier,
                  item.finishedAt != nil,
                  item.shouldSeedAfterDownload else {
                return
            }

            let originalRecord = item.makeRecord()
            item.shouldSeedAfterDownload = false
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.lastError = nil
            item.updatedAt = .now
            item.status = .completed
            item.recordActivity(.seedingStopped)

            do {
                // Persist the user's stop intent while retaining the GID. If
                // the app exits after this point, restoration can finish
                // cleanup instead of silently re-starting the seeder.
                try await self.saveRecordsNow()
                didPersistStopIntent = true
            } catch {
                // Keep mutation, save, and rollback under one gate. Otherwise
                // another task can durably capture the transient completed
                // state before this rollback restores the active seeder.
                self.replaceItem(id: id, with: originalRecord, reporting: error)
                self.activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Seeding State"),
                    message: error.localizedDescription
                )
            }
        }
        guard didPersistStopIntent else {
            return
        }

        do {
            try await torrentRemoveOperation(torrentService, backendIdentifier)
        } catch {
            item.backendIdentifier = backendIdentifier
            item.lastError = error.localizedDescription
            item.updatedAt = .now
            try? await saveRecordsNow()
            scheduleOrphanedTorrentCleanup(
                gid: backendIdentifier,
                ownerDownloadID: item.id
            )
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Stop Seeding"),
                message: error.localizedDescription
            )
            return
        }

        guard item.backendIdentifier == backendIdentifier,
              item.shouldSeedAfterDownload == false else {
            return
        }
        await performSerializedDurableMutation { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item(for: id) === item,
                  item.backendIdentifier == backendIdentifier,
                  item.shouldSeedAfterDownload == false else {
                return
            }
            item.backendIdentifier = nil
            item.updatedAt = .now
            do {
                try await self.saveRecordsNow()
            } catch {
                item.backendIdentifier = backendIdentifier
                item.lastError = error.localizedDescription
                item.updatedAt = .now
                self.scheduleOrphanedTorrentCleanup(
                    gid: backendIdentifier,
                    ownerDownloadID: item.id
                )
                self.activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Torrent Cleanup"),
                    message: error.localizedDescription
                )
            }
        }
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
        guard isShuttingDown == false else {
            return
        }
        if activeBrowserSession?.downloadID == id {
            return
        }
        guard let item = item(for: id),
              item.sourceKind == .directURL,
              item.status == .browserSessionRequired || item.browserResumeData != nil,
              browserCancellationTasks[id] == nil,
              completionTasks[id] == nil,
              completionLookupTasks[id] == nil,
              pendingBrowserContinuationIDs.contains(id) == false,
              directAttemptStates[id] == nil,
              browserReservedIDs.contains(id) == false
        else {
            return
        }

        guard directPauseTasks[id] == nil else {
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

        if occupiedDownloadIDs.contains(id) == false,
           occupiedDownloadIDs.count >= settings.transferSettings.maxConcurrentDownloads {
            activeAlert = UserAlert(
                title: String(localized: "Download Limit Reached"),
                message: String(localized: "Pause another active download before opening this browser session.")
            )
            return
        }

        let attemptIdentifier = UUID()
        pendingBrowserContinuationIDs.insert(id)
        browserReservedIDs.insert(id)
        directAttemptStates[id] = .active(attemptIdentifier)
        let session = browserCoordinator.startSession(
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            displayName: item.displayName,
            resumeData: item.browserResumeData
        )
        pendingBrowserContinuationIDs.remove(id)

        activeBrowserSession = session
        setStatus(for: item, to: .preparing)
        item.lastError = nil
        item.updatedAt = .now
        schedulePersist()
    }

    func dismissBrowserSession() {
        guard let session = activeBrowserSession else {
            return
        }
        activeBrowserSession = nil
        let id = session.downloadID
        guard browserCancellationTasks[id] == nil else {
            return
        }

        let secureBrowserCoordinator = browserCoordinator!
        let task = Task { @MainActor [weak self, secureBrowserCoordinator] in
            let quiescence = await secureBrowserCoordinator.quiesceDownload(id: id)
            guard let self else {
                return
            }
            self.browserCancellationTasks.removeValue(forKey: id)
            self.browserReservedIDs.remove(id)

            guard let item = self.item(for: id),
                  case let .active(currentAttempt) = self.directAttemptStates[id],
                  currentAttempt == session.attemptIdentifier,
                  quiescence?.attemptIdentifier == session.attemptIdentifier else {
                self.startNextQueuedDownloadsIfNeeded()
                return
            }

            if let message = quiescence?.writerQuiescenceUnavailableMessage {
                self.setStatus(for: item, to: .downloading)
                item.lastError = message
                item.updatedAt = .now
                self.schedulePersist()
                return
            }
            if let message = quiescence?.completionUnavailableMessage {
                self.failBrowserCompletionPublication(
                    id: id,
                    attemptIdentifier: session.attemptIdentifier,
                    message: message
                )
                return
            }

            self.storeBrowserPauseResult(quiescence?.resumeData, for: item)
            self.markBrowserSessionRequired(
                item,
                message: String(localized: "Open the browser session to continue this download."),
                preservingProgress: quiescence?.resumeData != nil
            )
            self.directAttemptStates.removeValue(forKey: id)
            self.schedulePersist()
            self.startNextQueuedDownloadsIfNeeded()
        }
        browserCancellationTasks[id] = task
    }

    private func startOrQueueDownload(id: UUID) {
        guard isShuttingDown == false else {
            return
        }

        guard cancellationTasks[id] == nil,
              removalTasks[id] == nil else {
            return
        }

        guard let item = item(for: id) else {
            return
        }

        if item.backend == .aria2,
           let gid = item.backendIdentifier,
           let cleanupTask = orphanedTorrentCleanupTasks[gid] {
            // A user reactivation supersedes delayed terminal cleanup. Wait
            // until a cleanup request that may already be in flight settles;
            // then status reconciliation can either reuse the GID or submit a
            // replacement without racing a forceRemove.
            cleanupTask.cancel()
            Task { @MainActor [weak self, weak item] in
                await cleanupTask.value
                guard let self,
                      let item,
                      self.item(for: id) === item,
                      self.isShuttingDown == false else {
                    return
                }
                self.startOrQueueDownload(id: id)
            }
            return
        }

        if item.backend == .ytDlp, item.requiresMediaRecoveryReset {
            pendingMediaStartAfterCleanupIDs.insert(id)
            scheduleMediaCleanup(id: id)
            return
        }

        if item.backend == .aria2, torrentStopSeedingTasks[id] != nil {
            if item.finishedAt != nil {
                pendingTorrentSeedingRestartIDs.insert(id)
            }
            return
        }

        if item.backend == .urlSession, directPauseTasks[id] != nil {
            return
        }

        if item.backend == .urlSession, browserCancellationTasks[id] != nil {
            return
        }

        if item.backend == .urlSession, item.browserResumeData != nil {
            markBrowserSessionRequired(
                item,
                message: String(
                    localized: "download.browser.resumeAfterRelaunch",
                    defaultValue: "Browser download progress is available. Continue in the browser to resume it.",
                    comment: "Status message shown when a browser-backed download can be resumed after relaunch."
                ),
                preservingProgress: true
            )
            schedulePersist()
            return
        }

        if item.backend == .urlSession, item.taskIdentifier != nil {
            return
        }

        if item.backend == .aria2, torrentStartTasks[id] != nil {
            return
        }

        if item.backend == .aria2, torrentPauseTasks[id] != nil {
            setStatus(for: item, to: .queued)
            item.updatedAt = .now
            schedulePersist()
            return
        }

        if item.backend == .ytDlp,
           mediaStartTasks[id] != nil
            || mediaPauseTasks[id] != nil
            || mediaCleanupTasks[id] != nil {
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
            resetDirectRetryState(for: item.id)
            startDirectDownload(item)

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
            let attemptIdentifier = UUID()
            activeMediaAttemptIdentifiers[id] = attemptIdentifier
            mediaStartTasks[id] = Task { @MainActor [weak self] in
                await self?.startMediaDownload(
                    id: id,
                    attemptIdentifier: attemptIdentifier
                )
            }
        }
    }

    private func startDirectDownload(
        _ item: DownloadItem,
        restartingFromBeginning: Bool = false
    ) {
        guard directAttemptStates[item.id] == nil else {
            return
        }
        if restartingFromBeginning {
            // A fresh HTTP attempt invalidates only range-resume state. A
            // completed handoff may have been created by the failed attempt's
            // final publication and must remain available to reconciliation.
            do {
                try coordinator.discardOwnedRecoveryDataOrThrow(id: item.id)
            } catch {
                item.taskIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.lastError = error.localizedDescription
                item.updatedAt = .now
                setStatus(for: item, to: .failed)
                activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Restart Download"),
                    message: error.localizedDescription
                )
                schedulePersist()
                startNextQueuedDownloadsIfNeeded()
                return
            }
            item.resumeData = nil
            item.bytesWritten = 0
            item.progress = 0
        }

        item.lastError = nil
        setStatus(for: item, to: .preparing)
        let attemptIdentifier = UUID()
        directAttemptStates[item.id] = .active(attemptIdentifier)
        do {
            item.taskIdentifier = try coordinator.startDownload(
                id: item.id,
                attemptIdentifier: attemptIdentifier,
                sourceURL: item.sourceURL,
                resumeData: item.resumeData,
                speedLimitOverride: item.downloadLimitOverride
            )
            item.resumeData = nil
        } catch {
            if directAttemptStates[item.id]?.identifier == attemptIdentifier {
                directAttemptStates.removeValue(forKey: item.id)
            }
            item.taskIdentifier = nil
            let recoverableBytes: Int64?
            switch coordinator.recoveryLookup(
                id: item.id,
                sourceURL: item.sourceURL
            ) {
            case let .available(recovery):
                recoverableBytes = recovery.bytesWritten
            case .absent:
                recoverableBytes = nil
            case .unavailable:
                recoverableBytes = item.bytesWritten > 0 ? item.bytesWritten : nil
            }
            handleDirectDownloadFailure(
                DirectDownloadFailure(
                    error: error,
                    resumeData: item.resumeData,
                    recoverableBytes: recoverableBytes
                ),
                for: item
            )
            return
        }
        item.startedAt = item.startedAt ?? .now
        item.updatedAt = .now
        schedulePersist()
    }

    private func scheduleMediaCleanup(id: UUID) {
        // Retire the process attempt before cancellation can enqueue any more
        // events. A later retry receives a different identifier.
        activeMediaAttemptIdentifiers.removeValue(forKey: id)

        pendingMediaCleanupIDs.insert(id)
        guard mediaCleanupTasks[id] == nil else {
            return
        }

        pendingMediaResumeIDs.remove(id)
        let pendingStart = mediaStartTasks[id]
        let pendingPause = mediaPauseTasks[id]
        pendingStart?.cancel()
        mediaCleanupTasks[id] = Task {
            @MainActor [weak self, mediaService, mediaCleanupOperation, pendingStart, pendingPause] in
            await pendingStart?.value
            await pendingPause?.value
            guard let self else {
                return
            }

            if let item = self.item(for: id), item.requiresMediaRecoveryReset {
                do {
                    // The barrier and any operation that made recovery unsafe
                    // must be durable before cleanup removes the old files.
                    try await self.saveRecordsNow()
                } catch {
                    self.mediaCleanupTasks.removeValue(forKey: id)
                    item.lastError = error.localizedDescription
                    item.updatedAt = .now
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Save Media Cleanup"),
                        message: error.localizedDescription
                    )
                    self.startNextQueuedDownloadsIfNeeded()
                    return
                }
            }

            var cleanupError: Error?
            if let mediaService {
                do {
                    try await mediaCleanupOperation(mediaService, id)
                } catch {
                    cleanupError = error
                }
            }
            if let cleanupError {
                self.mediaCleanupTasks.removeValue(forKey: id)
                self.activeAlert = UserAlert(
                    title: String(localized: "Media Cleanup Pending"),
                    message: cleanupError.localizedDescription
                )
                self.startNextQueuedDownloadsIfNeeded()
                return
            }

            if let item = self.item(for: id), item.requiresMediaRecoveryReset {
                var clearPersistenceError: Error?
                await self.performSerializedDurableMutation { [weak self, weak item] in
                    guard let self,
                          let item,
                          self.item(for: id) === item,
                          item.requiresMediaRecoveryReset else {
                        return
                    }
                    item.requiresMediaRecoveryReset = false
                    item.backendIdentifier = nil
                    item.bytesWritten = 0
                    item.expectedBytes = 0
                    item.progress = 0
                    item.updatedAt = .now
                    do {
                        try await self.saveRecordsNow()
                    } catch {
                        // Cleanup is idempotent, so an unsaved clear is handled
                        // by retaining the barrier and repeating cleanup later.
                        item.requiresMediaRecoveryReset = true
                        item.lastError = error.localizedDescription
                        item.updatedAt = .now
                        clearPersistenceError = error
                    }
                }
                if let clearPersistenceError {
                    self.mediaCleanupTasks.removeValue(forKey: id)
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Save Media Cleanup"),
                        message: clearPersistenceError.localizedDescription
                    )
                    self.startNextQueuedDownloadsIfNeeded()
                    return
                }
            }

            self.mediaCleanupTasks.removeValue(forKey: id)
            self.pendingMediaCleanupIDs.remove(id)
            self.pendingMediaRecoveryResets.remove(id)
            let shouldRetry = self.pendingMediaRetryAfterCleanupIDs.remove(id) != nil
            let shouldStart = self.pendingMediaStartAfterCleanupIDs.remove(id) != nil
            if shouldRetry,
               self.isShuttingDown == false,
               let item = self.item(for: id),
               item.status == .failed || item.status == .cancelled {
                self.retryDownload(id: id)
            } else if shouldStart,
                      self.isShuttingDown == false,
                      self.item(for: id) != nil {
                self.startOrQueueDownload(id: id)
            } else {
                self.startNextQueuedDownloadsIfNeeded()
            }
        }
    }

    private func handleDirectDownloadFailure(
        _ failure: DirectDownloadFailure,
        for item: DownloadItem
    ) {
        let hadReportedProgress = item.bytesWritten > 0
        item.taskIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        if let recoverableBytes = failure.recoverableBytes {
            item.resumeData = nil
            item.bytesWritten = recoverableBytes
            if item.expectedBytes > 0 {
                item.progress = min(
                    Double(recoverableBytes) / Double(item.expectedBytes),
                    1
                )
            } else if recoverableBytes == 0 {
                item.progress = 0
            }
        } else if failure.resumeData == nil {
            // A byte count without either Apple resume data or a validated
            // owned partial is historical transfer telemetry, not recoverable
            // progress. Do not persist or display it as though Retry could use
            // those bytes.
            item.bytesWritten = 0
            item.expectedBytes = 0
            item.progress = 0
        }

        let nextAttempt = (directRetryAttempts[item.id] ?? 0) + 1
        if failure.isRetryable,
           let delay = DirectDownloadRetryPolicy.delay(forAttempt: nextAttempt),
           isShuttingDown == false {
            directRetryAttempts[item.id] = nextAttempt
            if failure.recoverableBytes != nil {
                item.resumeData = nil
            } else if failure.wasResuming, failure.resumeData == nil {
                item.resumeData = nil
            } else {
                item.resumeData = failure.resumeData
            }
            item.lastError = directRetryMessage(
                for: failure,
                delay: delay,
                attempt: nextAttempt,
                hadProgress: hadReportedProgress
            )
            setStatus(for: item, to: .waitingToRetry)

            directRetryTasks[item.id]?.cancel()
            directRetryTasks[item.id] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard let self,
                      self.isShuttingDown == false,
                      let retryItem = self.item(for: item.id),
                      retryItem.status == .waitingToRetry,
                      retryItem.taskIdentifier == nil else {
                    return
                }

                self.directRetryTasks.removeValue(forKey: item.id)
                self.readyDirectRetries[item.id] = failure.requiresFreshStart
                self.startNextQueuedDownloadsIfNeeded()
            }
            startNextQueuedDownloadsIfNeeded()
            return
        }

        let attempts = directRetryAttempts[item.id] ?? 0
        resetDirectRetryState(for: item.id)
        item.resumeData = failure.recoverableBytes == nil ? failure.resumeData : nil
        let finalError: String
        if failure.isRetryable, attempts == DirectDownloadRetryPolicy.delays.count {
            finalError = String(
                format: String(
                    localized: "download.direct.retryExhausted",
                    defaultValue: "%@ Harbor retried this download %lld times.",
                    comment: "Direct-download error after all automatic retries. Parameters are the backend error and retry count."
                ),
                failure.message,
                Int64(attempts)
            )
        } else {
            finalError = failure.message
        }

        if failure.resumeData == nil,
           (failure.recoverableBytes ?? 0) == 0,
           hadReportedProgress {
            item.lastError = String(
                format: String(
                    localized: "download.direct.failureWithoutResumeData",
                    defaultValue: "%@ Downloaded progress could not be preserved; Retry will start from the beginning.",
                    comment: "Final direct-download error when URLSession produced no resumable state. Parameter is the backend error."
                ),
                finalError
            )
        } else {
            item.lastError = finalError
        }
        transitionStatus(for: item, to: .failed)
        startNextQueuedDownloadsIfNeeded()
    }

    private func directRetryMessage(
        for failure: DirectDownloadFailure,
        delay: Duration,
        attempt: Int,
        hadProgress: Bool
    ) -> String {
        let delaySeconds = delay.components.seconds
        let maximumAttempts = DirectDownloadRetryPolicy.delays.count

        if failure.wasResuming,
           failure.resumeData == nil,
           failure.recoverableBytes == nil {
            return String(
                format: String(
                    localized: "download.direct.retryCannotResume",
                    defaultValue: "The server rejected the saved resume state. Retrying from the beginning in %lld seconds (%lld of %lld).",
                    comment: "Direct-download retry message. Parameters are wait seconds, current retry number, and maximum retries."
                ),
                delaySeconds,
                Int64(attempt),
                Int64(maximumAttempts)
            )
        }

        if failure.resumeData == nil,
           (failure.recoverableBytes ?? 0) == 0,
           hadProgress {
            return String(
                format: String(
                    localized: "download.direct.retryWithoutResumeData",
                    defaultValue: "The connection was interrupted and URLSession did not provide resumable state. Retrying from the beginning in %lld seconds (%lld of %lld).",
                    comment: "Direct-download retry message. Parameters are wait seconds, current retry number, and maximum retries."
                ),
                delaySeconds,
                Int64(attempt),
                Int64(maximumAttempts)
            )
        }

        return String(
            format: String(
                localized: "download.direct.retryScheduled",
                defaultValue: "The connection was interrupted. Retrying in %lld seconds (%lld of %lld).",
                comment: "Direct-download retry message. Parameters are wait seconds, current retry number, and maximum retries."
            ),
            delaySeconds,
            Int64(attempt),
            Int64(maximumAttempts)
        )
    }

    private func directRecoveryResetMessage(
        for reason: DirectDownloadRecoveryResetReason
    ) -> String {
        switch reason {
        case .missingValidator:
            String(
                localized: "download.direct.recoveryReset.missingValidator",
                defaultValue: "The server did not provide a validator for the partial file, so Harbor restarted the download to avoid combining different content.",
                comment: "Direct-download status shown when a partial file cannot be safely resumed without an HTTP validator."
            )
        case .sourceChanged:
            String(
                localized: "download.direct.recoveryReset.sourceChanged",
                defaultValue: "The download source changed, so Harbor restarted the partial download.",
                comment: "Direct-download status shown when persisted partial data belongs to another source URL."
            )
        case .invalidLength:
            String(
                localized: "download.direct.recoveryReset.invalidLength",
                defaultValue: "The saved partial file was larger than the expected download, so Harbor restarted it.",
                comment: "Direct-download status shown when persisted partial data is longer than the declared resource."
            )
        case .serverRejectedRange:
            String(
                localized: "download.direct.recoveryReset.serverRejectedRange",
                defaultValue: "The server could not continue the saved partial file, so Harbor restarted the download.",
                comment: "Direct-download status shown when the server responds to a validated range request with the full resource."
            )
        }
    }

    private func resetDirectRetryState(for id: UUID) {
        directRetryTasks.removeValue(forKey: id)?.cancel()
        directRetryAttempts.removeValue(forKey: id)
        readyDirectRetries.removeValue(forKey: id)
    }

    private func startMediaDownload(
        id: UUID,
        attemptIdentifier: UUID
    ) async {
        var waitsForMediaStopEvent = false
        var keepsAttemptActive = false

        defer {
            mediaStartTasks.removeValue(forKey: id)
            if keepsAttemptActive == false,
               activeMediaAttemptIdentifiers[id] == attemptIdentifier {
                activeMediaAttemptIdentifiers.removeValue(forKey: id)
            }

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

            if pendingMediaRecoveryResets.contains(id)
                || readyItem.requiresMediaRecoveryReset {
                if readyItem.requiresMediaRecoveryReset {
                    try await saveRecordsNow()
                }
                try await mediaCleanupOperation(mediaService, id)
                pendingMediaRecoveryResets.remove(id)

                guard let refreshedItem = item(for: id),
                      refreshedItem.status == .preparing else {
                    return
                }
                var didPersistClear = false
                var clearPersistenceError: Error?
                await performSerializedDurableMutation { [weak self, weak refreshedItem] in
                    guard let self,
                          let refreshedItem,
                          self.item(for: id) === refreshedItem,
                          refreshedItem.status == .preparing else {
                        return
                    }
                    refreshedItem.requiresMediaRecoveryReset = false
                    refreshedItem.bytesWritten = 0
                    refreshedItem.expectedBytes = 0
                    refreshedItem.progress = 0
                    refreshedItem.updatedAt = .now
                    do {
                        try await self.saveRecordsNow()
                        didPersistClear = true
                    } catch {
                        refreshedItem.requiresMediaRecoveryReset = true
                        clearPersistenceError = error
                    }
                }
                if let clearPersistenceError {
                    throw clearPersistenceError
                }
                guard didPersistClear else {
                    return
                }
            }

            let processIdentifier = try await mediaService.startDownload(
                id: readyItem.id,
                attemptIdentifier: attemptIdentifier,
                sourceURL: readyItem.sourceURL,
                destinationFolder: readyItem.destinationFolderURL,
                metadata: validatedMetadata,
                formatPreference: requestedFormat,
                speedLimitBytesPerSecond: effectiveMediaDownloadLimit(for: readyItem)
            )

            guard let refreshedItem = item(for: id) else {
                waitsForMediaStopEvent = await mediaService.pause(id: id)
                keepsAttemptActive = waitsForMediaStopEvent
                return
            }

            guard refreshedItem.status == .preparing || refreshedItem.status == .downloading else {
                if refreshedItem.status == .cancelled {
                    waitsForMediaStopEvent = await mediaService.cancel(id: id)
                } else {
                    waitsForMediaStopEvent = await mediaService.pause(id: id)
                }
                keepsAttemptActive = waitsForMediaStopEvent
                if waitsForMediaStopEvent == false,
                   let outcome = await mediaService.terminalOutcome(id: id),
                   outcome.attemptIdentifier == attemptIdentifier,
                   activeMediaAttemptIdentifiers[id] == attemptIdentifier {
                    // The child can finish between startDownload returning and
                    // a concurrent Pause changing the model. Its durable
                    // terminal manifest then outlives the process, so consume
                    // that exact attempt before the start task retires token
                    // ownership.
                    handle(outcome.event, attemptIdentifier: attemptIdentifier)
                    if let completionTask = completionTasks[id] {
                        await completionTask.value
                    }
                }
                return
            }

            keepsAttemptActive = true
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
            if pendingTorrentPauseIDs.remove(id) != nil,
               let item = item(for: id),
               item.status.isTerminal == false {
                pauseDownload(id: id)
            } else {
                startNextQueuedDownloadsIfNeeded()
            }
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
                    // Persist the owner record before the reservation store
                    // permits a new non-idempotent add. A crash after aria2
                    // commits can then reattach that reservation to this ID.
                    try await saveRecordsNow()
                    let replacementIdentifier = try await torrentStartOperation(
                        torrentService,
                        id,
                        refreshedItem.sourceKind,
                        torrentEngineSourceURL(for: refreshedItem),
                        refreshedItem.destinationFolderPath,
                        torrentTransferOptions(for: refreshedItem)
                    )

                    guard item(for: id) != nil else {
                        try? await torrentService.discardPendingSubmission(
                            ownerDownloadID: id
                        )
                        return
                    }

                    activeBackendIdentifier = replacementIdentifier
                }
            } else {
                // The preparing record must predate the durable submission
                // reservation and RPC side effect.
                try await saveRecordsNow()
                let backendIdentifier = try await torrentStartOperation(
                    torrentService,
                    id,
                    currentItem.sourceKind,
                    torrentEngineSourceURL(for: currentItem),
                    currentItem.destinationFolderPath,
                    torrentTransferOptions(for: currentItem)
                )
                guard item(for: id) != nil else {
                    try? await torrentService.discardPendingSubmission(
                        ownerDownloadID: id
                    )
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
            do {
                try await saveRecordsNow()
                try await torrentService.acknowledgeSubmission(
                    ownerDownloadID: id,
                    gid: activeBackendIdentifier
                )
            } catch {
                // Keep both the active GID and its durable reservation. A
                // retry/relaunch can reconcile the same transfer without
                // submitting a duplicate add request.
                refreshedItem.lastError = error.localizedDescription
                refreshedItem.updatedAt = .now
                activeAlert = UserAlert(
                    title: String(localized: "Torrent Started; Ownership Save Pending"),
                    message: error.localizedDescription
                )
                schedulePersist()
            }
        } catch {
            guard let refreshedItem = item(for: id) else {
                if let uncertain = error as? TorrentSubmissionUncertainError {
                    try? await torrentService.removeAndConfirmStopped(gid: uncertain.gid)
                }
                return
            }

            if let uncertain = error as? TorrentUnpauseUncertainError {
                reflectActiveTorrentAfterUnpauseUncertainty(
                    refreshedItem,
                    error: uncertain
                )
                schedulePersist()
                return
            }

            if let uncertain = error as? TorrentSubmissionUncertainError {
                refreshedItem.backendIdentifier = uncertain.gid
                setStatus(
                    for: refreshedItem,
                    to: refreshedItem.finishedAt == nil ? .downloading : .seeding
                )
                refreshedItem.speedBytesPerSecond = 0
                refreshedItem.uploadBytesPerSecond = 0
                refreshedItem.updatedAt = .now
                refreshedItem.lastError = uncertain.localizedDescription
                if isShuttingDown == false {
                    activeAlert = UserAlert(
                        title: String(localized: "Torrent Ownership Verification Pending"),
                        message: uncertain.localizedDescription
                    )
                }
                do {
                    try await saveRecordsNow()
                } catch {
                    // The reservation remains authoritative if this record
                    // snapshot cannot be saved. Startup reconciliation will
                    // adopt the same GID before orphan deletion.
                    activeAlert = UserAlert(
                        title: String(localized: "Torrent Started; Ownership Save Pending"),
                        message: error.localizedDescription
                    )
                    schedulePersist()
                }
                return
            }

            guard isShuttingDown == false,
                  (refreshedItem.status == .preparing || refreshedItem.status == .seeding) else {
                return
            }

            if hadBackendIdentifier, isTransientTorrentEngineError(error) {
                // A failed status lookup is not proof that an existing aria2
                // transfer is paused. Keep its slot occupied until a later
                // refresh confirms a non-writing state.
                reflectActiveTorrentAfterUnpauseUncertainty(
                    refreshedItem,
                    error: error
                )
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
            do {
                try await torrentPauseOperation(torrentService, backendIdentifier)
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
            } catch {
                reflectActiveTorrentAfterPauseFailure(item, error: error)
            }
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

        case .queued, .preparing, .waitingToRetry, .downloading, .seeding:
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

    private func reflectActiveTorrentAfterPauseFailure(
        _ item: DownloadItem,
        snapshot: TorrentStatusSnapshot? = nil,
        error: Error
    ) {
        // The backend is authoritative here: if Harbor could not confirm the
        // pause, the record must continue consuming an active slot instead of
        // presenting a paused transfer while aria2 keeps writing in the
        // background.
        let isCompletedPayload = item.finishedAt != nil || snapshot?.isSeeder == true
        setStatus(for: item, to: isCompletedPayload ? .seeding : .downloading)
        if let snapshot {
            item.bytesWritten = snapshot.completedLength
            item.expectedBytes = max(snapshot.totalLength, 0)
            item.progress = snapshot.totalLength > 0
                ? min(Double(snapshot.completedLength) / Double(snapshot.totalLength), 1)
                : item.progress
            item.speedBytesPerSecond = snapshot.downloadSpeed
            item.uploadBytesPerSecond = snapshot.uploadSpeed
        }
        item.lastError = error.localizedDescription
        item.updatedAt = .now
        activeAlert = UserAlert(
            title: String(localized: "Couldn’t Pause Torrent"),
            message: error.localizedDescription
        )
    }

    private func reflectActiveTorrentAfterUnpauseUncertainty(
        _ item: DownloadItem,
        error: Error
    ) {
        // The unpause request may have committed even though its response was
        // lost. Keep the item slot-occupying until refresh proves otherwise;
        // declaring it paused could start another transfer concurrently.
        setStatus(for: item, to: item.finishedAt == nil ? .downloading : .seeding)
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.lastError = error.localizedDescription
        item.updatedAt = .now
        if isShuttingDown == false {
            activeAlert = UserAlert(
                title: String(localized: "Couldn’t Confirm Torrent Resume"),
                message: error.localizedDescription
            )
        }
    }

    private func torrentEngineSourceURL(for item: DownloadItem) -> URL {
        guard let managedTorrentSourcePath = item.managedTorrentSourcePath else {
            return item.sourceURL
        }

        return URL(fileURLWithPath: managedTorrentSourcePath)
    }

    private func pauseDownload(id: UUID) {
        guard let item = item(for: id),
              completionTasks[id] == nil else {
            return
        }

        if item.status == .seeding, item.finishedAt != nil {
            stopSeeding(id: id)
            return
        }

        if item.backend == .aria2, torrentStartTasks[id] != nil {
            pendingTorrentPauseIDs.insert(id)
            return
        }

        if item.backend == .aria2, torrentPauseTasks[id] != nil {
            setStatus(for: item, to: .paused)
            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            schedulePersist()
            return
        }

        let shouldWaitForMediaProcess = item.backend == .ytDlp
            && (item.backendIdentifier != nil || mediaStartTasks[id] != nil)

        if item.backend == .ytDlp, mediaPauseTasks[id] != nil {
            return
        }

        if item.backend == .urlSession {
            guard directPauseTasks[id] == nil else {
                return
            }

            resetDirectRetryState(for: id)
            if browserCoordinator.hasPendingOrActiveAttempt(id: id) {
                beginDirectPause(id: id, usesBrowser: true)
                return
            }
            if item.taskIdentifier != nil {
                beginDirectPause(id: id, usesBrowser: false)
                return
            }
        }

        setStatus(for: item, to: .paused)
        item.taskIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            break
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                let torrentPauseOperation = torrentPauseOperation
                let task = Task {
                    @MainActor [weak self, torrentService, torrentPauseOperation] in
                    guard let self else {
                        return
                    }
                    do {
                        try await torrentPauseOperation(torrentService, backendIdentifier)
                    } catch {
                        if let current = self.item(for: id),
                           current === item,
                           current.backendIdentifier == backendIdentifier,
                           current.status == .paused {
                            self.reflectActiveTorrentAfterPauseFailure(
                                current,
                                error: error
                            )
                        }
                    }
                    self.torrentPauseTasks.removeValue(forKey: id)
                    self.schedulePersist()
                    self.startNextQueuedDownloadsIfNeeded()
                }
                torrentPauseTasks[id] = task
            }
        case .ytDlp:
            if shouldWaitForMediaProcess {
                let pendingStart = mediaStartTasks[id]
                let mediaAttemptIdentifier = activeMediaAttemptIdentifiers[id]
                pendingStart?.cancel()
                let pauseTask = Task {
                    @MainActor [weak self, mediaService, mediaPauseOperation, pendingStart] in
                    await pendingStart?.value
                    if let mediaService {
                        await mediaPauseOperation(mediaService, id)
                    }

                    guard let self else {
                        return
                    }
                    if let mediaAttemptIdentifier,
                       let outcome = await mediaService?.terminalOutcome(id: id),
                       outcome.attemptIdentifier == mediaAttemptIdentifier,
                       self.activeMediaAttemptIdentifiers[id] == mediaAttemptIdentifier {
                        self.handle(
                            outcome.event,
                            attemptIdentifier: mediaAttemptIdentifier
                        )
                        if let completionTask = self.completionTasks[id] {
                            await completionTask.value
                        }
                    }
                    self.mediaPauseTasks.removeValue(forKey: id)
                    let shouldResume = self.pendingMediaResumeIDs.remove(id) != nil
                    if shouldResume,
                       self.isShuttingDown == false,
                       let pausedItem = self.item(for: id),
                       pausedItem.status == .paused {
                        self.startOrQueueDownload(id: id)
                    } else {
                        self.startNextQueuedDownloadsIfNeeded()
                    }
                }
                mediaPauseTasks[id] = pauseTask
            }
        }

        schedulePersist()
        if shouldWaitForMediaProcess == false {
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private func beginDirectPause(id: UUID, usesBrowser: Bool) {
        guard case let .active(attemptIdentifier) = directAttemptStates[id] else {
            return
        }
        directAttemptStates[id] = .pausing(attemptIdentifier)
        let directCoordinator = coordinator!
        let secureBrowserCoordinator = browserCoordinator!
        let directPauseOperation = directPauseOperation
        let pauseTask = Task {
            @MainActor [weak self, directCoordinator, secureBrowserCoordinator, directPauseOperation] in
            let browserResult: BrowserDownloadQuiescence?
            let directResult: DirectDownloadPauseResult?
            if usesBrowser {
                browserResult = await secureBrowserCoordinator.quiesceDownload(id: id)
                directResult = nil
            } else {
                browserResult = nil
                directResult = await directPauseOperation(directCoordinator, id)
            }

            guard let self else {
                return
            }
            self.directPauseTasks.removeValue(forKey: id)
            self.browserReservedIDs.remove(id)

            guard let item = self.item(for: id),
                  self.directAttemptStates[id]?.identifier == attemptIdentifier else {
                self.startNextQueuedDownloadsIfNeeded()
                return
            }

            if let browserResult,
               browserResult.attemptIdentifier == attemptIdentifier {
                self.completedDirectPauseResults[id] = .browser(browserResult)
            } else if let directResult,
                      directResult.attemptIdentifier == attemptIdentifier {
                self.completedDirectPauseResults[id] = .direct(directResult)
            }
            defer {
                if case .cancelling = self.directAttemptStates[id] {
                    // Cancel/Remove is waiting for this task and consumes the
                    // exact quiescence result before attempting its durable
                    // transaction. Preserve it until that waiter resumes.
                } else {
                    self.completedDirectPauseResults.removeValue(forKey: id)
                }
            }

            await self.reconcileCompletionAfterQuiescence(
                for: item,
                attemptIdentifier: attemptIdentifier
            )
            if let completionTask = self.completionTasks[id] {
                await completionTask.value
            }
            guard self.item(for: id) === item,
                  item.status != .completed,
                  self.directAttemptStates[id]?.identifier == attemptIdentifier else {
                self.startNextQueuedDownloadsIfNeeded()
                return
            }

            guard case .pausing = self.directAttemptStates[id] else {
                // Completion or cancellation won while the backend was being
                // quiesced. Its journal/recovery state is authoritative; a
                // stale pause result must not rewrite or delete it.
                self.startNextQueuedDownloadsIfNeeded()
                return
            }

            if let message = browserResult?.writerQuiescenceUnavailableMessage {
                self.directAttemptStates[id] = .active(attemptIdentifier)
                self.pendingDirectPauseFailures.removeValue(forKey: id)
                self.setStatus(for: item, to: .downloading)
                item.lastError = message
                item.updatedAt = .now
                self.schedulePersist()
                return
            }
            if let message = browserResult?.completionUnavailableMessage {
                self.directAttemptStates.removeValue(forKey: id)
                self.pendingDirectPauseFailures.removeValue(forKey: id)
                item.taskIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.lastError = self.completedHandoffUnavailableMessage(message)
                item.updatedAt = .now
                self.setStatus(for: item, to: .failed)
                self.schedulePersist()
                self.startNextQueuedDownloadsIfNeeded()
                return
            }
            if let message = directResult?.recoveryUnavailableMessage {
                self.storeURLSessionPauseResult(directResult!, for: item)
                self.directAttemptStates.removeValue(forKey: id)
                self.pendingDirectPauseFailures.removeValue(forKey: id)
                item.taskIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.lastError = self.directRecoveryUnavailableMessage(message)
                item.updatedAt = .now
                self.setStatus(for: item, to: .failed)
                self.schedulePersist()
                self.startNextQueuedDownloadsIfNeeded()
                return
            }

            var didStoreRecovery = false
            if let browserResult,
               browserResult.attemptIdentifier == attemptIdentifier,
               browserResult.resumeData != nil {
                self.storeBrowserPauseResult(browserResult.resumeData, for: item)
                didStoreRecovery = true
            } else if let directResult,
                      directResult.attemptIdentifier == attemptIdentifier,
                      directResult.resumeData != nil
                        || directResult.ownedRecovery != nil
                        || directResult.recoveryUnavailableMessage != nil {
                self.storeURLSessionPauseResult(directResult, for: item)
                didStoreRecovery = true
            }

            if didStoreRecovery == false,
               let pendingFailure = self.pendingDirectPauseFailures.removeValue(forKey: id) {
                self.storePendingPauseFailure(pendingFailure, for: item)
                didStoreRecovery = true
            }
            if didStoreRecovery == false {
                if usesBrowser {
                    self.storeBrowserPauseResult(nil, for: item)
                } else {
                    self.storeURLSessionPauseResult(
                        DirectDownloadPauseResult(
                            attemptIdentifier: attemptIdentifier,
                            resumeData: nil,
                            ownedRecovery: nil
                        ),
                        for: item
                    )
                }
            }
            item.taskIdentifier = nil

            switch self.directAttemptStates[id] {
            case .terminal, .cancelling:
                return
            case .pausing:
                break
            case .active, nil:
                return
            }

            self.directAttemptStates.removeValue(forKey: id)
            self.pendingDirectPauseFailures.removeValue(forKey: id)
            self.completedDirectPauseResults.removeValue(forKey: id)
            self.setStatus(for: item, to: .paused)
            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            self.schedulePersist()
            self.startNextQueuedDownloadsIfNeeded()
        }
        directPauseTasks[id] = pauseTask
    }

    private func storeBrowserPauseResult(
        _ resumeData: Data?,
        for item: DownloadItem
    ) {
        item.browserResumeData = resumeData

        guard resumeData == nil else {
            return
        }

        let discardedProgress = item.bytesWritten > 0
        item.bytesWritten = 0
        item.expectedBytes = 0
        item.progress = 0
        guard discardedProgress else {
            return
        }

        item.lastError = String(
            localized: "download.direct.pauseWithoutResumeData",
            defaultValue: "This download could not preserve resumable progress. Resuming will restart it from the beginning.",
            comment: "Paused direct-download message shown when the backend produced no resumable state."
        )
    }

    private func storeURLSessionPauseResult(
        _ result: DirectDownloadPauseResult,
        for item: DownloadItem
    ) {
        item.resumeData = result.resumeData

        if let message = result.recoveryUnavailableMessage {
            item.resumeData = nil
            item.lastError = directRecoveryUnavailableMessage(message)
            return
        }

        if let recovery = result.ownedRecovery {
            item.resumeData = nil
            item.bytesWritten = recovery.bytesWritten
            item.expectedBytes = recovery.metadata.expectedBytes
            if item.expectedBytes > 0 {
                item.progress = min(
                    Double(item.bytesWritten) / Double(item.expectedBytes),
                    1
                )
            }
            return
        }

        guard result.resumeData == nil else {
            return
        }

        let discardedProgress = item.bytesWritten > 0
        item.bytesWritten = 0
        item.expectedBytes = 0
        item.progress = 0
        guard discardedProgress else {
            return
        }

        item.lastError = String(
            localized: "download.direct.pauseWithoutResumeData",
            defaultValue: "This download could not preserve resumable progress. Resuming will restart it from the beginning.",
            comment: "Paused direct-download message shown when the backend produced no resumable state."
        )
    }

    private func storePendingPauseFailure(
        _ pendingFailure: PendingDirectPauseFailure,
        for item: DownloadItem
    ) {
        switch pendingFailure {
        case let .browser(failure):
            storeBrowserPauseResult(failure.resumeData, for: item)
            item.lastError = failure.message

        case let .direct(failure):
            let recoveryLookup = coordinator.recoveryLookup(
                id: item.id,
                sourceURL: item.sourceURL
            )
            let ownedRecovery: DirectDownloadRecoverySnapshot?
            let unavailableMessage: String?
            switch recoveryLookup {
            case let .available(recovery):
                ownedRecovery = recovery
                unavailableMessage = nil
            case .absent:
                ownedRecovery = nil
                unavailableMessage = nil
            case let .unavailable(message):
                ownedRecovery = nil
                unavailableMessage = message
            }
            storeURLSessionPauseResult(
                DirectDownloadPauseResult(
                    attemptIdentifier: directAttemptStates[item.id]?.identifier,
                    resumeData: ownedRecovery == nil && unavailableMessage == nil
                        ? failure.resumeData
                        : nil,
                    ownedRecovery: ownedRecovery,
                    recoveryUnavailableMessage: unavailableMessage
                ),
                for: item
            )
            if let resumeData = failure.resumeData,
               ownedRecovery == nil,
               unavailableMessage == nil,
               let bytesWritten = DownloadCoordinator.legacyResumeByteCount(from: resumeData) {
                item.bytesWritten = bytesWritten
                item.expectedBytes = max(item.expectedBytes, bytesWritten)
                item.progress = item.expectedBytes > 0
                    ? min(Double(bytesWritten) / Double(item.expectedBytes), 1)
                    : 0
            }
            item.lastError = unavailableMessage.map(directRecoveryUnavailableMessage)
                ?? failure.message
        }
    }

    private var currentRunningDownloadsCount: Int {
        occupiedDownloadIDs.count
    }

    private var occupiedDownloadIDs: Set<UUID> {
        var ids = Set(
            downloads.lazy
                .filter { $0.status.consumesDownloadSlot }
                .map(\.id)
        )
        ids.formUnion(browserReservedIDs)
        ids.formUnion(pendingBrowserContinuationIDs)
        ids.formUnion(browserCancellationTasks.keys)
        ids.formUnion(mediaStartTasks.keys)
        ids.formUnion(torrentStartTasks.keys)
        ids.formUnion(directPauseTasks.keys)
        ids.formUnion(mediaPauseTasks.keys)
        ids.formUnion(torrentPauseTasks.keys)
        ids.formUnion(mediaCleanupTasks.keys)
        ids.formUnion(completionTasks.keys)
        ids.formUnion(cancellationTasks.keys)
        ids.formUnion(removalTasks.keys)
        return ids
    }

    private func startNextQueuedDownloadsIfNeeded() {
        guard isShuttingDown == false else {
            return
        }

        guard isDrainingDownloadQueue == false else {
            return
        }
        isDrainingDownloadQueue = true
        defer { isDrainingDownloadQueue = false }

        let concurrencyLimit = settings.transferSettings.maxConcurrentDownloads
        guard currentRunningDownloadsCount < concurrencyLimit else {
            return
        }

        let schedulableItems = downloads
            .filter {
                cancellationTasks[$0.id] == nil
                    && removalTasks[$0.id] == nil
                    && (
                        $0.status == .queued
                            || ($0.status == .waitingToRetry && readyDirectRetries[$0.id] != nil)
                    )
            }
            .sorted { $0.createdAt < $1.createdAt }

        for item in schedulableItems {
            guard currentRunningDownloadsCount < concurrencyLimit else {
                break
            }

            // A synchronous start failure can re-enter this scheduler and
            // process later items from the same snapshot. Only start entries
            // that are still schedulable when the outer pass resumes.
            if item.status == .waitingToRetry,
               let restartingFromBeginning = readyDirectRetries.removeValue(forKey: item.id) {
                startDirectDownload(
                    item,
                    restartingFromBeginning: restartingFromBeginning
                )
            } else if item.status == .queued {
                startOrQueueDownload(id: item.id)
            } else {
                continue
            }
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
                  torrentStartTasks[item.id] == nil,
                  torrentPauseTasks[item.id] == nil,
                  torrentStopSeedingTasks[item.id] == nil,
                  cancellationTasks[item.id] == nil,
                  removalTasks[item.id] == nil else {
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
                      torrentPauseTasks[item.id] == nil,
                      torrentStopSeedingTasks[item.id] == nil,
                      cancellationTasks[item.id] == nil,
                      removalTasks[item.id] == nil,
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
                      torrentPauseTasks[item.id] == nil,
                      torrentStopSeedingTasks[item.id] == nil,
                      cancellationTasks[item.id] == nil,
                      removalTasks[item.id] == nil,
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
            let id = item.id
            guard torrentPauseTasks[id] == nil,
                  let backendIdentifier = item.backendIdentifier else {
                return
            }
            let lifecycleVersion = item.updatedAt
            let torrentPauseOperation = torrentPauseOperation
            torrentPauseTasks[id] = Task {
                @MainActor [weak self, weak item, torrentService, torrentPauseOperation] in
                do {
                    try await torrentPauseOperation(torrentService, lineage.rootGID)
                    guard let self,
                          let item,
                          self.item(for: id) === item,
                          item.backendIdentifier == backendIdentifier,
                          item.status == .paused,
                          item.updatedAt == lifecycleVersion else {
                        self?.torrentPauseTasks.removeValue(forKey: id)
                        self?.startNextQueuedDownloadsIfNeeded()
                        return
                    }
                    item.speedBytesPerSecond = 0
                    item.uploadBytesPerSecond = 0
                    item.updatedAt = .now
                    self.torrentPauseTasks.removeValue(forKey: id)
                    self.schedulePersist()
                    self.startNextQueuedDownloadsIfNeeded()
                } catch {
                    guard let self else {
                        return
                    }
                    self.torrentPauseTasks.removeValue(forKey: id)
                    if let item,
                       self.item(for: id) === item,
                       item.backendIdentifier == backendIdentifier,
                       item.status == .paused,
                       item.updatedAt == lifecycleVersion {
                        self.reflectActiveTorrentAfterPauseFailure(
                            item,
                            snapshot: snapshot,
                            error: error
                        )
                        self.schedulePersist()
                    }
                    self.startNextQueuedDownloadsIfNeeded()
                }
            }
            return
        }

        item.bytesWritten = snapshot.completedLength
        item.expectedBytes = max(snapshot.totalLength, 0)
        if snapshot.totalLength > 0 {
            item.progress = Double(snapshot.completedLength) / Double(snapshot.totalLength)
        }
        item.speedBytesPerSecond = snapshot.downloadSpeed
        item.uploadBytesPerSecond = snapshot.uploadSpeed
        item.metadataName = snapshot.metadataName ?? item.metadataName
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
            if item.finishedAt != nil {
                item.shouldSeedAfterDownload = false
                setStatus(for: item, to: .completed)
            } else {
                transitionStatus(for: item, to: .failed)
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
        let id = item.id
        var didPersistCompletion = false
        var shouldNotify = false
        await performSerializedDurableMutation { [weak self, weak item] in
            guard let self,
                  let item,
                  self.item(for: id) === item,
                  item.backend == .aria2,
                  item.status != .cancelled,
                  self.removalTasks[id] == nil,
                  self.cancellationTasks[id] == nil else {
                return
            }

            let recordBeforeCompletion = item.makeRecord()
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
                self.setStatus(for: item, to: .seeding)
            } else {
                item.uploadBytesPerSecond = 0
                self.setStatus(for: item, to: .completed)
            }

            shouldNotify = item.completionNotificationDelivered == false
            if shouldNotify {
                item.completionNotificationDelivered = true
            }

            do {
                try await self.saveRecordsNow()
                didPersistCompletion = true
            } catch {
                self.replaceItem(
                    id: id,
                    with: recordBeforeCompletion,
                    reporting: error
                )
                self.activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Save Completed Torrent"),
                    message: error.localizedDescription
                )
            }
        }

        if didPersistCompletion, shouldNotify {
            deliverNotificationIfEnabled(for: item, status: .completed)
        }

        if continuesSeeding == false, didPersistCompletion {
            do {
                try await torrentRemoveOperation(torrentService, gid)
                await performSerializedDurableMutation { [weak self, weak item] in
                    guard let self,
                          let item,
                          self.item(for: item.id) === item else {
                        return
                    }
                    let persistedIdentifier = item.backendIdentifier
                    item.backendIdentifier = nil
                    item.updatedAt = .now
                    do {
                        try await self.saveRecordsNow()
                    } catch {
                        item.backendIdentifier = persistedIdentifier ?? gid
                        item.lastError = error.localizedDescription
                        item.updatedAt = .now
                        self.scheduleOrphanedTorrentCleanup(
                            gid: gid,
                            ownerDownloadID: item.id
                        )
                        self.activeAlert = UserAlert(
                            title: String(localized: "Couldn’t Save Torrent Cleanup"),
                            message: error.localizedDescription
                        )
                    }
                }
            } catch {
                item.backendIdentifier = item.backendIdentifier ?? gid
                item.lastError = error.localizedDescription
                item.updatedAt = .now
                try? await saveRecordsNow()
                scheduleOrphanedTorrentCleanup(
                    gid: gid,
                    ownerDownloadID: item.id
                )
                activeAlert = UserAlert(
                    title: String(localized: "Completed Torrent Cleanup Pending"),
                    message: error.localizedDescription
                )
            }
        }

        startNextQueuedDownloadsIfNeeded()
    }

    func handle(_ event: DownloadEvent) {
        switch event {
        case let .started(
            id,
            attemptIdentifier,
            taskIdentifier,
            usesOwnedPartial,
            ownedRecovery,
            resetReason
        ):
            guard isActiveDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
                  let item = nonterminalItem(for: id) else {
                return
            }

            item.taskIdentifier = taskIdentifier
            setStatus(for: item, to: .downloading)
            if usesOwnedPartial {
                item.bytesWritten = ownedRecovery?.bytesWritten ?? 0
                if let recoveryExpectedBytes = ownedRecovery?.metadata.expectedBytes,
                   recoveryExpectedBytes > 0 {
                    item.expectedBytes = recoveryExpectedBytes
                } else if ownedRecovery == nil {
                    item.expectedBytes = 0
                }
                if item.expectedBytes > 0 {
                    item.progress = min(
                        Double(item.bytesWritten) / Double(item.expectedBytes),
                        1
                    )
                } else if item.bytesWritten == 0 {
                    item.progress = 0
                }
            }
            item.lastError = resetReason.map { directRecoveryResetMessage(for: $0) }
            item.updatedAt = .now
            item.uploadBytesPerSecond = 0

        case let .recoveryReset(id, attemptIdentifier, reason):
            guard isCurrentDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
                  let item = nonterminalItem(for: id) else {
                return
            }

            item.bytesWritten = 0
            item.expectedBytes = 0
            item.progress = 0
            item.lastError = directRecoveryResetMessage(for: reason)
            item.updatedAt = .now

        case let .progress(
            id,
            attemptIdentifier,
            bytesWritten,
            expectedBytes,
            speedBytesPerSecond
        ):
            guard isActiveDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
                  let item = nonterminalItem(for: id) else {
                return
            }

            item.bytesWritten = bytesWritten
            item.expectedBytes = expectedBytes > 0
                ? max(expectedBytes, bytesWritten)
                : 0
            if item.expectedBytes > 0 {
                item.progress = min(
                    Double(bytesWritten) / Double(item.expectedBytes),
                    1
                )
            }
            item.speedBytesPerSecond = speedBytesPerSecond
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

        case let .failed(id, attemptIdentifier, failure):
            guard isCurrentDirectAttempt(id: id, attemptIdentifier: attemptIdentifier) else {
                return
            }
            if case .pausing = directAttemptStates[id] {
                pendingDirectPauseFailures[id] = .direct(failure)
                return
            }
            guard case .active = directAttemptStates[id],
                  let item = nonterminalItem(for: id) else {
                return
            }
            directAttemptStates.removeValue(forKey: id)
            handleDirectDownloadFailure(failure, for: item)
            coordinator.acknowledgeTerminalOutcome(
                id: id,
                attemptIdentifier: attemptIdentifier
            )

        case let .finished(id, attemptIdentifier, handoff):
            beginCompletedHandoff(
                id: id,
                attemptIdentifier: attemptIdentifier,
                handoff: handoff
            )
            return
        }

        schedulePersist()
    }

    func handleBrowserDownloadEvent(_ event: BrowserDownloadEvent) {
        switch event {
        case let .started(
            id,
            attemptIdentifier,
            _,
            expectedBytes,
            _,
            statusCode,
            isResumed
        ):
            guard isActiveDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
                  let item = nonterminalItem(for: id) else {
                return
            }

            browserReservedIDs.remove(id)
            clearActiveBrowserSession(matching: id, attemptIdentifier: attemptIdentifier)
            setStatus(for: item, to: .downloading)
            let continuesPreviousPayload = isResumed && statusCode == 206
            if continuesPreviousPayload == false {
                item.progress = 0
                item.bytesWritten = 0
                item.expectedBytes = 0
            }
            if expectedBytes > 0 {
                item.expectedBytes = expectedBytes
            }
            item.lastError = nil
            item.resumeData = nil
            item.browserResumeData = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            item.startedAt = item.startedAt ?? .now

        case let .finished(id, attemptIdentifier, handoff):
            beginCompletedHandoff(
                id: id,
                attemptIdentifier: attemptIdentifier,
                handoff: handoff
            )
            return

        case let .failed(id, attemptIdentifier, failure):
            guard isCurrentDirectAttempt(id: id, attemptIdentifier: attemptIdentifier) else {
                return
            }
            if pendingBrowserWriterMutations[id] != nil,
               browserCoordinator.hasActiveDownload(id: id) == false {
                _ = resumePendingBrowserWriterMutationIfPossible(id: id)
                return
            }
            if case .pausing = directAttemptStates[id] {
                pendingDirectPauseFailures[id] = .browser(failure)
                return
            }
            guard case .active = directAttemptStates[id],
                  let item = nonterminalItem(for: id) else {
                return
            }

            directAttemptStates.removeValue(forKey: id)
            browserReservedIDs.remove(id)
            clearActiveBrowserSession(matching: id, attemptIdentifier: attemptIdentifier)
            item.lastError = failure.message
            item.browserResumeData = failure.resumeData
            if failure.resumeData == nil {
                item.progress = 0
                item.bytesWritten = 0
                item.expectedBytes = 0
            }
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .failed)
            startNextQueuedDownloadsIfNeeded()

        case let .dismissed(id, attemptIdentifier, resumeData):
            guard isActiveDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
                  let item = nonterminalItem(for: id) else {
                return
            }
            browserReservedIDs.remove(id)
            pendingBrowserContinuationIDs.remove(id)
            clearActiveBrowserSession(matching: id, attemptIdentifier: attemptIdentifier)
            storeBrowserPauseResult(resumeData, for: item)
            directAttemptStates.removeValue(forKey: id)
            markBrowserSessionRequired(
                item,
                message: String(localized: "Open the browser session to continue this download.")
            )
            startNextQueuedDownloadsIfNeeded()

        case let .completionUnavailable(id, attemptIdentifier, message):
            failBrowserCompletionPublication(
                id: id,
                attemptIdentifier: attemptIdentifier,
                message: message
            )
            return

        case let .quiescenceFailed(id, attemptIdentifier, message):
            guard isCurrentDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
                  let item = nonterminalItem(for: id) else {
                return
            }
            browserReservedIDs.remove(id)
            pendingBrowserContinuationIDs.remove(id)
            clearActiveBrowserSession(matching: id, attemptIdentifier: attemptIdentifier)
            directAttemptStates[id] = .active(attemptIdentifier)
            setStatus(for: item, to: .downloading)
            item.lastError = message
            item.updatedAt = .now

        case let .quiescedAfterTimeout(id, attemptIdentifier, resumeData, wasCancelling):
            guard isCurrentDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
                  let item = nonterminalItem(for: id) else {
                return
            }
            if wasCancelling {
                if pendingBrowserWriterMutations[id] != nil {
                    _ = resumePendingBrowserWriterMutationIfPossible(id: id)
                    return
                }
                if case .cancelling = directAttemptStates[id] {
                    return
                }
            }
            browserReservedIDs.remove(id)
            pendingBrowserContinuationIDs.remove(id)
            clearActiveBrowserSession(matching: id, attemptIdentifier: attemptIdentifier)
            storeBrowserPauseResult(resumeData, for: item)
            directAttemptStates.removeValue(forKey: id)
            markBrowserSessionRequired(
                item,
                message: String(localized: "Open the browser session to continue this download.")
            )
            startNextQueuedDownloadsIfNeeded()
        }

        schedulePersist()
    }

    private func failBrowserCompletionPublication(
        id: UUID,
        attemptIdentifier: UUID,
        message: String
    ) {
        guard isCurrentDirectAttempt(id: id, attemptIdentifier: attemptIdentifier),
              let item = nonterminalItem(for: id) else {
            return
        }
        browserReservedIDs.remove(id)
        pendingBrowserContinuationIDs.remove(id)
        clearActiveBrowserSession(matching: id, attemptIdentifier: attemptIdentifier)
        directAttemptStates.removeValue(forKey: id)
        item.taskIdentifier = nil
        item.resumeData = nil
        item.browserResumeData = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.lastError = completedHandoffUnavailableMessage(message)
        item.updatedAt = .now
        setStatus(for: item, to: .failed)
        schedulePersist()
        startNextQueuedDownloadsIfNeeded()
    }

    private func clearActiveBrowserSession(
        matching id: UUID,
        attemptIdentifier: UUID? = nil
    ) {
        if activeBrowserSession?.downloadID == id,
           attemptIdentifier == nil
            || activeBrowserSession?.attemptIdentifier == attemptIdentifier {
            activeBrowserSession = nil
        }
    }

    private func isCurrentDirectAttempt(id: UUID, attemptIdentifier: UUID) -> Bool {
        directAttemptStates[id]?.identifier == attemptIdentifier
    }

    private func isActiveDirectAttempt(id: UUID, attemptIdentifier: UUID) -> Bool {
        guard case let .active(currentIdentifier) = directAttemptStates[id] else {
            return false
        }
        return currentIdentifier == attemptIdentifier
    }

    private func beginDirectRetryAfterCompletionLookup(_ item: DownloadItem) {
        let id = item.id
        guard completionLookupTasks[id] == nil else {
            return
        }

        let requestedStatus = item.status
        let sourceURL = item.sourceURL
        let completedHandoffStore = completedHandoffStore
        item.lastError = nil
        item.updatedAt = .now
        setStatus(for: item, to: .preparing)
        let task = Task { @MainActor [weak self, weak item] in
            guard let self else {
                return
            }
            defer {
                self.completionLookupTasks.removeValue(forKey: id)
                self.startNextQueuedDownloadsIfNeeded()
            }
            let browserRecoveryFailures: [UUID: String]
            do {
                browserRecoveryFailures = try await self.browserCoordinator
                    .recoverCompletedTemporaryFiles(downloadID: id)
            } catch {
                browserRecoveryFailures = [id: error.localizedDescription]
            }
            var lookup = await Task.detached(priority: .utility) {
                Self.lookupCompletedHandoff(
                    in: completedHandoffStore,
                    downloadID: id,
                    sourceURL: sourceURL
                )
            }.value
            if case .none = lookup,
               let recoveryFailure = browserRecoveryFailures[id] {
                lookup = .unavailable(
                    self.completedHandoffUnavailableMessage(recoveryFailure)
                )
            }
            guard let item,
                  self.isShuttingDown == false,
                  self.item(for: id) === item,
                  item.status == .preparing,
                  self.removalTasks[id] == nil,
                  self.cancellationTasks[id] == nil else {
                return
            }

            if requestedStatus == .cancelled {
                do {
                    // Cancellation is a durable request to abandon every byte
                    // owned by the retired attempt. Do not let Retry silently
                    // resume that state merely because the earlier cleanup hit
                    // a transient filesystem error.
                    try self.urlSessionCleanupOperation(
                        self.coordinator,
                        self.browserCoordinator,
                        id
                    )
                } catch {
                    item.status = .cancelled
                    item.lastError = error.localizedDescription
                    item.updatedAt = .now
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Restart Download"),
                        message: error.localizedDescription
                    )
                    self.schedulePersist()
                    return
                }

                item.status = .cancelled
                self.performRetry(of: item)
                return
            }

            switch lookup {
            case let .available(handoff):
                item.lastError = nil
                item.updatedAt = .now
                self.setStatus(for: item, to: .preparing)
                _ = await self.finalizeCompletedHandoff(
                    handoff,
                    for: item,
                    reportPersistenceFailure: true
                )
            case let .unavailable(message):
                self.setStatus(for: item, to: .failed)
                item.lastError = message
                item.updatedAt = .now
                self.activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Verify Completed Download"),
                    message: message
                )
                self.schedulePersist()
            case .none:
                item.status = requestedStatus
                self.performRetry(of: item)
            }
        }
        completionLookupTasks[id] = task
    }

    private func beginMediaRetryAfterCompletionLookup(_ item: DownloadItem) {
        let id = item.id
        guard completionLookupTasks[id] == nil else {
            return
        }

        let requestedStatus = item.status
        item.lastError = nil
        item.updatedAt = .now
        setStatus(for: item, to: .preparing)

        let task = Task { @MainActor [weak self, weak item] in
            guard let self else {
                return
            }
            defer {
                self.completionLookupTasks.removeValue(forKey: id)
                self.startNextQueuedDownloadsIfNeeded()
            }

            let entry: MediaCompletionEntry?
            do {
                entry = try await self.mediaService.completedDownloadEntry(id: id)
            } catch {
                guard let item,
                      self.item(for: id) === item,
                      item.status == .preparing else {
                    return
                }
                let failureMessage = String(
                    localized: "download.media.completionUnavailable",
                    defaultValue: "Harbor could not verify the completed media: \(error.localizedDescription)",
                    comment: "Failure shown when a durable media-completion journal is temporarily inaccessible."
                )
                _ = await self.persistMediaCompletionFailure(
                    failureMessage,
                    for: item
                )
                self.activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Verify Completed Media"),
                    message: failureMessage
                )
                return
            }

            guard let item,
                  self.isShuttingDown == false,
                  self.item(for: id) === item,
                  item.status == .preparing,
                  self.removalTasks[id] == nil,
                  self.cancellationTasks[id] == nil else {
                return
            }

            switch entry {
            case nil:
                item.status = requestedStatus
                self.performRetry(of: item)

            case let .valid(manifest):
                guard self.mediaCompletion(manifest, belongsTo: item) else {
                    let failureMessage = String(
                        localized: "download.media.completionOwnershipMismatch",
                        defaultValue: "The saved media completion does not belong to this download source and destination.",
                        comment: "Failure shown when a durable media-completion journal does not match the current download record."
                    )
                    _ = await self.persistMediaCompletionFailure(
                        failureMessage,
                        for: item
                    )
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Verify Completed Media"),
                        message: failureMessage
                    )
                    return
                }
                _ = await self.commitMediaCompletion(manifest, to: item)

            case let .invalid(_, message):
                let didPersistFailure = await self.persistMediaCompletionFailure(
                    message,
                    for: item
                )
                guard didPersistFailure else {
                    return
                }
                do {
                    // Persist the classification before deleting the only
                    // evidence that explains why this attempt cannot resume.
                    try await self.mediaService.discardCompletionMarker(id: id)
                } catch {
                    self.activeAlert = UserAlert(
                        title: String(localized: "Couldn’t Reset Media Recovery"),
                        message: error.localizedDescription
                    )
                    return
                }
                guard self.item(for: id) === item,
                      item.status == .failed,
                      self.removalTasks[id] == nil,
                      self.cancellationTasks[id] == nil else {
                    return
                }
                item.status = requestedStatus
                self.performRetry(of: item)

            case let .unavailable(_, message):
                let failureMessage = String(
                    localized: "download.media.completionUnavailable",
                    defaultValue: "Harbor could not verify the completed media: \(message)",
                    comment: "Failure shown when a durable media-completion journal is temporarily inaccessible."
                )
                _ = await self.persistMediaCompletionFailure(
                    failureMessage,
                    for: item
                )
                self.activeAlert = UserAlert(
                    title: String(localized: "Couldn’t Verify Completed Media"),
                    message: failureMessage
                )
            }
        }
        completionLookupTasks[id] = task
    }

    private nonisolated static func lookupCompletedHandoff(
        in store: CompletedDownloadHandoffStore,
        downloadID: UUID,
        sourceURL: URL
    ) -> CompletedHandoffLookup {
        var candidates: [CompletedDownloadHandoff] = []
        var unavailableDescription: String?
        let entries: [CompletedDownloadHandoffEntry]
        do {
            entries = try store.entries()
        } catch {
            return .unavailable(
                String(
                    localized: "download.completedHandoff.unavailable",
                    defaultValue: "Harbor could not verify completed downloads: \(error.localizedDescription)",
                    comment: "Failure shown when the completed-download journal cannot be scanned."
                )
            )
        }
        for entry in entries {
            switch entry {
            case let .valid(handoff)
                where handoff.manifest.downloadID == downloadID
                    && handoff.manifest.sourceURL == sourceURL:
                candidates.append(handoff)
            case let .unavailable(_, candidateID, errorDescription)
                where candidateID == downloadID:
                unavailableDescription = unavailableDescription ?? String(
                    localized: "download.completedHandoff.unavailable",
                    defaultValue: "Harbor could not verify the completed download: \(errorDescription)",
                    comment: "Failure shown when a durable completed download package is temporarily inaccessible."
                )
            case .valid, .invalid, .unavailable:
                continue
            }
        }
        if let newest = candidates.max(by: { $0.manifest.createdAt < $1.manifest.createdAt }) {
            return .available(newest)
        }
        if let unavailableDescription {
            return .unavailable(unavailableDescription)
        }
        return .none
    }

    private func completedHandoffUnavailableMessage(_ detail: String) -> String {
        String(
            localized: "download.completedHandoff.unavailable",
            defaultValue: "Harbor could not verify the completed download: \(detail)",
            comment: "Failure shown when a durable completed download package is temporarily inaccessible."
        )
    }

    private func directRecoveryUnavailableMessage(_ detail: String) -> String {
        String(
            localized: "download.direct.recoveryUnavailable",
            defaultValue: "Harbor could not access the saved download progress: \(detail)",
            comment: "Failure shown when a direct download partial is temporarily inaccessible."
        )
    }

#if DEBUG
    func installDirectAttemptForTesting(id: UUID, attemptIdentifier: UUID) {
        directAttemptStates[id] = .active(attemptIdentifier)
    }

    @discardableResult
    func installActiveBrowserDownloadForTesting(
        id: UUID,
        attemptIdentifier: UUID,
        cancel: @escaping (@escaping @Sendable (Data?) -> Void) -> Void
    ) -> BrowserDownloadSession? {
        guard let item = item(for: id) else {
            return nil
        }
        let session = browserCoordinator.startSession(
            downloadID: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            displayName: item.displayName
        )
        directAttemptStates[id] = .active(attemptIdentifier)
        browserReservedIDs.insert(id)
        activeBrowserSession = session
        setStatus(for: item, to: .downloading)
        browserCoordinator.installActiveDownloadForTesting(
            session: session,
            cancel: cancel
        )
        return session
    }

    func installBrowserCompletionPublicationForTesting(
        downloadID: UUID,
        attemptIdentifier: UUID,
        operation: @escaping @MainActor @Sendable () async -> BrowserDownloadEvent
    ) {
        browserCoordinator.installCompletionPublicationForTesting(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            operation: operation
        )
    }

    func hasBrowserReservationForTesting(id: UUID) -> Bool {
        browserReservedIDs.contains(id)
    }

    func hasTerminalMutationTaskForTesting(id: UUID) -> Bool {
        cancellationTasks[id] != nil || removalTasks[id] != nil
    }

    func installTerminalMutationTaskForTesting(
        id: UUID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.cancellationTasks.removeValue(forKey: id)
        }
        cancellationTasks[id] = task
    }

    var isBrowserQuiescingForShutdownForTesting: Bool {
        browserCoordinator.isQuiescingForShutdownForTesting
    }

    func installReadyDirectRetryForTesting(
        id: UUID,
        restartingFromBeginning: Bool = false
    ) {
        readyDirectRetries[id] = restartingFromBeginning
    }

    func drainDownloadQueueForTesting() {
        startNextQueuedDownloadsIfNeeded()
    }

    func installMediaAttemptForTesting(id: UUID, attemptIdentifier: UUID) {
        activeMediaAttemptIdentifiers[id] = attemptIdentifier
    }

    func reflectTorrentPauseFailureForTesting(
        _ item: DownloadItem,
        error: Error
    ) {
        reflectActiveTorrentAfterPauseFailure(item, error: error)
    }

    func reflectTorrentUnpauseUncertaintyForTesting(
        _ item: DownloadItem,
        error: Error
    ) {
        reflectActiveTorrentAfterUnpauseUncertainty(item, error: error)
    }

    func applyTorrentLineageForTesting(
        _ lineage: TorrentStatusLineage,
        to id: UUID
    ) async {
        guard let item = item(for: id) else {
            return
        }
        await apply(lineage: lineage, to: item)
    }

    func scheduleOrphanedTorrentCleanupForTesting(
        gid: String,
        ownerDownloadID: UUID? = nil
    ) {
        scheduleOrphanedTorrentCleanup(
            gid: gid,
            ownerDownloadID: ownerDownloadID,
            retryDelays: [.zero]
        )
    }

    func reconcileTorrentReservationsForTesting(
        engineGIDs: Set<String>
    ) async {
        await reconcileRestoredTorrentSession(
            knownEngineGIDs: engineGIDs,
            stopsAfterReservationAdoption: true
        )
    }

    var orphanedTorrentCleanupTaskCountForTesting: Int {
        orphanedTorrentCleanupTasks.count
    }
#endif

    private func beginCompletedHandoff(
        id: UUID,
        attemptIdentifier: UUID,
        handoff: CompletedDownloadHandoff
    ) {
        if completionTasks[id] != nil {
            return
        }
        guard isCurrentDirectAttempt(id: id, attemptIdentifier: attemptIdentifier) else {
            if item(for: id)?.status == .completed,
               completedHandoffStore.ownsAttempt(
                   downloadID: id,
                   attemptIdentifier: attemptIdentifier
               ) {
                // The completion record could not yet be saved. Keep its
                // journal for restart reconciliation instead of treating the
                // repeated delegate event as an unowned payload.
                return
            }
            completedHandoffStore.discardPackage(at: handoff.packageURL)
            return
        }
        guard let item = nonterminalItem(for: id),
              handoff.manifest.downloadID == id,
              handoff.manifest.attemptIdentifier == attemptIdentifier else {
            completedHandoffStore.discardPackage(at: handoff.packageURL)
            return
        }

        pendingBrowserWriterMutations.removeValue(forKey: id)
        directAttemptStates[id] = .terminal(attemptIdentifier)
        coordinator.acknowledgeTerminalOutcome(
            id: id,
            attemptIdentifier: attemptIdentifier
        )
        browserReservedIDs.remove(id)
        clearActiveBrowserSession(matching: id, attemptIdentifier: attemptIdentifier)
        resetDirectRetryState(for: id)
        item.taskIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        let task = Task { @MainActor [weak self, weak item] in
            guard let self, let item, self.item(for: id) === item else {
                self?.completedHandoffStore.discardPackage(at: handoff.packageURL)
                return
            }
            _ = await self.finalizeCompletedHandoff(
                handoff,
                for: item,
                reportPersistenceFailure: true
            )
            if self.directAttemptStates[id]?.identifier == attemptIdentifier {
                self.directAttemptStates.removeValue(forKey: id)
            }
            self.pendingDirectPauseFailures.removeValue(forKey: id)
            self.completionTasks.removeValue(forKey: id)
            self.startNextQueuedDownloadsIfNeeded()
        }
        completionTasks[id] = task
    }

    private func reconcileCompletionAfterQuiescence(
        for item: DownloadItem,
        attemptIdentifier: UUID?
    ) async {
        let id = item.id
        if let completionTask = completionTasks[id] {
            await completionTask.value
            return
        }

        guard item.backend == .urlSession,
              let attemptIdentifier else {
            return
        }
        guard let handoff = await completedHandoff(
            downloadID: id,
            attemptIdentifier: attemptIdentifier
        ), handoff.manifest.sourceURL == item.sourceURL else {
            return
        }

        directAttemptStates[id] = .active(attemptIdentifier)
        beginCompletedHandoff(
            id: id,
            attemptIdentifier: attemptIdentifier,
            handoff: handoff
        )
        if let completionTask = completionTasks[id] {
            await completionTask.value
        }
    }

    private func completedHandoff(
        downloadID: UUID,
        attemptIdentifier: UUID
    ) async -> CompletedDownloadHandoff? {
        let completedHandoffStore = completedHandoffStore
        return await Task.detached(priority: .utility) {
            completedHandoffStore.handoff(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier
            )
        }.value
    }

    private func nonterminalItem(for id: UUID) -> DownloadItem? {
        guard let item = item(for: id), item.status.isTerminal == false else {
            return nil
        }

        return item
    }

    func handle(
        _ event: MediaDownloadEvent,
        attemptIdentifier: UUID
    ) {
        guard let id = mediaDownloadID(from: event),
              activeMediaAttemptIdentifiers[id] == attemptIdentifier else {
            return
        }

        if mediaEventReleasesQueueSlot(event) {
            activeMediaAttemptIdentifiers.removeValue(forKey: id)
        }

        if item(for: id) == nil {
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
            guard isShuttingDown == false else {
                return
            }

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

            if item.status == .cancelled {
                item.backendIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
                transitionStatus(for: item, to: .cancelled)
            }
            startNextQueuedDownloadsIfNeeded()

        case let .finished(id, fileURL, payloadURLs, expectedBytes):
            guard let item = item(for: id) else {
                return
            }
            let task = Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.item(for: id) === item else {
                    self?.completionTasks.removeValue(forKey: id)
                    return
                }
                defer {
                    self.completionTasks.removeValue(forKey: id)
                    self.startNextQueuedDownloadsIfNeeded()
                }

                let entry: MediaCompletionEntry?
                do {
                    entry = try await self.mediaService.completedDownloadEntry(id: id)
                } catch {
                    _ = await self.persistMediaCompletionFailure(
                        String(
                            localized: "download.media.completionUnavailable",
                            defaultValue: "Harbor could not verify the completed media: \(error.localizedDescription)",
                            comment: "Failure shown when a durable media-completion journal is temporarily inaccessible."
                        ),
                        for: item
                    )
                    return
                }

                switch entry {
                case let .valid(manifest):
                    let eventPayloadPaths = payloadURLs.map {
                        $0.standardizedFileURL.path
                    }
                    let manifestPayloadPaths = manifest.payloads.map(\.path)
                    guard manifest.attemptIdentifier == attemptIdentifier,
                          self.mediaCompletion(manifest, belongsTo: item),
                          manifest.fileLocationPath
                            == fileURL.standardizedFileURL.path,
                          manifest.actualBytes == max(expectedBytes, 0),
                          eventPayloadPaths.count == manifestPayloadPaths.count,
                          Set(eventPayloadPaths) == Set(manifestPayloadPaths) else {
                        _ = await self.persistMediaCompletionFailure(
                            "The completed media journal did not match the active download attempt.",
                            for: item
                        )
                        return
                    }
                    _ = await self.commitMediaCompletion(manifest, to: item)

                case let .invalid(_, message):
                    let didPersistFailure = await self.persistMediaCompletionFailure(
                        message,
                        for: item
                    )
                    if didPersistFailure {
                        await self.discardInvalidMediaCompletionMarker(id: id)
                    }

                case let .unavailable(_, message):
                    _ = await self.persistMediaCompletionFailure(
                        String(
                            localized: "download.media.completionUnavailable",
                            defaultValue: "Harbor could not verify the completed media: \(message)",
                            comment: "Failure shown when a durable media-completion journal is temporarily inaccessible."
                        ),
                        for: item
                    )

                case nil:
                    _ = await self.persistMediaCompletionFailure(
                        "The completed media journal is missing.",
                        for: item
                    )
                }
            }
            completionTasks[id] = task
            return

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

    func activeMediaAttemptIdentifier(for id: UUID) -> UUID? {
        activeMediaAttemptIdentifiers[id]
    }

    private func mediaDownloadID(from event: MediaDownloadEvent) -> UUID? {
        switch event {
        case let .started(id, _, _, _, _),
             let .progress(id, _, _, _),
             let .paused(id),
             let .cancelled(id),
             let .finished(id, _, _, _),
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

    private func markBrowserSessionRequired(
        _ item: DownloadItem,
        message: String,
        preservingProgress: Bool = false
    ) {
        item.taskIdentifier = nil
        setStatus(for: item, to: .browserSessionRequired)
        if preservingProgress == false {
            item.progress = 0
            item.bytesWritten = 0
            item.expectedBytes = 0
        }
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
        case .directURL:
            AddDownloadSheetDraft.linkOrMagnet(
                url,
                destinationFolderURL: settings.defaultDestinationURL,
                shouldStartImmediately: settings.startDownloadsAutomatically
            )
        case .mediaURL, nil:
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
            } else if previousStatus == .downloading
                || previousStatus == .preparing
                || previousStatus == .waitingToRetry {
                nil
            } else {
                previousStatus == .paused || previousStatus == .browserSessionRequired ? .resumed : .started
            }
        case .waitingToRetry:
            nil
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
        case .queued, .preparing, .waitingToRetry, .downloading, .seeding, .browserSessionRequired, .paused:
            return nil
        }

        return DownloadNotificationPayload(
            identifier: "download-\(item.id.uuidString)-\(status.rawValue)",
            title: title,
            body: body
        )
    }

    private func scheduleOrphanedTorrentCleanup(
        gid: String,
        ownerDownloadID: UUID? = nil,
        retryDelays: [Duration] = [.seconds(1), .seconds(5), .seconds(15)]
    ) {
        guard isShuttingDown == false,
              orphanedTorrentCleanupTasks[gid] == nil else {
            return
        }

        let torrentService = torrentService
        let torrentRemoveOperation = torrentRemoveOperation
        orphanedTorrentCleanupTasks[gid] = Task {
            @MainActor [weak self, torrentService, torrentRemoveOperation] in
            for delay in retryDelays {
                do {
                    try await Task.sleep(for: delay)
                    guard let self else {
                        return
                    }
                    guard self.shouldRunOrphanedTorrentCleanup(
                        gid: gid,
                        ownerDownloadID: ownerDownloadID
                    ) else {
                        self.orphanedTorrentCleanupTasks.removeValue(forKey: gid)
                        return
                    }
                    try await torrentRemoveOperation(torrentService, gid)

                    self.orphanedTorrentCleanupTasks.removeValue(forKey: gid)
                    if let ownerDownloadID,
                       let item = self.item(for: ownerDownloadID),
                       item.backendIdentifier == gid,
                       self.shouldRunOrphanedTorrentCleanup(
                           gid: gid,
                           ownerDownloadID: ownerDownloadID
                       ) {
                        let originalIdentifier = item.backendIdentifier
                        item.backendIdentifier = nil
                        item.lastError = nil
                        item.updatedAt = .now
                        do {
                            try await self.saveRecordsNow()
                        } catch {
                            item.backendIdentifier = originalIdentifier
                            item.lastError = error.localizedDescription
                            self.activeAlert = UserAlert(
                                title: String(localized: "Couldn’t Save Torrent Cleanup"),
                                message: error.localizedDescription
                            )
                        }
                    }
                    return
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }
            }
            self?.orphanedTorrentCleanupTasks.removeValue(forKey: gid)
        }
    }

    private func shouldRunOrphanedTorrentCleanup(
        gid: String,
        ownerDownloadID: UUID?
    ) -> Bool {
        guard let ownerDownloadID,
              let item = item(for: ownerDownloadID),
              item.backendIdentifier == gid else {
            return true
        }
        return item.status == .cancelled
            || (item.status == .completed && item.shouldSeedAfterDownload == false)
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
        guard isShuttingDown == false else {
            return
        }

        persistTask?.cancel()
        persistTask = Task { @MainActor [weak self] in
            await DownloadCenterDurableMutationContext.$token.withValue(nil) {
                guard let self else {
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    try Task.checkCancellation()
                    try await self.persistCurrentRecords()
                } catch is CancellationError {
                    return
                } catch {
                    guard self.isShuttingDown == false else {
                        return
                    }
                    self.activeAlert = UserAlert(
                        title: String(
                            localized: "alert.saveDownloads.title",
                            defaultValue: "Couldn’t Save Downloads",
                            comment: "Alert title shown when Harbor cannot save the download list."
                        ),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func saveRecordsNow() async throws {
        await cancelPendingPersistenceAndWait()
        try await persistCurrentRecords()
    }

    private func persistCurrentRecords() async throws {
        if let contextToken = DownloadCenterDurableMutationContext.token,
           persistenceGateOwner == contextToken {
            try await writeCurrentRecords()
            return
        }

        let token = UUID()
        try await acquirePersistenceGate(token: token)
        defer { releasePersistenceGate(token: token) }
        try await DownloadCenterDurableMutationContext.$token.withValue(token) {
            try await writeCurrentRecords()
        }
    }

    private func writeCurrentRecords() async throws {
        let revision = nextPersistenceRevision()
        try await recordSaveOperation(
            persistence,
            downloads.map { $0.makeRecord() },
            revision
        )
    }

    private func performSerializedDurableMutation(
        _ operation: () async -> Void
    ) async {
        let token = UUID()
        do {
            try await acquirePersistenceGate(token: token)
        } catch {
            return
        }
        defer { releasePersistenceGate(token: token) }
        await DownloadCenterDurableMutationContext.$token.withValue(token) {
            await operation()
        }
    }

    private func acquirePersistenceGate(token: UUID) async throws {
        try Task.checkCancellation()
        if persistenceGateOwner == nil {
            persistenceGateOwner = token
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard Task.isCancelled == false else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                persistenceGateWaiters.append(
                    PersistenceGateWaiter(
                        id: waiterID,
                        token: token,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPersistenceGateWaiter(id: waiterID)
            }
        }
        do {
            try Task.checkCancellation()
        } catch {
            // The previous owner may have granted this waiter at the same
            // instant its task was cancelled. Once granted, the waiter is no
            // longer present for the cancellation handler to remove; release
            // that ownership explicitly or every later persistence mutation
            // would wait forever.
            if persistenceGateOwner == token {
                releasePersistenceGate(token: token)
            }
            throw error
        }
    }

    private func cancelPersistenceGateWaiter(id: UUID) {
        guard let index = persistenceGateWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = persistenceGateWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releasePersistenceGate(token: UUID) {
        guard persistenceGateOwner == token else {
            return
        }
        guard persistenceGateWaiters.isEmpty == false else {
            persistenceGateOwner = nil
            return
        }
        let next = persistenceGateWaiters.removeFirst()
        persistenceGateOwner = next.token
#if DEBUG
        let grantHook = persistenceGateGrantHookForTesting
        persistenceGateGrantHookForTesting = nil
        grantHook?()
#endif
        next.continuation.resume()
    }

#if DEBUG
    func performSerializedDurableMutationForTesting(
        _ operation: () async -> Void
    ) async {
        await performSerializedDurableMutation(operation)
    }

    func persistCurrentRecordsForTesting() async throws {
        try await persistCurrentRecords()
    }

    func installPersistenceGateGrantHookForTesting(_ hook: @escaping () -> Void) {
        persistenceGateGrantHookForTesting = hook
    }

    var isPersistenceGateIdleForTesting: Bool {
        persistenceGateOwner == nil && persistenceGateWaiters.isEmpty
    }

    var persistenceGateWaiterCountForTesting: Int {
        persistenceGateWaiters.count
    }
#endif

    private func nextPersistenceRevision() -> DownloadPersistenceRevision {
        persistenceRevision &+= 1
        return DownloadPersistenceRevision(
            writerIdentifier: persistenceWriterIdentifier,
            value: persistenceRevision
        )
    }

    private func cancelPendingPersistenceAndWait() async {
        while let pendingTask = persistTask {
            persistTask = nil
            pendingTask.cancel()
            await pendingTask.value
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

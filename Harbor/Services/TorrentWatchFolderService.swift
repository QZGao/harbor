import Darwin
import Dispatch
import Foundation

enum TorrentWatchFolderStatus: Equatable, Sendable {
    case stopped
    case watching
    case unavailable
}

@MainActor
final class TorrentWatchFolderService {
    typealias CandidateHandler = @MainActor (URL) -> Void

    private struct FileSnapshot: Equatable {
        let size: Int64
        let modificationDate: Date
    }

    private let fileManager: FileManager
    private let debounceInterval: TimeInterval
    private let retryInterval: TimeInterval

    private var watchedFolderURL: URL?
    private var candidateHandler: CandidateHandler?
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var previousSnapshots: [String: FileSnapshot] = [:]
    private var emittedSnapshots: [String: FileSnapshot] = [:]

    private(set) var status: TorrentWatchFolderStatus = .stopped {
        didSet {
            guard status != oldValue else {
                return
            }
            statusDidChange?(status)
        }
    }

    var statusDidChange: ((TorrentWatchFolderStatus) -> Void)? {
        didSet {
            statusDidChange?(status)
        }
    }

    init(
        fileManager: FileManager = .default,
        debounceInterval: TimeInterval = 1,
        retryInterval: TimeInterval = 10
    ) {
        self.fileManager = fileManager
        self.debounceInterval = debounceInterval
        self.retryInterval = retryInterval
    }

    func start(
        watching folderURL: URL,
        onCandidate: @escaping CandidateHandler
    ) {
        stop()
        watchedFolderURL = folderURL.standardizedFileURL
        candidateHandler = onCandidate
        beginWatching()
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        directorySource?.cancel()
        directorySource = nil
        watchedFolderURL = nil
        candidateHandler = nil
        previousSnapshots = [:]
        emittedSnapshots = [:]
        status = .stopped
    }

    private func beginWatching() {
        guard let watchedFolderURL, candidateHandler != nil else {
            status = .stopped
            return
        }

        retryWorkItem?.cancel()
        retryWorkItem = nil

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: watchedFolderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: watchedFolderURL.path) else {
            markUnavailableAndRetry()
            return
        }

        let descriptor = open(watchedFolderURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            markUnavailableAndRetry()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: .main
        )
        source.setCancelHandler {
            close(descriptor)
        }
        source.setEventHandler { [weak self, weak source] in
            let event = source?.data ?? []
            Task { @MainActor [weak self] in
                self?.handleDirectoryEvent(event)
            }
        }
        directorySource = source
        status = .watching
        source.resume()
        scheduleScan(after: 0)
    }

    private func handleDirectoryEvent(_ event: DispatchSource.FileSystemEvent) {
        if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
            markUnavailableAndRetry()
            return
        }

        scheduleScan(after: debounceInterval)
    }

    private func scheduleScan(after delay: TimeInterval) {
        guard status == .watching else {
            return
        }

        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.scanWatchedFolder()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scanWatchedFolder() {
        guard status == .watching,
              let watchedFolderURL,
              let candidateHandler else {
            return
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: watchedFolderURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            markUnavailableAndRetry()
            return
        }

        var currentSnapshots: [String: FileSnapshot] = [:]
        var needsConfirmationScan = false

        for fileURL in contents where fileURL.pathExtension.caseInsensitiveCompare("torrent") == .orderedSame {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile != false,
                  let size = values.fileSize,
                  let modificationDate = values.contentModificationDate else {
                continue
            }

            let canonicalURL = fileURL.standardizedFileURL
            let path = canonicalURL.path
            let snapshot = FileSnapshot(size: Int64(size), modificationDate: modificationDate)
            currentSnapshots[path] = snapshot

            guard previousSnapshots[path] == snapshot else {
                needsConfirmationScan = true
                continue
            }

            guard emittedSnapshots[path] != snapshot else {
                continue
            }

            emittedSnapshots[path] = snapshot
            candidateHandler(canonicalURL)
        }

        previousSnapshots = currentSnapshots
        emittedSnapshots = emittedSnapshots.filter { currentSnapshots[$0.key] == $0.value }

        if needsConfirmationScan {
            scheduleScan(after: debounceInterval)
        }
    }

    private func markUnavailableAndRetry() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        directorySource?.cancel()
        directorySource = nil
        previousSnapshots = [:]
        emittedSnapshots = [:]
        status = .unavailable
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard watchedFolderURL != nil, candidateHandler != nil else {
            return
        }

        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.beginWatching()
            }
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: workItem)
    }
}

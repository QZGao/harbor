import Foundation

nonisolated struct TorrentSidecarContext: Sendable {
    let destinationFolderURL: URL
    let sourceKind: DownloadSourceKind
    let torrentFingerprint: String?
    let fileLocationURL: URL?
    let payloadURLs: [URL]
}

nonisolated struct TorrentSidecarFileService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func hideExistingSidecars(for context: TorrentSidecarContext) {
        for url in verifiedExistingSidecarURLs(for: context) {
            var values = URLResourceValues()
            values.isHidden = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
        }
    }

    func removeExistingSidecars(for context: TorrentSidecarContext) throws {
        for url in verifiedExistingSidecarURLs(for: context) {
            try fileManager.removeItem(at: url)
        }
    }

    func removeExistingControlFiles(for context: TorrentSidecarContext) throws {
        for url in existingControlFileURLs(for: context) {
            try fileManager.removeItem(at: url)
        }
    }

    func magnetMetadataURL(for context: TorrentSidecarContext) -> URL? {
        verifiedMagnetMetadataURL(for: context)
    }

    func removeMagnetMetadata(for context: TorrentSidecarContext) throws {
        guard let metadataURL = verifiedMagnetMetadataURL(for: context) else {
            return
        }

        try fileManager.removeItem(at: metadataURL)
    }

    private func verifiedExistingSidecarURLs(for context: TorrentSidecarContext) -> [URL] {
        var candidates = Set(existingControlFileURLs(for: context))

        if let metadataURL = verifiedMagnetMetadataURL(for: context) {
            candidates.insert(metadataURL)

            let metadataControlURL = URL(fileURLWithPath: metadataURL.path + ".aria2")
                .standardizedFileURL
            if isDescendant(
                metadataControlURL,
                of: context.destinationFolderURL.standardizedFileURL
            ) {
                candidates.insert(metadataControlURL)
            }
        }

        return candidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private func existingControlFileURLs(for context: TorrentSidecarContext) -> [URL] {
        let destinationURL = context.destinationFolderURL.standardizedFileURL
        var candidates = Set<URL>()

        for payloadURL in context.payloadURLs + [context.fileLocationURL].compactMap({ $0 }) {
            let controlURL = URL(fileURLWithPath: payloadURL.path + ".aria2").standardizedFileURL
            if isDescendant(controlURL, of: destinationURL) {
                candidates.insert(controlURL)
            }
        }

        if context.sourceKind == .magnetLink,
           let fingerprint = ManagedTorrentSourceStore.normalizedInfoHash(context.torrentFingerprint) {
            let metadataControlURL = destinationURL
                .appendingPathComponent("\(fingerprint).torrent.aria2", isDirectory: false)
                .standardizedFileURL
            candidates.insert(metadataControlURL)
        }

        return candidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private func verifiedMagnetMetadataURL(for context: TorrentSidecarContext) -> URL? {
        guard context.sourceKind == .magnetLink,
              let fingerprint = ManagedTorrentSourceStore.normalizedInfoHash(context.torrentFingerprint)
        else {
            return nil
        }

        let metadataURL = context.destinationFolderURL
            .appendingPathComponent("\(fingerprint).torrent", isDirectory: false)
            .standardizedFileURL
        guard isDescendant(metadataURL, of: context.destinationFolderURL.standardizedFileURL),
              fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL, options: .mappedIfSafe),
              ManagedTorrentSourceStore.fingerprint(for: data) == fingerprint else {
            return nil
        }

        return metadataURL
    }

    private func isDescendant(_ candidateURL: URL, of directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.path.hasSuffix("/")
            ? directoryURL.path
            : directoryURL.path + "/"
        return candidateURL.path.hasPrefix(directoryPath)
    }
}

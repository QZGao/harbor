import Foundation

struct TorrentContentsPreviewService: Sendable {
    func preview(
        sourceKind: DownloadSourceKind,
        sourceURL: URL,
        torrentService: Aria2TorrentService
    ) async throws -> TorrentContentsPreview {
        let data: Data
        switch sourceKind {
        case .magnetLink:
            data = try await torrentService.previewMagnetMetainfo(at: sourceURL)
        case .torrentFile:
            if sourceURL.isFileURL {
                data = try readLocalTorrent(at: sourceURL)
            } else {
                data = try await fetchRemoteTorrent(from: sourceURL)
            }
        case .directURL, .mediaURL:
            throw TorrentEngineError.invalidSource
        }

        return try TorrentMetainfoParser.preview(from: data)
    }

    private func readLocalTorrent(at sourceURL: URL) throws -> Data {
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return try ManagedTorrentSourceStore.loadTorrentData(at: sourceURL)
    }

    private func fetchRemoteTorrent(from sourceURL: URL) async throws -> Data {
        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let response = response as? HTTPURLResponse else {
            throw ManagedTorrentSourceStoreError.invalidServerResponse
        }
        guard 200 ..< 300 ~= response.statusCode else {
            throw ManagedTorrentSourceStoreError.unsuccessfulStatusCode(response.statusCode)
        }
        return try ManagedTorrentSourceStore.loadTorrentData(at: temporaryURL)
    }
}

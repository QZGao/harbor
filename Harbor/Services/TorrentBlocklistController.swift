import Foundation

@MainActor
final class TorrentBlocklistController {
    private let settings: AppSettingsStore
    private let service: TorrentBlocklistService
    private var updateTask: Task<Void, Never>?

    init(settings: AppSettingsStore, service: TorrentBlocklistService) {
        self.settings = settings
        self.service = service

        settings.torrentBlocklistSettingsDidChange = { [weak self] in
            self?.scheduleUpdate(forceRefresh: false)
        }
        settings.torrentBlocklistRefreshRequested = { [weak self] in
            guard self?.settings.torrentBlocklistEnabled == true else {
                return
            }
            self?.scheduleUpdate(forceRefresh: true)
        }
    }

    deinit {
        updateTask?.cancel()
    }

    func activate() async {
        await update(forceRefresh: false)
    }

    private func scheduleUpdate(forceRefresh: Bool) {
        let previousTask = updateTask
        previousTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard Task.isCancelled == false else {
                return
            }
            guard let self else {
                return
            }
            await self.update(forceRefresh: forceRefresh)
            if Task.isCancelled == false {
                self.updateTask = nil
            }
        }
    }

    private func update(forceRefresh: Bool) async {
        settings.setTorrentBlocklistRefreshing(true)
        defer { settings.setTorrentBlocklistRefreshing(false) }

        do {
            guard settings.torrentBlocklistEnabled else {
                try await service.disable()
                settings.markTorrentBlocklistDisabled()
                return
            }

            let status = if forceRefresh {
                try await service.refresh(
                    source: settings.torrentBlocklistURL,
                    proxySettings: settings.proxySettings
                )
            } else {
                try await service.activate(
                    source: settings.torrentBlocklistURL,
                    proxySettings: settings.proxySettings
                )
            }
            guard Task.isCancelled == false else {
                return
            }
            settings.updateTorrentBlocklistStatus(status)
        } catch {
            guard Task.isCancelled == false else {
                return
            }
            settings.updateTorrentBlocklistError(error)
        }
    }
}

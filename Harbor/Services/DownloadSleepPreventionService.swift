import Foundation

@MainActor
protocol DownloadSleepPreventing: AnyObject {
    func update(isEnabled: Bool, hasActiveDownloads: Bool)
    func stop()
}

@MainActor
final class DownloadSleepPreventionService: DownloadSleepPreventing {
    private var activity: NSObjectProtocol?

    func update(isEnabled: Bool, hasActiveDownloads: Bool) {
        if isEnabled, hasActiveDownloads {
            guard activity == nil else {
                return
            }

            activity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Harbor is downloading files."
            )
        } else {
            stop()
        }
    }

    func stop() {
        guard let activity else {
            return
        }

        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

import Foundation

enum DownloadFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case active
    case paused
    case completed
    case failed
    case cancelled

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .all:
            LocalizedStringResource("sidebar.category.all", defaultValue: "All Downloads")
        case .active:
            LocalizedStringResource("sidebar.category.active", defaultValue: "Active")
        case .paused:
            LocalizedStringResource("sidebar.category.paused", defaultValue: "Paused")
        case .completed:
            LocalizedStringResource("sidebar.category.completed", defaultValue: "Completed")
        case .failed:
            LocalizedStringResource("sidebar.category.failed", defaultValue: "Failed")
        case .cancelled:
            LocalizedStringResource("sidebar.category.cancelled", defaultValue: "Cancelled")
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            "Everything in your queue and history"
        case .active:
            "Running and queued transfers"
        case .paused:
            "Ready to resume or continue in browser"
        case .completed:
            "Saved successfully"
        case .failed:
            "Needs attention"
        case .cancelled:
            "Stopped manually"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            "tray.full"
        case .active:
            "arrow.down.circle"
        case .paused:
            "pause.circle"
        case .completed:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .cancelled:
            "xmark.circle"
        }
    }

    @MainActor
    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            item.status == .queued
                || item.status == .preparing
                || item.status == .waitingToRetry
                || item.status == .downloading
                || item.status == .seeding
        case .paused:
            item.status == .paused || item.status == .browserSessionRequired
        case .completed:
            item.status == .completed
        case .failed:
            item.status == .failed
        case .cancelled:
            item.status == .cancelled
        }
    }
}

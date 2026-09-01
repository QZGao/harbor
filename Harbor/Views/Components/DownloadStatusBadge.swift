import SwiftUI

struct DownloadStatusBadge: View {
    let status: DownloadStatus
    var downloadID: UUID?

    init(status: DownloadStatus, downloadID: UUID? = nil) {
        self.status = status
        self.downloadID = downloadID
    }

    private var tint: Color {
        switch status {
        case .queued:
            .secondary
        case .preparing, .waitingToRetry:
            .orange
        case .downloading:
            .blue
        case .seeding:
            .purple
        case .browserSessionRequired:
            .mint
        case .paused:
            .yellow
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .accessibilityIdentifier(
                downloadID.map { HarborAccessibility.downloadStatus(status, downloadID: $0) }
                    ?? HarborAccessibility.downloadStatus(status)
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
    }
}

import SwiftUI

struct AcknowledgmentsSettingsTab: View {
    private let acknowledgments = OpenSourceAcknowledgment.all

    var body: some View {
        Form {
            Section {
                Text("Harbor is made possible by these open-source projects.")
                    .foregroundStyle(.secondary)
            }

            Section("Open Source Software") {
                ForEach(acknowledgments) { acknowledgment in
                    AcknowledgmentRow(acknowledgment: acknowledgment)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AcknowledgmentRow: View {
    let acknowledgment: OpenSourceAcknowledgment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(acknowledgment.name)
                    .font(.headline)

                Spacer()

                Text(acknowledgment.license)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(acknowledgment.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct OpenSourceAcknowledgment: Identifiable {
    let name: String
    let license: String
    let purpose: String

    var id: String { name }

    static let all: [OpenSourceAcknowledgment] = [
        OpenSourceAcknowledgment(
            name: "aria2",
            license: "GNU GPL v2 or later",
            purpose: "Torrent and magnet downloads."
        ),
        OpenSourceAcknowledgment(
            name: "yt-dlp",
            license: "The Unlicense",
            purpose: "Media extraction and downloads."
        ),
        OpenSourceAcknowledgment(
            name: "FFmpeg",
            license: "GNU GPL (bundled build)",
            purpose: "Media probing, conversion, and merging."
        )
    ]
}

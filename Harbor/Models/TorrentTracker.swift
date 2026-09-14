import Foundation

nonisolated struct TorrentTracker: Decodable, Equatable, Identifiable, Sendable {
    let url: String
    let source: String
    let tier: String
    let status: String
    let seeders: String
    let leechers: String
    let updating: String
    let message: String?

    var id: String { url }

    var isRemovable: Bool {
        source == "global"
    }

    var tierNumber: Int {
        Int(tier) ?? 0
    }

    var statusText: String {
        if updating == "true" {
            return String(localized: "Updating")
        }
        guard status.isEmpty == false else {
            return String(localized: "Unknown")
        }
        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var peerCountText: String? {
        guard let seeders = Int(seeders), seeders >= 0,
              let leechers = Int(leechers), leechers >= 0 else {
            return nil
        }
        return String(
            format: String(localized: "%1$d seeders, %2$d leechers"),
            seeders,
            leechers
        )
    }

    static func pending(url: String, tier: Int) -> TorrentTracker {
        TorrentTracker(
            url: url,
            source: "metainfo",
            tier: "\(tier)",
            status: "",
            seeders: "-1",
            leechers: "-1",
            updating: "false",
            message: nil
        )
    }
}

nonisolated enum TorrentTrackerError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter an HTTP, HTTPS, or UDP tracker URL."
        case .unavailable:
            "Tracker information is unavailable for this download."
        }
    }

    static func normalizedURL(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "udp"].contains(scheme),
              components.host?.isEmpty == false else {
            throw TorrentTrackerError.invalidURL
        }
        return value
    }
}

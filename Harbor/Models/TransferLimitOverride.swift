import Foundation

enum TransferLimitOverride: Codable, Equatable, Hashable, Sendable {
    case inherit
    case unlimited
    case limited(kilobytesPerSecond: Int)

    nonisolated func resolvedBytesPerSecond(inheriting defaultLimit: Int64?) -> Int64? {
        switch self {
        case .inherit:
            return defaultLimit
        case .unlimited:
            return nil
        case let .limited(kilobytesPerSecond):
            let clampedKilobytes = Int64(clamping: max(kilobytesPerSecond, 1))
            let (bytesPerSecond, didOverflow) = clampedKilobytes.multipliedReportingOverflow(by: 1_024)
            return didOverflow ? Int64.max : bytesPerSecond
        }
    }
}

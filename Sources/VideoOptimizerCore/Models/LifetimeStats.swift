// LifetimeStats.swift - Cumulative bytes saved across every successful conversion, ever.

import Foundation

/// How much this app has saved you, in total, across every launch — not just this
/// session. Persisted by LifetimeStatsStore (App layer) as JSON; this struct is the
/// pure, testable shape and has no idea it gets written to UserDefaults.
public struct LifetimeStats: Codable, Equatable, Sendable {
    public var totalInputBytes: Int64 = 0
    public var totalOutputBytes: Int64 = 0
    public var filesConverted: Int = 0

    public init() {}

    /// Bytes actually reclaimed so far. Clamped to zero: a display value must never go
    /// negative, even though the post-flight bloat guard means a recorded pair should
    /// never have output >= input in the first place.
    public var totalBytesSaved: Int64 { max(0, totalInputBytes - totalOutputBytes) }

    /// Folds one more successful conversion into the running total.
    public mutating func record(inputBytes: Int64, outputBytes: Int64) {
        totalInputBytes += inputBytes
        totalOutputBytes += outputBytes
        filesConverted += 1
    }
}

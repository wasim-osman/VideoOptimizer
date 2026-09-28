// LifetimeStatsTests.swift - The cumulative "how much has this app saved you" total.
//
// LifetimeStatsStore (App layer, UserDefaults-backed) has no test target — this is the
// pure accumulation logic it wraps, which is why the logic itself lives here in Core.

import Foundation
import Testing
@testable import VideoOptimizerCore

@Suite("LifetimeStats")
struct LifetimeStatsTests {

    @Test("a fresh instance starts at zero")
    func startsAtZero() {
        let stats = LifetimeStats()
        #expect(stats.totalInputBytes == 0)
        #expect(stats.totalOutputBytes == 0)
        #expect(stats.filesConverted == 0)
        #expect(stats.totalBytesSaved == 0)
    }

    @Test("recording one conversion updates every field")
    func recordingOneConversion() {
        var stats = LifetimeStats()
        stats.record(inputBytes: 1_000_000, outputBytes: 400_000)
        #expect(stats.totalInputBytes == 1_000_000)
        #expect(stats.totalOutputBytes == 400_000)
        #expect(stats.filesConverted == 1)
        #expect(stats.totalBytesSaved == 600_000)
    }

    /// The whole point of this type: it accumulates across every launch, not just the
    /// current session — recording twice must add, never overwrite or average.
    @Test("recording accumulates across multiple conversions, it does not overwrite")
    func recordingAccumulates() {
        var stats = LifetimeStats()
        stats.record(inputBytes: 1_000_000, outputBytes: 400_000)
        stats.record(inputBytes: 2_000_000, outputBytes: 900_000)
        stats.record(inputBytes: 500_000, outputBytes: 500_000)   // a 0-byte-saved file still counts

        #expect(stats.totalInputBytes == 3_500_000)
        #expect(stats.totalOutputBytes == 1_800_000)
        #expect(stats.filesConverted == 3, "every recorded conversion must count, even one that saved nothing")
        #expect(stats.totalBytesSaved == 1_700_000)
    }

    /// The post-flight bloat guard means a real caller should never record output >=
    /// input, but the displayed total must never go negative regardless.
    @Test("totalBytesSaved is clamped to zero, never negative")
    func neverNegative() {
        var stats = LifetimeStats()
        stats.record(inputBytes: 100, outputBytes: 500)
        #expect(stats.totalBytesSaved == 0)
    }

    @Test("many small conversions add up the same as one big one")
    func manySmallConversionsAddUp() {
        var many = LifetimeStats()
        for _ in 0..<10 {
            many.record(inputBytes: 100, outputBytes: 40)
        }
        var one = LifetimeStats()
        one.record(inputBytes: 1000, outputBytes: 400)

        #expect(many.totalBytesSaved == one.totalBytesSaved)
        #expect(many.filesConverted == 10)
        #expect(one.filesConverted == 1, "file count must reflect how many conversions happened, not just the byte total")
    }

    // MARK: - Persistence contract
    //
    // This is not incidental: LifetimeStatsStore persists exactly this JSON shape to
    // UserDefaults across launches, so a round-trip here is a direct test of what
    // actually has to survive an app relaunch.

    @Test("round-trips through JSON exactly, as it will through UserDefaults")
    func codableRoundTrip() throws {
        var original = LifetimeStats()
        original.record(inputBytes: 12_345_678_901, outputBytes: 2_345_678_901)
        original.record(inputBytes: 42, outputBytes: 7)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LifetimeStats.self, from: data)

        #expect(decoded == original)
        #expect(decoded.totalBytesSaved == original.totalBytesSaved)
        #expect(decoded.filesConverted == 2)
    }

    @Test("decoding missing/corrupt data is the caller's problem, not this type's")
    func emptyDataFailsToDecode() {
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(LifetimeStats.self, from: Data())
        }
    }
}

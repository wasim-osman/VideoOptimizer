import Foundation
import VideoOptimizerCore

/// Persists `LifetimeStats` as JSON in UserDefaults. Mirrors SettingsStore's shape —
/// the actual accumulation logic lives in Core (LifetimeStats.record), where it's
/// unit-tested; this is just the UserDefaults glue around it.
@MainActor
final class LifetimeStatsStore {
    static let shared = LifetimeStatsStore()

    private let defaultsKey = "lifetimeStats.v1"

    private(set) var stats: LifetimeStats

    private init() {
        if let data = UserDefaults.standard.data(forKey: "lifetimeStats.v1"),
           let decoded = try? JSONDecoder().decode(LifetimeStats.self, from: data) {
            stats = decoded
        } else {
            stats = LifetimeStats()
        }
    }

    /// Adds one successful conversion's before/after sizes to the running total.
    func record(inputBytes: Int64, outputBytes: Int64) {
        stats.record(inputBytes: inputBytes, outputBytes: outputBytes)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

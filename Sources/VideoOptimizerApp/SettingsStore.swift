import Foundation
import VideoOptimizerCore

/// Persists `Settings` as JSON in UserDefaults and broadcasts changes.
/// The app is unsandboxed (spec §0.1), so a plain folder path is enough — no bookmark needed.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    static let didChange = Notification.Name("VideoOptimizer.settingsDidChange")

    private let defaultsKey = "settings.v1"

    private(set) var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            save()
            NotificationCenter.default.post(name: Self.didChange, object: settings)
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "settings.v1"),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = decoded
        } else {
            settings = Settings()
        }
    }

    func update(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

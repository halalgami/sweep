import Foundation

/// Shared settings between the app, CLI and agent (stored in the app's defaults domain).
public enum SettingsStore {
    public static let suiteName = "dev.algamthe.sweep"
    static let key = "scanSettings"

    public static var defaults: UserDefaults { UserDefaults(suiteName: suiteName) ?? .standard }

    public static func load() -> ScanSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(ScanSettings.self, from: data) else {
            return .defaults()
        }
        return s
    }

    public static func save(_ s: ScanSettings) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
}

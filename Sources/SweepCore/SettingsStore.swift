import Foundation

/// Shared settings between the app, CLI and agent (stored in the app's defaults domain).
public enum SettingsStore {
    public static let suiteName = "dev.algamthe.sweep"
    static let key = "scanSettings"

    /// Inside Sweep.app (the app itself, or the agent embedded in it) the app's own domain is `.standard`;
    /// macOS ignores a suite named after the current bundle. Elsewhere (CLI) read the app's domain as a suite.
    static func usesStandardDomain(mainBundleID: String?) -> Bool { mainBundleID == suiteName }

    public static var defaults: UserDefaults {
        usesStandardDomain(mainBundleID: Bundle.main.bundleIdentifier) ? .standard : (UserDefaults(suiteName: suiteName) ?? .standard)
    }

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

import Foundation

public enum RuleSetError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case let .invalid(s): "Invalid rules file: \(s)" } }
}

public struct RuleSet: Sendable {
    public var rules: [Rule]
    public var warnings: [String] = []

    public init(rules: [Rule]) { self.rules = rules }

    public func rule(_ id: String) -> Rule? { rules.first { $0.id == id } }

    public static let userOverrideURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Sweep/rules.json")

    static let resourceBundleName = "Sweep_SweepCore.bundle"

    /// Finds rules.json without relying on `Bundle.module` (which crashes when the bundle isn't where SwiftPM expects,
    /// e.g. for the agent binary inside Sweep.app/Contents/MacOS).
    static func locateBundledRules(executableDir: URL?, mainResources: URL?) -> URL? {
        var dirs: [URL] = []
        if let mainResources { dirs.append(mainResources) }
        if let exe = executableDir {
            dirs.append(exe)
            dirs.append(exe.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for d in dirs {
            let bundle = d.appendingPathComponent(resourceBundleName)
            for candidate in [bundle.appendingPathComponent("rules.json"), bundle.appendingPathComponent("Contents/Resources/rules.json")]
            where FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public static func bundledData() throws -> Data {
        let exeDir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        if let url = locateBundledRules(executableDir: exeDir, mainResources: Bundle.main.resourceURL) {
            return try Data(contentsOf: url)
        }
        guard let url = Bundle.module.url(forResource: "rules", withExtension: "json") else {
            throw RuleSetError.invalid("bundled rules.json missing")
        }
        return try Data(contentsOf: url)
    }

    public static func bundled() throws -> RuleSet { try load(bundled: bundledData(), override: nil) }

    private struct File: Decodable { var version: Int; var rules: [Entry] }
    private struct Entry: Decodable {
        var rule: Rule?
        var id: String
        var disabled: Bool
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id)
            disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
            rule = disabled ? nil : try Rule(from: decoder)
        }
        enum Keys: String, CodingKey { case id, disabled }
    }

    /// Merge user override into bundled rules by id: same id replaces, `"disabled": true` removes, new ids append.
    public static func load(bundled: Data, override: Data?) throws -> RuleSet {
        func decode(_ d: Data, _ name: String) throws -> File {
            do { return try JSONDecoder().decode(File.self, from: d) }
            catch { throw RuleSetError.invalid("\(name): \(error)") }
        }
        var rules = try decode(bundled, "bundled").rules.compactMap(\.rule)
        if let override {
            for e in try decode(override, "override").rules {
                if let i = rules.firstIndex(where: { $0.id == e.id }) {
                    if let r = e.rule { rules[i] = r } else { rules.remove(at: i) }
                } else if let r = e.rule {
                    rules.append(r)
                }
            }
        }
        return RuleSet(rules: rules)
    }

    /// Never fails: a broken override falls back to bundled rules with a warning.
    public static func loadOrBundled(overrideURL: URL = userOverrideURL) -> RuleSet {
        let bundled = (try? bundledData()) ?? Data(#"{"version":1,"rules":[]}"#.utf8)
        let override = try? Data(contentsOf: overrideURL)
        do { return try load(bundled: bundled, override: override) } catch {
            var set = (try? load(bundled: bundled, override: nil)) ?? RuleSet(rules: [])
            set.warnings.append("Your rules override at \(overrideURL.path) was ignored: \(error)")
            return set
        }
    }
}

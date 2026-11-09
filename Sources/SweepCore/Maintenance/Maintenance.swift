import CryptoKit
import Foundation

/// The exact set of routine rules the user agreed to. Any change to what they do changes the fingerprint.
public struct RoutineManifest: Codable, Sendable, Hashable {
    public var ruleIDs: [String]
    public var fingerprint: String

    public static func current(rules: RuleSet) -> RoutineManifest {
        let routine = rules.rules.filter(\.isRoutine).sorted { $0.id < $1.id }
        let canon = routine.map { r -> String in
            let params: String = (r.params ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            let fields: [String] = [r.id, r.title, r.kind.rawValue, r.tool ?? "", r.action.type, (r.action.command ?? []).joined(separator: " "),
                                    (r.paths ?? []).joined(separator: ","), r.rebuildCost.rawValue, params,
                                    "noProcess=" + (r.requiresNoProcess ?? []).joined(separator: ","),
                                    "appQuit=" + (r.requiresAppQuit ?? []).joined(separator: ","),
                                    "minBytes=" + (r.minBytes.map { String($0) } ?? "")]
            return fields.joined(separator: "|")
        }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(canon.utf8)).map { String(format: "%02x", $0) }.joined()
        return RoutineManifest(ruleIDs: routine.map(\.id), fingerprint: hash)
    }

    public func rules(in set: RuleSet) -> [Rule] { set.rules.filter { ruleIDs.contains($0.id) } }
}

/// Stores which routine manifest the user explicitly acknowledged.
public final class ConsentStore: @unchecked Sendable {
    let defaults: UserDefaults
    static let key = "routineConsentFingerprint", dateKey = "routineConsentDate"
    public init(defaults: UserDefaults = SettingsStore.defaults) { self.defaults = defaults }

    public func acknowledge(_ m: RoutineManifest) {
        defaults.set(m.fingerprint, forKey: Self.key)
        defaults.set(Date(), forKey: Self.dateKey)
    }
    public func revoke() { defaults.removeObject(forKey: Self.key); defaults.removeObject(forKey: Self.dateKey) }
    public func isValid(for m: RoutineManifest) -> Bool { defaults.string(forKey: Self.key) == m.fingerprint }
    public var hasAnyConsent: Bool { defaults.string(forKey: Self.key) != nil }
}

public protocol Notifier: Sendable {
    func notify(title: String, body: String) async
}

/// Posts a macOS notification without a shell (osascript with argv; the text is passed as data, not code).
public struct OSAScriptNotifier: Notifier {
    public init() {}
    public func notify(title: String, body: String) async {
        _ = await ProcessCommandRunner().run("/usr/bin/osascript", [
            "-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run",
            title, body,
        ], timeout: 10)
    }
}

/// Installs the weekly maintenance LaunchAgent.
public struct MaintenanceError: Error, CustomStringConvertible { public var description: String }

public struct LaunchAgentManager: Sendable {
    public static let label = "dev.algamthe.sweep.agent"
    public let home: String
    public let runner: CommandRunner
    public init(home: String = NSHomeDirectory(), runner: CommandRunner = ProcessCommandRunner()) { self.home = home; self.runner = runner }

    public var plistPath: String { "\(home)/Library/LaunchAgents/\(Self.label).plist" }
    public var logPath: String { "\(home)/Library/Logs/Sweep/agent.log" }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    public func plist(agentPath: String, weekday: Int = 1, hour: Int = 10) -> [String: Any] {
        ["Label": Self.label, "ProgramArguments": [agentPath],
         "StartCalendarInterval": ["Weekday": weekday, "Hour": hour, "Minute": 0],
         "StandardOutPath": logPath, "StandardErrorPath": logPath,
         "ProcessType": "Background", "LowPriorityIO": true, "Nice": 10, "RunAtLoad": false]
    }

    public func install(agentPath: String, weekday: Int = 1, hour: Int = 10) async throws {
        try FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist(agentPath: agentPath, weekday: weekday, hour: hour), format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: plistPath))
        let domain = "gui/\(getuid())"
        _ = await runner.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.label)"], timeout: 15)
        let r = await runner.run("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 15)
        if !r.ok { throw MaintenanceError(description: "launchctl bootstrap failed: \(r.stderr)") }
    }

    public func uninstall() async throws {
        _ = await runner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.label)"], timeout: 15)
        if isInstalled { try FileManager.default.removeItem(atPath: plistPath) }
    }

    // Synchronous wrappers for tests and the CLI.
    func installSync(agentPath: String) throws { try blocking { try await install(agentPath: agentPath) } }
    func uninstallSync() throws { try blocking { try await uninstall() } }
    private func blocking(_ op: @escaping @Sendable () async throws -> Void) throws {
        let sem = DispatchSemaphore(value: 0)
        let box = ErrorBox()
        Task.detached { do { try await op() } catch { box.error = error }; sem.signal() }
        sem.wait()
        if let e = box.error { throw e }
    }
}

final class ErrorBox: @unchecked Sendable { var error: Error? }

public enum RoutineOutcome: Sendable {
    case refused(String)
    case ran([ItemResult])
}

/// Runs the routine subset unattended — only if the user acknowledged exactly this routine list.
public struct MaintenanceRunner: Sendable {
    public let context: DetectionContext
    public let rules: RuleSet
    public let consent: ConsentStore
    public let history: HistoryStore?
    public let notifier: Notifier
    public let logURL: URL
    public let includeSystemInfo: Bool

    public init(context: DetectionContext, rules: RuleSet, consent: ConsentStore, history: HistoryStore?, notifier: Notifier,
                logURL: URL = Executor.defaultLogURL(), includeSystemInfo: Bool = true) {
        self.context = context; self.rules = rules; self.consent = consent; self.history = history
        self.notifier = notifier; self.logURL = logURL; self.includeSystemInfo = includeSystemInfo
    }

    public func runRoutine() async -> RoutineOutcome {
        let manifest = RoutineManifest.current(rules: rules)
        guard consent.isValid(for: manifest) else {
            let reason = consent.hasAnyConsent
                ? "The list of routine cleanups changed since you approved it, so the routine sweep is paused."
                : "Routine sweeps aren't turned on."
            await notifier.notify(title: "Sweep", body: "\(reason) Open Sweep to review and turn it back on.")
            return .refused(reason)
        }
        let routineRules = RuleSet(rules: manifest.rules(in: rules))
        let report = await SweepScanner(context: context, rules: routineRules, includeBuckets: false, includeSystemInfo: includeSystemInfo).scanReport()
        let decisions = (try? history?.decisions()) ?? [:]
        let plan = Plan.build(from: report, routineOnly: true, decisions: decisions)
        let guardian = SafetyGuard(context: context, rules: rules,
                                   protected: ProtectedLocations(home: context.home, userProtected: context.settings.protectedPaths))
        let executor = Executor(guardian: guardian, context: context, logURL: logURL)
        var results: [ItemResult] = []
        for await e in executor.execute(plan) { if case let .finished(r) = e { results.append(r) } }
        try? history?.record(report)
        try? history?.recordRun(results, at: Date(), routine: true)

        let done = results.filter { $0.status == .removed || $0.status == .partial }
        let bytes = done.reduce(Int64(0)) { $0 + $1.expectedBytes }
        let names = done.map(\.title).joined(separator: ", ")
        let skipped = results.count - done.count
        var body = done.isEmpty ? "Routine sweep found nothing to clean." : "Routine sweep cleaned \(names) (about \(ByteFormat.string(bytes)))."
        if skipped > 0 { body += " \(skipped) skipped." }
        body += " Details: \(logURL.path.replacingOccurrences(of: context.home, with: "~"))"
        await notifier.notify(title: "Sweep", body: body)
        return .ran(results)
    }
}

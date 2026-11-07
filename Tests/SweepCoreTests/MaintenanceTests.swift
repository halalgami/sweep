import Foundation
import Testing
@testable import SweepCore

final class RecordingNotifier: Notifier, @unchecked Sendable {
    var messages: [String] = []
    func notify(title: String, body: String) async { messages.append(body) }
}

@Suite struct MaintenanceTests {
    func freshDefaults() -> UserDefaults {
        let name = "sweep-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func fingerprintChangesWhenRoutineSetChanges() throws {
        let rules = try RuleSet.bundled()
        let a = RoutineManifest.current(rules: rules)
        var changed = rules
        let i = try #require(changed.rules.firstIndex { $0.id == "cache.uv" })
        changed.rules[i].action.command = ["cache", "clean"]
        #expect(RoutineManifest.current(rules: changed).fingerprint != a.fingerprint)
        var added = rules
        let j = try #require(added.rules.firstIndex { $0.id == "cache.pip" })
        added.rules[j].routine = true
        #expect(RoutineManifest.current(rules: added).ruleIDs.contains("cache.pip"))
        #expect(RoutineManifest.current(rules: added).fingerprint != a.fingerprint)
        #expect(a.ruleIDs == ["cache.brew", "cache.go", "cache.npm", "cache.pnpm", "cache.uv", "cache.xcode-deriveddata", "docker.builder"])
    }

    @Test func consentOnlyValidForAcknowledgedFingerprint() throws {
        let store = ConsentStore(defaults: freshDefaults())
        let m = RoutineManifest.current(rules: try RuleSet.bundled())
        #expect(!store.isValid(for: m))
        store.acknowledge(m)
        #expect(store.isValid(for: m))
        var other = m; other.fingerprint = "different"
        #expect(!store.isValid(for: other))
        store.revoke()
        #expect(!store.isValid(for: m))
    }

    @Test func launchAgentPlistShape() {
        let mgr = LaunchAgentManager(home: "/Users/me", runner: FakeCommandRunner())
        let p = mgr.plist(agentPath: "/Applications/Sweep.app/Contents/MacOS/SweepAgent", weekday: 1, hour: 10)
        #expect(p["Label"] as? String == "dev.algamthe.sweep.agent")
        #expect(p["ProgramArguments"] as? [String] == ["/Applications/Sweep.app/Contents/MacOS/SweepAgent"])
        let cal = p["StartCalendarInterval"] as? [String: Int]
        #expect(cal?["Weekday"] == 1)
        #expect(cal?["Hour"] == 10)
        #expect(p["StandardOutPath"] as? String == "/Users/me/Library/Logs/Sweep/agent.log")
    }

    @Test func installWritesPlistAndBootstraps() throws {
        let t = TempDir()
        let runner = FakeCommandRunner(fallback: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        let mgr = LaunchAgentManager(home: t.path, runner: runner)
        try mgr.installSync(agentPath: "/x/SweepAgent")
        #expect(FileManager.default.fileExists(atPath: t.path + "/Library/LaunchAgents/dev.algamthe.sweep.agent.plist"))
        #expect(runner.calls.contains { $0.hasPrefix("/bin/launchctl bootstrap gui/") })
        try mgr.uninstallSync()
        #expect(!FileManager.default.fileExists(atPath: t.path + "/Library/LaunchAgents/dev.algamthe.sweep.agent.plist"))
    }

    @Test func routineRunRefusesWithoutConsentAndTouchesNothing() async throws {
        let runner = FakeCommandRunner()
        let notifier = RecordingNotifier()
        let ctx = makeContext(runner: runner, tools: ["uv", "npm", "brew"])
        let mr = MaintenanceRunner(context: ctx, rules: try RuleSet.bundled(), consent: ConsentStore(defaults: freshDefaults()),
                                   history: nil, notifier: notifier, logURL: TempDir().url.appendingPathComponent("l"))
        let outcome = await mr.runRoutine()
        guard case .refused = outcome else { Issue.record("must refuse"); return }
        #expect(runner.calls.isEmpty)
        #expect(notifier.messages.first?.contains("Open Sweep") == true)
    }

    @Test func routineRunExecutesOnlyRoutineItemsWithConsent() async throws {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.cache/uv/w/a", logical: 3_000_000_000)
        fs.addFile("/Users/me/Library/Caches/pip/x", logical: 900_000_000)   // not routine
        let runner = FakeCommandRunner()
        runner.stub("/opt/homebrew/bin/uv cache dir", stdout: "/Users/me/.cache/uv\n")
        runner.stub("/opt/homebrew/bin/uv cache prune", stdout: "Removed 10 files\n")
        let consent = ConsentStore(defaults: freshDefaults())
        let rules = try RuleSet.bundled()
        consent.acknowledge(RoutineManifest.current(rules: rules))
        let notifier = RecordingNotifier()
        let mr = MaintenanceRunner(context: makeContext(probe: fs, runner: runner, tools: ["uv"]), rules: rules, consent: consent,
                                   history: nil, notifier: notifier, logURL: TempDir().url.appendingPathComponent("l"), includeSystemInfo: false)
        guard case let .ran(results) = await mr.runRoutine() else { Issue.record("should run"); return }
        #expect(results.map(\.title) == ["uv cache"])
        #expect(runner.calls.contains("/opt/homebrew/bin/uv cache prune"))
        #expect(!runner.calls.contains { $0.contains("pip") })
        #expect(notifier.messages.first?.contains("uv cache") == true)
    }
}

import Foundation
import Testing
@testable import SweepCore

/// Regression tests for the final whole-branch review findings.
@Suite struct ReviewFixTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func leftoversCtx(fs: FakeFileSystemProbe, dump: String, trash: String = "/Users/me/.Trash/Notely.app/\n") -> DetectionContext {
        let runner = FakeCommandRunner()
        runner.stub((["/usr/bin/osascript"] + LeftoversDetector.trashScriptArguments).joined(separator: " "), stdout: trash)
        runner.stub(LeftoversDetector.lsregister + " -dump", stdout: dump)
        runner.stub("/usr/sbin/pkgutil --pkgs", stdout: "")
        return makeContext(probe: fs, runner: runner, tools: ["osascript"], now: now)
    }
    let sep = String(repeating: "-", count: 80)

    // C1
    @Test func appStillInstalledIsNotALeftover() async {
        let fs = FakeFileSystemProbe()
        fs.addDir("/Applications/Notely.app")
        fs.addFile("/Users/me/Library/Application Support/Notely/db.sqlite", logical: 40_000_000)
        fs.addFile("/Users/me/Library/Preferences/io.notely.app.plist", logical: 4_096)
        let dump = """
        \(sep)
        path:                       /Users/me/.Trash/Notely.app (0x1)
        name:                       Notely
        identifier:                 io.notely.app
        \(sep)
        path:                       /Applications/Notely.app (0x2)
        name:                       Notely
        identifier:                 io.notely.app
        """
        let out = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: leftoversCtx(fs: fs, dump: dump))
        #expect(out.items.isEmpty)
    }

    // I4
    @Test func bundleIDMustMatchAsWholeComponent() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Library/Caches/io.notely.application/x", logical: 10_000_000)
        fs.addFile("/Users/me/Library/Preferences/io.notely.app.plist", logical: 4_096)
        fs.addFile("/Users/me/Library/Group Containers/ABCDE12345.io.notely.app/x", logical: 4_096)
        let dump = "\(sep)\npath: /Users/me/.Trash/Notely.app (0x1)\nname: Notely\nidentifier: io.notely.app\n"
        let paths = await DetectorRegistry.detector(for: .leftovers).detect(rule: rule("leftovers.trash"), context: leftoversCtx(fs: fs, dump: dump)).items.map(\.path)
        #expect(!paths.contains { $0.contains("io.notely.application") })
        #expect(paths.contains("/Users/me/Library/Preferences/io.notely.app.plist"))
        #expect(paths.contains("/Users/me/Library/Group Containers/ABCDE12345.io.notely.app"))
    }

    // I2
    @Test func duplicatePathKeepsSensitiveFlagAndNonDestructiveAction() {
        var large = testItem("/Users/me/Documents/c/customers.csv", category: "decision.large-files", tier: .needsDecision, action: .trash, bytes: 2_000_000_000)
        large.sensitive = false
        var sens = testItem("/Users/me/Documents/c/customers.csv", category: "decision.sensitive-data", tier: .needsDecision, action: .revealInFinder, bytes: 2_000_000_000)
        sens.sensitive = true
        let out = SweepScanner.consolidate([large, sens], protected: ProtectedLocations(home: "/Users/me", userProtected: [], iCloudDesktopAndDocuments: false))
        #expect(out.count == 1)
        #expect(out[0].sensitive)
        #expect(out[0].action == .revealInFinder)
        #expect(!out[0].defaultSelected)
    }

    // I3
    @Test func processRunningFromArtifactKeepsProjectActive() async {
        let proj = "/Users/me/Projects/api"
        let fs = FakeFileSystemProbe()
        fs.addFile("\(proj)/pyproject.toml", logical: 10, mtime: now.addingTimeInterval(-40 * 86400))
        fs.addFile("\(proj)/.venv/bin/python", logical: 10_000_000, mtime: now.addingTimeInterval(-40 * 86400))
        let ctx = makeContext(probe: fs, processes: [RunningProcess(pid: 9, ppid: 1, command: "python",
            arguments: ["\(proj)/.venv/bin/python", "-m", "uvicorn", "app:main"], cwd: "/")], now: now)
        let v = await IdleChecker().verdict(project: proj, context: ctx)
        #expect(!v.idle)
    }

    // I5
    @Test func runningVMIsNotActionable() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Parallels/Win.pvm/disk.hdd", logical: 50_000_000_000)
        let ctx = makeContext(probe: fs, processes: [RunningProcess(pid: 4, ppid: 1, command: "prl_vm_app",
            arguments: ["/Applications/Parallels Desktop.app/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app", "--openvm", "/Users/me/Parallels/Win.pvm"], cwd: nil)], now: now)
        let out = await DetectorRegistry.detector(for: .vms).detect(rule: rule("decision.vms"), context: ctx)
        guard case .none? = out.items.first?.action else { Issue.record("running VM must not be actionable"); return }
    }

    // I7
    @Test func tier2WithoutProjectRootIsBlocked() async {
        let t = TempDir()
        let nm = t.dir("loose/node_modules")
        var ctx = makeContext(tools: ["git"]); ctx.home = t.path; ctx.probe = RealFileSystemProbe()
        let g = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: t.path, userProtected: [], iCloudDesktopAndDocuments: false))
        #expect(await g.check(testItem(nm, category: "artifact.projects", tier: .idleArtifact)) != .allowed)
    }

    @Test func monorepoPackageChecksRepoRootGitStatus() async {
        let t = TempDir()
        let old = Date(timeIntervalSinceNow: -40 * 86400)
        _ = t.dir("repo/.git")
        t.file("repo/packages/app/package.json", bytes: 10, mtime: old)
        t.file("repo/packages/app/src/a.ts", bytes: 10, mtime: old)
        let nm = t.dir("repo/packages/app/node_modules")
        let repo = t.path + "/repo"
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/git -C \(repo) log -1 --format=%ct", stdout: "\(Int(old.timeIntervalSince1970))\n")
        runner.stub("/usr/bin/git -C \(repo) status --porcelain", stdout: " M README.md\n")
        var ctx = makeContext(runner: runner, tools: ["git"]); ctx.home = t.path; ctx.probe = RealFileSystemProbe()
        let g = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: t.path, userProtected: [], iCloudDesktopAndDocuments: false))
        #expect(await g.check(testItem(nm, category: "artifact.projects", tier: .idleArtifact)) != .allowed)
    }

    // I8
    @Test func cancelledContextStopsMeasuring() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.cache/big/a.bin", logical: 9_000_000)
        var ctx = makeContext(probe: fs)
        ctx.isCancelled = { true }
        let r = Rule(id: "t", title: "T", tier: .safe, kind: .pathCache, paths: ["~/.cache/big"], action: RuleAction(type: "hardDelete"), rebuildCost: .low, explanation: "x")
        #expect(await PathDetector().detect(rule: r, context: ctx).items.isEmpty)
    }

    // I1
    @Test func planRemovingDropsEntry() {
        let a = testItem("/a"), b = testItem("/b")
        let plan = Plan(entries: [PlanEntry(item: a, selected: true), PlanEntry(item: b, selected: true)])
        #expect(plan.removing(itemID: a.id).entries.map(\.item.path) == ["/b"])
    }
}

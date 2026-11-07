import Foundation
import Testing
@testable import SweepCore

@Suite struct IdleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let proj = "/Users/me/Projects/app"
    func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }

    func setup(sourceDaysAgo: Double, commitDaysAgo: Double?, dirty: Bool = false,
               processes: [RunningProcess] = []) -> (DetectionContext, FakeCommandRunner) {
        let fs = FakeFileSystemProbe()
        fs.addFile("\(proj)/package.json", logical: 100, mtime: daysAgo(sourceDaysAgo + 5))
        fs.addFile("\(proj)/src/index.ts", logical: 100, mtime: daysAgo(sourceDaysAgo))
        fs.addFile("\(proj)/node_modules/react/index.js", logical: 300_000_000, mtime: daysAgo(0))
        fs.addFile("\(proj)/pnpm-lock.yaml", logical: 100, mtime: daysAgo(sourceDaysAgo + 5))
        let runner = FakeCommandRunner()
        if let c = commitDaysAgo {
            fs.addDir("\(proj)/.git")
            runner.stub("/usr/bin/git -C \(proj) log -1 --format=%ct", stdout: "\(Int(daysAgo(c).timeIntervalSince1970))\n")
            runner.stub("/usr/bin/git -C \(proj) status --porcelain", stdout: dirty ? " M src/index.ts\n" : "")
        }
        return (makeContext(probe: fs, runner: runner, processes: processes, tools: ["git"], now: now), runner)
    }

    @Test func idleWhenSourcesAndCommitsOld() async {
        let (ctx, _) = setup(sourceDaysAgo: 20, commitDaysAgo: 30)
        let v = await IdleChecker().verdict(project: proj, context: ctx)
        #expect(v.idle)
        #expect(v.idleDays == 20)
    }

    @Test func recentSourceEditMeansActive() async {
        let (ctx, _) = setup(sourceDaysAgo: 3, commitDaysAgo: 30)
        let v = await IdleChecker().verdict(project: proj, context: ctx)
        #expect(!v.idle)
        #expect(v.reasons.contains { $0.contains("edited 3 days ago") })
    }

    @Test func recentCommitMeansActive() async {
        let (ctx, _) = setup(sourceDaysAgo: 20, commitDaysAgo: 2)
        #expect(!(await IdleChecker().verdict(project: proj, context: ctx)).idle)
    }

    @Test func uncommittedChangesMeanActive() async {
        let (ctx, _) = setup(sourceDaysAgo: 20, commitDaysAgo: 30, dirty: true)
        let v = await IdleChecker().verdict(project: proj, context: ctx)
        #expect(!v.idle)
        #expect(v.reasons.contains { $0.contains("uncommitted") })
    }

    @Test func runningDevServerMeansActive() async {
        let (ctx, _) = setup(sourceDaysAgo: 20, commitDaysAgo: 30, processes: [
            RunningProcess(pid: 5, ppid: 1, command: "node", arguments: ["node", "node_modules/.bin/next", "dev"], cwd: proj)])
        let v = await IdleChecker().verdict(project: proj, context: ctx)
        #expect(!v.idle)
        #expect(v.reasons.contains { $0.contains("dev server") })
    }

    @Test func idleProjectEmitsArtifactItemWithRebuildCommand() async {
        let (ctx, _) = setup(sourceDaysAgo: 20, commitDaysAgo: 30)
        let out = await DetectorRegistry.detector(for: .projectArtifacts).detect(rule: rule("artifact.projects"), context: ctx)
        let item = try! #require(out.items.first)
        #expect(item.path == "\(proj)/node_modules")
        #expect(item.tier == .idleArtifact)
        #expect(item.action == .hardDelete)
        #expect(item.rebuildHint == "pnpm install")
        #expect(item.evidence.contains { $0.contains("idle 20 days") })
    }

    @Test func activeProjectEmitsNothing() async {
        let (ctx, _) = setup(sourceDaysAgo: 1, commitDaysAgo: 30)
        let out = await DetectorRegistry.detector(for: .projectArtifacts).detect(rule: rule("artifact.projects"), context: ctx)
        #expect(out.items.isEmpty)
    }

    @Test func targetOnlyCountsNextToCargoToml() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Projects/web/package.json", logical: 1, mtime: daysAgo(40))
        fs.addFile("/Users/me/Projects/web/target/x.bin", logical: 50_000_000, mtime: daysAgo(40))
        fs.addFile("/Users/me/Projects/rs/Cargo.toml", logical: 1, mtime: daysAgo(40))
        fs.addFile("/Users/me/Projects/rs/target/debug/x", logical: 50_000_000, mtime: daysAgo(40))
        let ctx = makeContext(probe: fs, tools: ["git"], now: now)
        let out = await DetectorRegistry.detector(for: .projectArtifacts).detect(rule: rule("artifact.projects"), context: ctx)
        #expect(out.items.map(\.path) == ["/Users/me/Projects/rs/target"])
    }

    // MARK: worktrees

    func worktreeSetup(status: String, upstream: Bool, ahead: String) -> (DetectionContext, FakeCommandRunner) {
        let fs = FakeFileSystemProbe()
        let repo = "/Users/me/Projects/repo", wt = "/Users/me/Projects/repo-feature"
        fs.addFile("\(repo)/package.json", logical: 1, mtime: daysAgo(1))
        fs.addDir("\(repo)/.git")
        fs.addFile("\(wt)/big.bin", logical: 80_000_000)
        let r = FakeCommandRunner()
        let g = "/usr/bin/git"
        r.stub("\(g) -C \(repo) worktree list --porcelain",
               stdout: "worktree \(repo)\nHEAD aaa\nbranch refs/heads/main\n\nworktree \(wt)\nHEAD bbb\nbranch refs/heads/feature\n\n")
        r.stub("\(g) -C \(wt) status --porcelain", stdout: status)
        if upstream { r.stub("\(g) -C \(wt) rev-parse --abbrev-ref --symbolic-full-name @{u}", stdout: "origin/feature\n") }
        r.stub("\(g) -C \(wt) rev-list --count @{u}..HEAD", stdout: ahead)
        r.stub("\(g) -C \(wt) merge-base --is-ancestor HEAD main", stdout: "")
        return (makeContext(probe: fs, runner: r, tools: ["git"], now: now), r)
    }

    @Test func cleanPushedWorktreeOffered() async {
        let (ctx, _) = worktreeSetup(status: "", upstream: true, ahead: "0\n")
        let out = await DetectorRegistry.detector(for: .gitWorktrees).detect(rule: rule("git.worktrees"), context: ctx)
        let item = try! #require(out.items.first)
        #expect(item.path == "/Users/me/Projects/repo-feature")
        #expect(item.action == .gitWorktreeRemove(repo: "/Users/me/Projects/repo"))
        #expect(item.evidence.contains("merged to main: yes"))
    }

    @Test func dirtyWorktreeNotOffered() async {
        let (ctx, _) = worktreeSetup(status: "?? new.txt\n", upstream: true, ahead: "0\n")
        #expect(await DetectorRegistry.detector(for: .gitWorktrees).detect(rule: rule("git.worktrees"), context: ctx).items.isEmpty)
    }

    @Test func aheadWorktreeNotOffered() async {
        let (ctx, _) = worktreeSetup(status: "", upstream: true, ahead: "2\n")
        #expect(await DetectorRegistry.detector(for: .gitWorktrees).detect(rule: rule("git.worktrees"), context: ctx).items.isEmpty)
    }

    @Test func worktreeWithoutUpstreamNotOffered() async {
        let (ctx, _) = worktreeSetup(status: "", upstream: false, ahead: "0\n")
        #expect(await DetectorRegistry.detector(for: .gitWorktrees).detect(rule: rule("git.worktrees"), context: ctx).items.isEmpty)
    }
}

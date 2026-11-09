import Darwin
import Foundation
import Testing
@testable import SweepCore

/// Regression tests for the pre-release (0.3.0) review findings.
@Suite(.serialized) struct ReleaseReviewTests {
    let docker = "/opt/homebrew/bin/docker"
    let git = "/usr/bin/git"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // R1: an item that *contains* a protected folder must be blocked too.
    @Test func itemContainingProtectedFolderIsBlocked() {
        let p = ProtectedLocations(home: "/Users/me", userProtected: ["~/Library/Caches/com.foo/keep"], iCloudDesktopAndDocuments: false)
        #expect(p.reason(for: "/Users/me/Library/Caches/com.foo") != nil)
        #expect(p.reason(for: "/Users/me/Library/Caches/com.bar") == nil)
        // Prefix lookalikes are not containment.
        #expect(p.reason(for: "/Users/me/Library/Caches/com.fo") == nil)
    }

    // R2: Docker must only ever talk to a local daemon.
    func dockerRunner(endpoint: String) -> FakeCommandRunner {
        let r = FakeCommandRunner()
        r.stub("\(docker) info --format {{.ServerVersion}}", stdout: "27\n")
        r.stub("\(docker) context inspect --format {{.Endpoints.docker.Host}}", stdout: endpoint + "\n")
        r.stub("\(docker) buildx ls --format {{.Name}}", stdout: "default\n")
        r.stub("\(docker) buildx du --builder default --verbose=false", stdout: "Total: 2GB\n")
        return r
    }

    @Test func dockerSkippedWhenContextIsRemote() async {
        let out = await DetectorRegistry.detector(for: .docker).detect(
            rule: rule("docker.builder"), context: makeContext(runner: dockerRunner(endpoint: "tcp://prod.example.com:2376"), tools: ["docker"]))
        #expect(out.items.isEmpty)
        #expect(out.warnings.contains { $0.contains("isn't on this Mac") })
    }

    @Test func dockerCommandBlockedAtRunTimeWhenContextIsRemote() async {
        let ctx = makeContext(runner: dockerRunner(endpoint: "ssh://me@build-box"), tools: ["docker"])
        let g = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: "/Users/me", userProtected: [], iCloudDesktopAndDocuments: false))
        let item = testItem("docker://builder/default", category: "docker.builder", action: .dockerCommand(arguments: ["builder", "prune", "-f"]))
        guard case .blocked = await g.check(item) else { Issue.record("remote docker allowed"); return }
    }

    @Test func dockerCommandAllowedWhenContextIsLocal() async {
        let ctx = makeContext(runner: dockerRunner(endpoint: "unix:///Users/me/.colima/default/docker.sock"), tools: ["docker"])
        let g = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: "/Users/me", userProtected: [], iCloudDesktopAndDocuments: false))
        let item = testItem("docker://builder/default", category: "docker.builder", action: .dockerCommand(arguments: ["builder", "prune", "-f"]))
        #expect(await g.check(item) == .allowed)
    }

    // R3: `git worktree remove` deletes ignored files permanently; personal ones must stop it.
    func worktreeCtx(ignored: String) -> DetectionContext {
        let fs = FakeFileSystemProbe()
        let repo = "/Users/me/Projects/repo", wt = "/Users/me/Projects/repo-feature"
        fs.addFile("\(repo)/package.json", logical: 1, mtime: now.addingTimeInterval(-86400))
        fs.addDir("\(repo)/.git")
        fs.addFile("\(wt)/big.bin", logical: 80_000_000)
        let r = FakeCommandRunner()
        r.stub("\(git) -C \(repo) worktree list --porcelain",
               stdout: "worktree \(repo)\nHEAD aaa\nbranch refs/heads/main\n\nworktree \(wt)\nHEAD bbb\nbranch refs/heads/feature\n\n")
        r.stub("\(git) -C \(wt) status --porcelain --ignored", stdout: ignored)
        r.stub("\(git) -C \(wt) rev-parse --abbrev-ref --symbolic-full-name @{u}", stdout: "origin/feature\n")
        r.stub("\(git) -C \(wt) rev-list --count @{u}..HEAD", stdout: "0\n")
        r.stub("\(git) -C \(wt) merge-base --is-ancestor HEAD main", stdout: "")
        return makeContext(probe: fs, runner: r, tools: ["git"], now: now)
    }

    @Test func worktreeWithIgnoredPersonalFileIsNotRemovable() async {
        let out = await DetectorRegistry.detector(for: .gitWorktrees).detect(rule: rule("git.worktrees"), context: worktreeCtx(ignored: "!! .env\n!! node_modules/\n"))
        guard let item = out.items.first else { Issue.record("worktree not listed"); return }
        #expect(item.action == .revealInFinder)
        #expect(item.evidence.contains { $0.contains(".env") })
    }

    @Test func worktreeWithOnlyBuildFoldersIgnoredIsRemovable() async {
        let out = await DetectorRegistry.detector(for: .gitWorktrees).detect(rule: rule("git.worktrees"), context: worktreeCtx(ignored: "!! node_modules/\n!! .next/\n"))
        #expect(out.items.first?.action == .gitWorktreeRemove(repo: "/Users/me/Projects/repo"))
    }

    @Test func worktreeRemovalBlockedAtRunTimeWhenPersonalIgnoredFileAppears() async {
        let t = TempDir()
        let wt = t.dir("wt")
        let r = FakeCommandRunner()
        r.stub("\(git) -C \(wt) status --porcelain --ignored", stdout: "!! secrets.json\n")
        var ctx = makeContext(runner: r, tools: ["git"])
        ctx.home = t.path; ctx.probe = RealFileSystemProbe()
        let g = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: t.path, userProtected: [], iCloudDesktopAndDocuments: false))
        guard case .blocked = await g.check(testItem(wt, category: "git.worktrees", tier: .idleArtifact, action: .gitWorktreeRemove(repo: t.path))) else {
            Issue.record("worktree with ignored personal file allowed"); return
        }
    }

    @Test func sensitiveChildMakesParentRevealOnly() {
        let parent = testItem("/Users/me/Projects/repo-feature", category: "git.worktrees", tier: .idleArtifact, action: .gitWorktreeRemove(repo: "/Users/me/Projects/repo"))
        var child = testItem("/Users/me/Projects/repo-feature/data/customers.csv", category: "decision.sensitive-data", tier: .needsDecision, action: .revealInFinder)
        child.sensitive = true
        let out = SweepScanner.consolidate([parent, child], protected: ProtectedLocations(home: "/Users/me", userProtected: [], iCloudDesktopAndDocuments: false))
        #expect(out.count == 1)
        #expect(out[0].sensitive)
        #expect(out[0].action == .revealInFinder)
        #expect(!out[0].defaultSelected)
    }

    // R4: deleting never crosses into another mounted volume.
    @Test func deleteTreeDoesNotCrossMountPoints() throws {
        let t = TempDir()
        let root = t.dir("cache")
        t.file("cache/a.bin", bytes: 1000)
        let mnt = t.dir("cache/mnt")
        let img = t.path + "/vol.dmg"
        #expect(Self.sh("/usr/bin/hdiutil", ["create", "-size", "2m", "-fs", "HFS+", "-volname", "SweepTest", "-quiet", img]) == 0)
        #expect(Self.sh("/usr/bin/hdiutil", ["attach", img, "-nobrowse", "-quiet", "-mountpoint", mnt]) == 0)
        defer { _ = Self.sh("/usr/bin/hdiutil", ["detach", mnt, "-force", "-quiet"]) }
        let keep = mnt + "/keep.txt"
        FileManager.default.createFile(atPath: keep, contents: Data("x".utf8))
        let r = Executor.deleteTree(root)
        #expect(FileManager.default.fileExists(atPath: keep))
        #expect(!FileManager.default.fileExists(atPath: root + "/a.bin"))
        #expect(r.otherVolume >= 1)
    }

    // R9: files written during the delete leave the folder behind; that's not "removed".
    @Test func deleteTreeReportsFilesThatAppearedDuringDelete() {
        let t = TempDir()
        let root = t.dir("cache")
        t.file("cache/sub/a.bin", bytes: 1000)
        let r = Executor.deleteTree(root, beforeRemovingDirectory: { dir in
            if dir == root { FileManager.default.createFile(atPath: root + "/late.bin", contents: Data("x".utf8)) }
        })
        #expect(r.leftBehind)
        #expect(FileManager.default.fileExists(atPath: root + "/late.bin"))
    }

    // R10: protection is judged on the resolved path too (/etc → /private/etc).
    @Test func etcPathIsBlockedThroughItsResolvedLocation() async {
        let t = TempDir()
        var ctx = makeContext()
        ctx.home = t.path; ctx.probe = RealFileSystemProbe()
        let g = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: t.path, userProtected: [], iCloudDesktopAndDocuments: false))
        guard case .blocked = await g.check(testItem("/etc/hosts")) else { Issue.record("/etc/hosts allowed"); return }
    }

    // R5: a cleanup command reports what it actually freed, not the whole scanned size.
    @Test func toolCommandReportsRemeasuredFreedBytes() async throws {
        let t = TempDir()
        let cache = t.dir("Library/Caches/uv")
        t.file("Library/Caches/uv/a.bin", bytes: 40_000)
        let runner = FakeCommandRunner()
        runner.stub("/opt/homebrew/bin/uv cache prune", stdout: "Nothing to prune\n")
        var ctx = makeContext(tools: ["uv"])
        ctx.home = t.path; ctx.probe = RealFileSystemProbe(); ctx.runner = runner
        let guardian = SafetyGuard(context: ctx, rules: guardRules, protected: ProtectedLocations(home: t.path, userProtected: [], iCloudDesktopAndDocuments: false))
        let ex = Executor(guardian: guardian, context: ctx, logURL: t.url.appendingPathComponent("log.txt"))
        let item = testItem(cache, category: "cache.uv", action: .toolCommand(executable: "/opt/homebrew/bin/uv", arguments: ["cache", "prune"]), bytes: 40_960)
        var results: [ItemResult] = []
        for await e in ex.execute(Plan(entries: [PlanEntry(item: item, selected: true)])) { if case let .finished(r) = e { results.append(r) } }
        let r = try #require(results.first)
        #expect(r.status == .removed)
        #expect(r.expectedBytes == 0)
    }

    // R6: names that identify clients or projects don't reach the AI, wherever they live.
    @Test func identifyingTitlesAreRedactedOutsideSensitiveRoots() {
        let red = Redactor(home: "/Users/me", sensitiveRoots: ["/Users/me/Documents"], revealNames: false)
        let items = [
            testItem("docker://image/abc", category: "docker.images", tier: .needsDecision, action: .dockerCommand(arguments: ["image", "rm", "x"])),
            testItem("/Users/me/Parallels/ClientX Win11.pvm", category: "decision.vms", tier: .needsDecision, action: .trash),
            testItem("/Users/me/work/client-billing-feature", category: "git.worktrees", tier: .idleArtifact, action: .gitWorktreeRemove(repo: "/Users/me/work/client-billing")),
        ].enumerated().map { i, item -> Item in
            var it = item
            it.title = ["Docker image 1234.dkr.ecr.aws/client-billing:prod", "ClientX Win11", "Worktree client-billing-feature"][i]
            it.evidence = ["upstream origin/client-billing/feature"]
            return it
        }
        let report = ScanReport(scannedAt: Date(), volume: VolumeSummary(totalBytes: 100, availableBytes: 10, importantAvailableBytes: 10, usedBytes: 90),
                                apfs: [], buckets: [], unaccountedBytes: 0, fullDiskAccess: true, snapshots: [], items: items, rootCauses: [], warnings: [])
        let json = InsightsSummary.build(report: report, growth: [:], declines: [:], redactor: red).json()
        #expect(!json.contains("client-billing"))
        #expect(!json.contains("ClientX"))
        let revealed = InsightsSummary.build(report: report, growth: [:], declines: [:],
                                             redactor: Redactor(home: "/Users/me", sensitiveRoots: [], revealNames: true)).json()
        #expect(revealed.contains("ClientX"))
    }

    static func sh(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}


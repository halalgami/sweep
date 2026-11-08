import Foundation
import Testing
@testable import SweepCore

func testItem(_ path: String, category: String = "t.cache", tier: Tier = .safe, action: ItemAction = .hardDelete,
              bytes: Int64 = 1_000, routine: Bool = false, selected: Bool = true, cost: RebuildCost = .low) -> Item {
    Item(id: Item.makeID(category: category, key: path), category: category, title: (path as NSString).lastPathComponent, path: path,
         logicalBytes: bytes, physicalBytes: bytes, lastModified: nil, lastUsedSignal: nil, tier: tier, action: action,
         rebuildCost: cost, rebuildHint: nil, evidence: [], routine: routine, defaultSelected: selected, sensitive: false)
}

@Suite struct SafetyGuardTests {
    func realGuard(home: String, protectedPaths: [String] = [], rules: RuleSet = RuleSet(rules: []),
                   processes: [RunningProcess] = [], runner: FakeCommandRunner = FakeCommandRunner()) -> SafetyGuard {
        var ctx = makeContext(runner: runner, processes: processes, tools: ["git", "docker"],
                              settings: ScanSettings(projectRoots: [], protectedPaths: protectedPaths))
        ctx.home = home
        ctx.probe = RealFileSystemProbe()
        return SafetyGuard(context: ctx, rules: rules, protected: ProtectedLocations(home: home, userProtected: protectedPaths, iCloudDesktopAndDocuments: false))
    }

    @Test func allowsOrdinaryCacheDir() async {
        let t = TempDir()
        let cache = t.dir("Library/Caches/com.x")
        #expect(await realGuard(home: t.path).check(testItem(cache)) == .allowed)
    }

    @Test func blocksSymlinkSwappedIntoKeychains() async throws {
        let t = TempDir()
        let keychains = t.dir("Library/Keychains")
        _ = t.dir("Library/Caches")
        try FileManager.default.createSymbolicLink(atPath: t.path + "/Library/Caches/com.x", withDestinationPath: keychains)
        let v = await realGuard(home: t.path).check(testItem(t.path + "/Library/Caches/com.x"))
        guard case let .blocked(reason) = v else { Issue.record("should block"); return }
        #expect(reason.contains("link"))
    }

    @Test func blocksPathInsideSymlinkedParentPointingToProtected() async throws {
        let t = TempDir()
        let keychains = t.dir("Library/Keychains")
        t.file("Library/Keychains/login.keychain-db", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: t.path + "/sneaky", withDestinationPath: keychains)
        let v = await realGuard(home: t.path).check(testItem(t.path + "/sneaky/login.keychain-db"))
        #expect(v != .allowed)
    }

    @Test func blocksVanishedPath() async {
        let t = TempDir()
        let v = await realGuard(home: t.path).check(testItem(t.path + "/gone"))
        #expect(v == .blocked("It no longer exists"))
    }

    @Test func blocksUserProtectedAndTier4AndNone() async {
        let t = TempDir()
        let keep = t.dir("keep/cache")
        let g = realGuard(home: t.path, protectedPaths: [t.path + "/keep"])
        #expect(await g.check(testItem(keep)) != .allowed)
        let other = t.dir("other")
        #expect(await g.check(testItem(other, tier: .protected)) != .allowed)
        #expect(await g.check(testItem(other, action: .none(reason: "x"))) != .allowed)
        #expect(await g.check(testItem(other, action: .revealInFinder)) != .allowed)
    }

    @Test func blocksWhenRequiredProcessStartsAfterPlanning() async {
        let t = TempDir()
        let npx = t.dir(".npm/_npx")
        let r = rule("cache.npx")
        let g = realGuard(home: t.path, rules: RuleSet(rules: [r]), processes: [
            RunningProcess(pid: 3, ppid: 1, command: "node", arguments: ["node", "npm", "exec", "x"], cwd: nil)])
        #expect(await g.check(testItem(npx, category: "cache.npx")) != .allowed)
    }

    @Test func blocksTier2WhenProjectBecameActive() async {
        let t = TempDir()
        t.file("app/package.json", bytes: 10)
        t.file("app/src/index.ts", bytes: 10)          // edited just now
        let nm = t.dir("app/node_modules")
        let v = await realGuard(home: t.path).check(testItem(nm, category: "artifact.projects", tier: .idleArtifact))
        guard case let .blocked(reason) = v else { Issue.record("should block"); return }
        #expect(reason.contains("active"))
    }

    @Test func blocksDirtyWorktreeAtExecution() async {
        let t = TempDir()
        let wt = t.dir("wt")
        let runner = FakeCommandRunner()
        runner.stub("/usr/bin/git -C \(wt) status --porcelain --ignored", stdout: " M file\n")
        let v = await realGuard(home: t.path, runner: runner).check(testItem(wt, category: "git.worktrees", tier: .idleArtifact,
                                                                              action: .gitWorktreeRemove(repo: t.path)))
        #expect(v != .allowed)
    }

    @Test func dockerCommandsAreAllowlisted() async {
        let t = TempDir()
        let local = FakeCommandRunner()
        local.stub("/opt/homebrew/bin/docker context inspect --format {{.Endpoints.docker.Host}}", stdout: "unix:///var/run/docker.sock\n")
        let g = realGuard(home: t.path, runner: local)
        #expect(await g.check(testItem("docker://builder/default", action: .dockerCommand(arguments: ["buildx", "prune", "-f", "--builder", "default"]))) == .allowed)
        #expect(await g.check(testItem("docker://x", action: .dockerCommand(arguments: ["volume", "prune", "-f"]))) != .allowed)
        #expect(await g.check(testItem("docker://x", action: .dockerCommand(arguments: ["system", "prune", "-af", "--volumes"]))) != .allowed)
    }

    @Test func refusesWholeHomeOrBucketRoot() async {
        let t = TempDir()
        let g = realGuard(home: t.path)
        _ = t.dir("Library/Caches")
        #expect(await g.check(testItem(t.path)) != .allowed)
        #expect(await g.check(testItem(t.path + "/Library/Caches")) != .allowed)
    }
}

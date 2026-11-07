import Foundation
import Testing
@testable import SweepCore

@Suite struct PlanTests {
    func report(_ items: [Item]) -> ScanReport {
        ScanReport(scannedAt: Date(), volume: VolumeSummary(totalBytes: 100, availableBytes: 10, importantAvailableBytes: 10, usedBytes: 90),
                   apfs: [], buckets: [], unaccountedBytes: 0, fullDiskAccess: true, snapshots: [], items: items, rootCauses: [], warnings: [])
    }

    @Test func tierOneBatchSelectedOthersNeedPerItemConfirm() {
        let plan = Plan.build(from: report([
            testItem("/a", tier: .safe), testItem("/b", tier: .idleArtifact), testItem("/c", tier: .needsDecision, action: .trash),
            testItem("/d", tier: .safe, selected: false, cost: .high), testItem("/e", tier: .protected, action: .none(reason: "x")),
        ]), routineOnly: false, decisions: [:])
        #expect(plan.entries.map(\.item.path) == ["/a", "/d", "/b", "/c"])
        #expect(plan.entries.map(\.selected) == [true, false, false, false])
    }

    @Test func routineOnlyKeepsRoutineTierOneItems() {
        let plan = Plan.build(from: report([testItem("/r", routine: true), testItem("/n"), testItem("/t2", tier: .idleArtifact)]),
                              routineOnly: true, decisions: [:])
        #expect(plan.entries.map(\.item.path) == ["/r"])
        #expect(plan.entries.allSatisfy { $0.selected })
    }

    @Test func keepDecisionsHideItemsUntilExpiry() {
        let a = testItem("/a"), b = testItem("/b")
        let now = Date()
        let decisions = [a.id: Decision(itemID: a.id, kind: .keep, createdAt: now, expiresAt: now.addingTimeInterval(86400)),
                         b.id: Decision(itemID: b.id, kind: .keep, createdAt: now, expiresAt: now.addingTimeInterval(-1))]
        let plan = Plan.build(from: report([a, b]), routineOnly: false, decisions: decisions, now: now)
        #expect(plan.entries.map(\.item.path) == ["/b"])
    }

    @Test func totalsSplitFreedAndTrashed() {
        var plan = Plan.build(from: report([testItem("/a", bytes: 100), testItem("/c", tier: .needsDecision, action: .trash, bytes: 50)]),
                              routineOnly: false, decisions: [:])
        plan.entries[1].selected = true
        #expect(plan.expectedFreedBytes == 100)
        #expect(plan.toTrashBytes == 50)
    }
}

@Suite struct ExecutorTests {
    func executor(home: String, runner: CommandRunner = ProcessCommandRunner(), log: URL) -> Executor {
        var ctx = makeContext(tools: ["git"])
        ctx.home = home
        ctx.probe = RealFileSystemProbe()
        ctx.runner = runner
        let guardian = SafetyGuard(context: ctx, rules: RuleSet(rules: []), protected: ProtectedLocations(home: home, userProtected: [], iCloudDesktopAndDocuments: false))
        return Executor(guardian: guardian, context: ctx, logURL: log)
    }

    func run(_ ex: Executor, _ plan: Plan) async -> [ItemResult] {
        var results: [ItemResult] = []
        for await e in ex.execute(plan) { if case let .finished(r) = e { results.append(r) } }
        return results
    }

    @Test func hardDeleteReportsPartialWhenSomeFilesProtected() async throws {
        let t = TempDir()
        t.file("Library/Caches/c/a.bin", bytes: 1000)
        t.file("Library/Caches/c/sub/b.bin", bytes: 1000)
        let locked = t.file("Library/Caches/c/sub/locked.bin", bytes: 1000)
        #expect(chflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked, 0) }
        let item = testItem(t.path + "/Library/Caches/c")
        let results = await run(executor(home: t.path, log: t.url.appendingPathComponent("log.txt")),
                                Plan(entries: [PlanEntry(item: item, selected: true)]))
        let r = try #require(results.first)
        #expect(r.status == .partial)
        #expect(r.removedPaths == 2)
        #expect(r.protectedPaths >= 1)
        #expect(FileManager.default.fileExists(atPath: locked))
        #expect(!FileManager.default.fileExists(atPath: t.path + "/Library/Caches/c/a.bin"))
        let log = try String(contentsOf: t.url.appendingPathComponent("log.txt"), encoding: .utf8)
        #expect(log.contains("partial"))
    }

    @Test func unselectedEntriesAreNeverTouched() async {
        let t = TempDir()
        let f = t.file("Library/Caches/keep/a.bin", bytes: 10)
        let results = await run(executor(home: t.path, log: t.url.appendingPathComponent("l")),
                                Plan(entries: [PlanEntry(item: testItem(t.path + "/Library/Caches/keep"), selected: false)]))
        #expect(results.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f))
    }

    @Test func trashMovesToTrash() async throws {
        let t = TempDir()
        let name = "sweep-trash-test-\(UUID().uuidString).bin"
        let f = t.file("Downloads/\(name)", bytes: 10)
        let results = await run(executor(home: t.path, log: t.url.appendingPathComponent("l")),
                                Plan(entries: [PlanEntry(item: testItem(f, tier: .needsDecision, action: .trash), selected: true)]))
        #expect(results.first?.status == .trashed)
        #expect(!FileManager.default.fileExists(atPath: f))
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(name)").path
        try? FileManager.default.removeItem(atPath: trashed)
    }

    @Test func toolCommandFailureIsReportedWithStderr() async {
        let t = TempDir()
        let runner = FakeCommandRunner()
        runner.stub("/opt/homebrew/bin/uv cache prune", CommandResult(exitCode: 2, stdout: "", stderr: "error: cache is locked"))
        let item = testItem("/opt/homebrew/bin/uv-cache", action: .toolCommand(executable: "/opt/homebrew/bin/uv", arguments: ["cache", "prune"]))
        let results = await run(executor(home: t.path, runner: runner, log: t.url.appendingPathComponent("l")),
                                Plan(entries: [PlanEntry(item: item, selected: true)]))
        #expect(results.first?.status == .failed)
        #expect(results.first?.message.contains("cache is locked") == true)
    }

    @Test func blockedItemsAreReportedNotExecuted() async {
        let t = TempDir()
        let results = await run(executor(home: t.path, log: t.url.appendingPathComponent("l")),
                                Plan(entries: [PlanEntry(item: testItem(t.path + "/nope"), selected: true)]))
        #expect(results.first?.status == .blocked)
    }

    @Test func verificationSplitsFreedTrashedAndFlagsLag() {
        let before = VolumeSummary(totalBytes: 1000, availableBytes: 100, importantAvailableBytes: 100, usedBytes: 900)
        let after = VolumeSummary(totalBytes: 1000, availableBytes: 120, importantAvailableBytes: 120, usedBytes: 880)
        let results = [ItemResult(itemID: "a", title: "a", status: .removed, removedPaths: 1, protectedPaths: 0, failedPaths: 0, message: "", expectedBytes: 100),
                       ItemResult(itemID: "b", title: "b", status: .trashed, removedPaths: 1, protectedPaths: 0, failedPaths: 0, message: "", expectedBytes: 40),
                       ItemResult(itemID: "c", title: "c", status: .failed, removedPaths: 0, protectedPaths: 0, failedPaths: 1, message: "", expectedBytes: 70)]
        let v = Verifier.verification(before: before, after: after, results: results)
        #expect(v.expectedBytes == 100)
        #expect(v.trashedBytes == 40)
        #expect(v.freedNowBytes == 20)
        #expect(v.lagLikely)
    }
}

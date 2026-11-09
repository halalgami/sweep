import Foundation
import Testing
@testable import SweepCore

/// Regression tests for the minor findings deferred from the 0.3.0 review.
@Suite(.serialized) struct DeferredFixTests {
    func cacheRule(_ id: String = "t.routine", minBytes: Int64? = nil, noProcess: [String]? = nil, appQuit: [String]? = nil) -> Rule {
        Rule(id: id, title: "Test cache", tier: .safe, kind: .pathCache, paths: ["~/.cache/t"], action: RuleAction(type: "hardDelete"),
             rebuildCost: .low, explanation: "test", routine: true, requiresNoProcess: noProcess, requiresAppQuit: appQuit, minBytes: minBytes)
    }

    // D1: loosening a routine rule's safety conditions must invalidate consent.
    @Test func consentFingerprintCoversBlockersAndMinBytes() {
        let base = RoutineManifest.current(rules: RuleSet(rules: [cacheRule(minBytes: 1_000_000, noProcess: ["uv"], appQuit: ["Xcode"])])).fingerprint
        let variants = [cacheRule(minBytes: 1, noProcess: ["uv"], appQuit: ["Xcode"]),
                        cacheRule(minBytes: 1_000_000, noProcess: [], appQuit: ["Xcode"]),
                        cacheRule(minBytes: 1_000_000, noProcess: ["uv"], appQuit: nil)]
        for v in variants {
            #expect(RoutineManifest.current(rules: RuleSet(rules: [v])).fingerprint != base)
        }
    }

    // D2: an item whose rule was removed (e.g. from the user's override) must not run.
    @Test func itemWhoseRuleWasRemovedIsBlocked() async throws {
        let t = try TempDir()
        let dir = t.dir("Library/Caches/com.example.gone")
        try Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: dir + "/f"))
        var ctx = makeContext()
        ctx.home = t.path; ctx.probe = RealFileSystemProbe()
        let protected = ProtectedLocations(home: t.path, userProtected: [], iCloudDesktopAndDocuments: false)
        let item = testItem(dir, category: "cache.gone")
        let withRule = SafetyGuard(context: ctx, rules: RuleSet(rules: [cacheRule("cache.gone")]), protected: protected)
        #expect(await withRule.check(item) == .allowed)
        let without = SafetyGuard(context: ctx, rules: RuleSet(rules: []), protected: protected)
        guard case let .blocked(reason) = await without.check(item) else { Issue.record("item without a rule allowed"); return }
        #expect(reason.contains("rule"))
    }

    // D3: the fstrim helper image must be pinned by digest, not a moving tag.
    @Test func trimImageIsPinnedByDigest() {
        let image = DockerDetector.trimArguments.first { $0.hasPrefix("alpine") }
        #expect(image?.contains("@sha256:") == true)
        #expect(SafetyGuard.dockerAllowed(DockerDetector.trimArguments))
        var unpinned = DockerDetector.trimArguments
        if let i = unpinned.firstIndex(where: { $0.hasPrefix("alpine") }) { unpinned[i] = "alpine" }
        #expect(!SafetyGuard.dockerAllowed(unpinned))
    }

    // D4: long filesystem walks must not run on Swift's cooperative thread pool.
    final class RecordingProbe: FileSystemProbe, @unchecked Sendable {
        let base = RealFileSystemProbe()
        let lock = NSLock()
        var onPool: Set<String> = [], listed: Set<String> = []
        func record(_ path: String) {
            let pool = String(cString: __dispatch_queue_get_label(nil)).contains("cooperative")
            lock.withLock { listed.insert(path); if pool { onPool.insert(path) } }
        }
        func meta(_ path: String) -> FileMeta? { base.meta(path) }
        func children(_ path: String) -> [String]? { record(path); return base.children(path) }
        func isDeletable(_ path: String) -> Bool { base.isDeletable(path) }
        func entries(_ path: String) -> [DirEntry]? { record(path); return base.entries(path) }
    }

    @Test func scanWalksRunOffTheCooperativePool() async throws {
        let t = try TempDir()
        let files = ["Projects/app/package.json", "Projects/app/src/deep/x.ts", "Projects/app/node_modules/pkg/index.js",
                     "Projects/group/inner/proj/Cargo.toml", "Library/Caches/com.x/sub/file",
                     ".claude/plugins/a/b/.mcp.json", "Downloads/f1/f2/file.bin"]
        for f in files {
            _ = t.dir((f as NSString).deletingLastPathComponent)
            try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: t.path + "/" + f))
        }
        let deep = ["Projects/app/src/deep", "Projects/group/inner", "Library/Caches/com.x/sub", ".claude/plugins/a/b", "Downloads/f1/f2"]
            .map { t.path + "/" + $0 }
        let probe = RecordingProbe()
        var ctx = makeContext(settings: ScanSettings(projectRoots: [t.path + "/Projects"]))
        ctx.home = t.path; ctx.probe = probe
        _ = await SweepScanner(context: ctx, rules: try RuleSet.bundled(), includeBuckets: false, includeSystemInfo: false).scanReport()
        let notWalked = deep.filter { !probe.listed.contains($0) }, onPool = deep.filter { probe.onPool.contains($0) }
        #expect(notWalked.isEmpty)
        #expect(onPool.isEmpty)
    }

    // D5: a missing resource bundle must throw, not crash via Bundle.module.
    @Test func missingBundledRulesThrows() throws {
        let t = try TempDir()
        #expect(throws: RuleSetError.self) { try RuleSet.bundledData(searchDirs: [t.url]) }
        #expect(try RuleSet.bundled().rules.count > 30)
    }
}

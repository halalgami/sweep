import Foundation
import Testing
@testable import SweepCore

@Suite struct ScannerTests {
    func rulesJSON(_ rules: [Rule]) -> RuleSet { RuleSet(rules: rules) }

    @Test func scanCollectsSortsAndCollapsesNestedItems() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/.cache/big/a.bin", logical: 9_000_000)
        fs.addFile("/Users/me/.cache/big/inner/b.bin", logical: 2_000_000)
        fs.addFile("/Users/me/.cache/small/a.bin", logical: 3_000_000)
        let outer = Rule(id: "t.outer", title: "Outer", tier: .safe, kind: .pathCache, paths: ["~/.cache/big", "~/.cache/small"],
                         action: RuleAction(type: "hardDelete"), rebuildCost: .low, explanation: "x")
        let inner = Rule(id: "t.inner", title: "Inner", tier: .safe, kind: .pathCache, paths: ["~/.cache/big/inner"],
                         action: RuleAction(type: "hardDelete"), rebuildCost: .low, explanation: "x")
        let scanner = SweepScanner(context: makeContext(probe: fs), rules: rulesJSON([outer, inner]), includeBuckets: false, includeSystemInfo: false)
        let report = await scanner.scanReport()
        #expect(report.items.map(\.path) == ["/Users/me/.cache/big", "/Users/me/.cache/small"])
        #expect(report.items[0].physicalBytes == 11_000_000)
    }

    @Test func samePathKeepsEarlierRule() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/Library/Caches/Homebrew/x.tgz", logical: 90_000_000)
        let specific = Rule(id: "cache.brewish", title: "Homebrew", tier: .safe, kind: .pathCache, paths: ["~/Library/Caches/Homebrew"],
                            action: RuleAction(type: "hardDelete"), rebuildCost: .low, explanation: "x")
        let library = rule("cache.library")
        let report = await SweepScanner(context: makeContext(probe: fs), rules: rulesJSON([specific, library]),
                                   includeBuckets: false, includeSystemInfo: false).scanReport()
        #expect(report.items.map(\.category) == ["cache.brewish"])
    }

    @Test func itemsInsideProtectedPathsBecomeTier4() async {
        let fs = FakeFileSystemProbe()
        fs.addFile("/Users/me/keep/cache/a.bin", logical: 9_000_000)
        let r = Rule(id: "t.keep", title: "K", tier: .safe, kind: .pathCache, paths: ["~/keep/cache"],
                     action: RuleAction(type: "hardDelete"), rebuildCost: .low, explanation: "x")
        let ctx = makeContext(probe: fs, settings: ScanSettings(projectRoots: [], protectedPaths: ["/Users/me/keep"]))
        let report = await SweepScanner(context: ctx, rules: rulesJSON([r]), includeBuckets: false, includeSystemInfo: false).scanReport()
        #expect(report.items.first?.tier == .protected)
        #expect(report.items.first?.action.isActionable == false)
    }

    @Test func streamEmitsPhasesAndFinished() async {
        let scanner = SweepScanner(context: makeContext(), rules: rulesJSON([]), includeBuckets: false, includeSystemInfo: false)
        var sawFinished = false, phases = 0
        for await e in scanner.scan() {
            switch e { case .phase: phases += 1; case .finished: sawFinished = true; default: break }
        }
        #expect(sawFinished)
        #expect(phases > 0)
    }
}

@Suite struct RootCauseTests {
    @Test func findsLatestResolversAndDuplicates() throws {
        let home = try #require(Bundle.module.url(forResource: "Fixtures/home", withExtension: nil)).path
        var ctx = makeContext(probe: FakeFileSystemProbe())
        ctx.home = home
        ctx.probe = RealFileSystemProbe()
        let hints = RootCauseAnalyzer().analyze(context: ctx)
        let latest = hints.filter { $0.kind == "latestResolver" }
        #expect(latest.contains { $0.detail.contains("mcp-server-fetch@latest") && $0.relatedCategory == "cache.uv" })
        #expect(latest.contains { $0.detail.contains("context7") && $0.relatedCategory == "cache.npx" })
        #expect(hints.contains { $0.kind == "duplicateMCP" && $0.detail.contains("mcp-server-git") })
        #expect(!hints.contains { $0.detail.contains(home) })   // paths shown with ~
    }

    @Test func findsOrphanedMCPProcesses() {
        let ctx = makeContext(processes: [
            RunningProcess(pid: 77, ppid: 1, command: "node", arguments: ["node", "/x/npx", "@modelcontextprotocol/server-github"], cwd: nil),
            RunningProcess(pid: 78, ppid: 500, command: "node", arguments: ["node", "/x/npx", "@modelcontextprotocol/server-x"], cwd: nil),
        ])
        let hints = RootCauseAnalyzer().analyze(context: ctx)
        #expect(hints.filter { $0.kind == "orphanMCP" }.map(\.detail).joined().contains("77"))
        #expect(!hints.filter { $0.kind == "orphanMCP" }.map(\.detail).joined().contains("78"))
    }
}

@Suite struct RootCauseGroupingTests {
    @Test func sameLatestPackageInManyFilesIsOneHint() throws {
        let t = TempDir()
        for d in ["a", "b", "c"] {
            let dir = t.dir(".claude/plugins/\(d)")
            try #"{"mcpServers":{"pw":{"command":"npx","args":["@playwright/mcp@latest"]}}}"#.write(toFile: dir + "/.mcp.json", atomically: true, encoding: .utf8)
        }
        var ctx = makeContext()
        ctx.home = t.path
        ctx.probe = RealFileSystemProbe()
        let latest = RootCauseAnalyzer().analyze(context: ctx).filter { $0.kind == "latestResolver" }
        #expect(latest.count == 1)
        #expect(latest.first?.detail.contains("3 config files") == true)
    }
}

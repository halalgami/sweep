import Foundation
import Testing
@testable import SweepCore

@Suite struct RuleTests {
    static let requiredIDs = [
        "cache.uv", "cache.npm", "cache.npx", "cache.pnpm", "cache.bun", "cache.pip", "cache.brew", "cache.gradle",
        "cache.go", "cache.cargo", "cache.library", "cache.dotcache.puppeteer", "cache.dotcache.playwright",
        "cache.dotcache.huggingface", "cache.dotcache.torch", "cache.dotcache.whisper", "cache.dotcache.codex-runtimes",
        "cache.chrome-optguide", "cache.xcode-deriveddata", "cache.xcode-previews", "docker.builder", "docker.dangling",
        "docker.trim", "docker.images", "editor.vscode-extensions", "editor.cursor-extensions", "artifact.projects",
        "git.worktrees", "decision.simruntimes", "decision.vms", "decision.texlive", "decision.conda",
        "decision.llm-models", "decision.large-files", "decision.installers", "decision.xcode-old-deriveddata",
        "decision.sensitive-data", "leftovers.trash", "protected.paths",
    ]

    @Test func bundledRulesCoverEveryDetector() throws {
        let set = try RuleSet.bundled()
        let ids = Set(set.rules.map(\.id))
        for id in Self.requiredIDs { #expect(ids.contains(id), "missing rule \(id)") }
        #expect(ids.count == set.rules.count, "duplicate rule ids")
    }

    @Test func routineSubsetIsExactlyTheOwnerApprovedList() throws {
        let routine = Set(try RuleSet.bundled().rules.filter { $0.routine == true }.map(\.id))
        #expect(routine == ["cache.uv", "cache.npm", "cache.brew", "cache.pnpm", "cache.go",
                            "cache.xcode-deriveddata", "docker.builder"])
    }

    @Test func highRebuildRulesAreNeverRoutine() throws {
        for r in try RuleSet.bundled().rules where r.rebuildCost == .high {
            #expect(r.routine != true, "\(r.id) is high-cost but routine")
        }
    }

    @Test func overrideReplacesAndDisables() throws {
        let bundled = Data(#"{"version":1,"rules":[{"id":"a","title":"A","tier":1,"kind":"pathCache","paths":["~/a"],"action":{"type":"hardDelete"},"rebuildCost":"low","explanation":"x"},{"id":"b","title":"B","tier":1,"kind":"pathCache","paths":["~/b"],"action":{"type":"hardDelete"},"rebuildCost":"low","explanation":"x"}]}"#.utf8)
        let override = Data(#"{"version":1,"rules":[{"id":"a","title":"A2","tier":1,"kind":"pathCache","paths":["~/a"],"action":{"type":"hardDelete"},"rebuildCost":"low","explanation":"x"},{"id":"b","disabled":true},{"id":"c","title":"C","tier":3,"kind":"pathCache","paths":["~/c"],"action":{"type":"trash"},"rebuildCost":"high","explanation":"x"}]}"#.utf8)
        let set = try RuleSet.load(bundled: bundled, override: override)
        #expect(set.rule("a")?.title == "A2")
        #expect(set.rule("b") == nil)
        #expect(set.rule("c")?.tier == .needsDecision)
    }

    @Test func malformedOverrideIsReportedNotFatal() throws {
        let bundled = try RuleSet.bundledData()
        #expect(throws: (any Error).self) { try RuleSet.load(bundled: bundled, override: Data("{nope".utf8)) }
        let set = RuleSet.loadOrBundled(overrideURL: URL(fileURLWithPath: "/definitely/missing.json"))
        #expect(!set.rules.isEmpty)
    }

    @Test func pathPatternExpandsSingleComponentGlobs() {
        let fake = FakeFileSystemProbe()
        fake.addDir("/Users/me/Library/Caches/com.a")
        fake.addDir("/Users/me/Library/Caches/com.b")
        fake.addFile("/Users/me/Library/Caches/file.txt", logical: 1)
        let out = PathPattern.expand("~/Library/Caches/*", home: "/Users/me", probe: fake)
        #expect(out == ["/Users/me/Library/Caches/com.a", "/Users/me/Library/Caches/com.b", "/Users/me/Library/Caches/file.txt"])
        #expect(PathPattern.expand("~/Library/Caches/com.*", home: "/Users/me", probe: fake).count == 2)
        #expect(PathPattern.expand("~/a*b", home: "/Users/me", probe: fake).isEmpty)
        #expect(PathPattern.expand("~/Library/Caches/com.a", home: "/Users/me", probe: fake) == ["/Users/me/Library/Caches/com.a"])
        #expect(PathPattern.expand("~/missing", home: "/Users/me", probe: fake).isEmpty)
    }
}

@Suite struct RuleOrderTests {
    @Test func genericLibraryRuleComesAfterSpecificCacheRules() throws {
        let ids = try RuleSet.bundled().rules.map(\.id)
        let lib = try #require(ids.firstIndex(of: "cache.library"))
        for specific in ["cache.pip", "cache.brew", "cache.dotcache.playwright", "cache.go"] {
            #expect(try #require(ids.firstIndex(of: specific)) < lib, "\(specific) must precede cache.library")
        }
    }
}

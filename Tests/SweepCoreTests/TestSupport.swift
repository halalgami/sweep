import Foundation
@testable import SweepCore

func makeContext(probe: FakeFileSystemProbe = FakeFileSystemProbe(), runner: FakeCommandRunner = FakeCommandRunner(),
                 processes: [RunningProcess] = [], tools: [String] = [], settings: ScanSettings? = nil,
                 now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> DetectionContext {
    DetectionContext(home: "/Users/me", runner: runner, tools: FakeToolLocator(tools), probe: probe,
                     processes: StaticProcessListing(processes),
                     settings: settings ?? ScanSettings(projectRoots: ["/Users/me/Projects"]), now: now)
}

func rule(_ id: String) -> Rule { try! RuleSet.bundled().rule(id)! }


/// Rules for SafetyGuard tests: the bundled rules plus the made-up categories test items use.
/// (The guard blocks items whose rule is missing.)
let guardRules: RuleSet = {
    var set = try! RuleSet.bundled()
    set.rules += ["t.cache", "c"].map {
        Rule(id: $0, title: $0, tier: .safe, kind: .pathCache, action: RuleAction(type: "hardDelete"), rebuildCost: .low, explanation: "test")
    }
    return set
}()

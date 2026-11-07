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


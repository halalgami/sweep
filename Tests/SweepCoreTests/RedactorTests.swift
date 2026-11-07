import Foundation
import Testing
@testable import SweepCore

@Suite struct RedactorTests {
    let home = "/Users/halalgami"
    func redactor(reveal: Bool = false) -> Redactor {
        Redactor(home: home, sensitiveRoots: ["\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads", "\(home)/Developer"], revealNames: reveal)
    }

    @Test func hidesProjectAndFileNamesUnderSensitiveRoots() {
        let r = redactor()
        let out = r.redact(path: "\(home)/Documents/ClientX/data/export.csv")
        #expect(out.hasPrefix("~/Documents/project_01/"))
        #expect(out.hasSuffix(".csv"))
        for leak in ["ClientX", "halalgami", "export", "data"] { #expect(!out.contains(leak)) }
    }

    @Test func sameProjectGetsSameNumber() {
        let r = redactor()
        let a = r.redact(path: "\(home)/Documents/ClientX/node_modules")
        let b = r.redact(path: "\(home)/Documents/Other/node_modules")
        let c = r.redact(path: "\(home)/Documents/ClientX/apps/web/.next")
        #expect(a == "~/Documents/project_01/node_modules")
        #expect(b == "~/Documents/project_02/node_modules")
        #expect(c == "~/Documents/project_01/…/.next")
    }

    @Test func nonSensitivePathsOnlyLoseUsername() {
        let r = redactor()
        #expect(r.redact(path: "\(home)/Library/Caches/uv") == "~/Library/Caches/uv")
        #expect(r.redact(path: "/Users/someoneelse/x") == "/Users/<user>/x")
        #expect(r.redact(path: "docker://builder/default") == "docker://builder/default")
    }

    @Test func revealNamesKeepsNamesButStripsUsername() {
        let out = redactor(reveal: true).redact(path: "\(home)/Documents/ClientX/node_modules")
        #expect(out == "~/Documents/ClientX/node_modules")
    }

    @Test func redactsUsernameInsideFreeText() {
        #expect(redactor().redact(text: "see /Users/halalgami/.claude/x and /Users/bob/y") == "see ~/.claude/x and /Users/<user>/y")
    }

    @Test func summaryNeverLeaksSensitiveNamesOrUsername() throws {
        var sensitive = testItem("\(home)/Developer/crm/exports/customers_2026.csv", category: "decision.sensitive-data", tier: .needsDecision,
                                 action: .revealInFinder, bytes: 80_000_000)
        sensitive.title = "Data file in crm: customers_2026.csv"
        sensitive.sensitive = true
        var artifact = testItem("\(home)/Documents/AcmeClient/node_modules", category: "artifact.projects", tier: .idleArtifact, bytes: 900_000_000)
        artifact.title = "AcmeClient / node_modules"
        artifact.evidence = ["Project idle 40 days"]
        let uv = testItem("\(home)/.cache/uv", category: "cache.uv", bytes: 30_000_000_000)
        let report = ScanReport(scannedAt: Date(), volume: VolumeSummary(totalBytes: 500_000_000_000, availableBytes: 40_000_000_000, importantAvailableBytes: 50_000_000_000, usedBytes: 460_000_000_000),
                                apfs: [], buckets: [Bucket(path: home, physicalBytes: 300_000_000_000, inaccessible: 0, children: [])],
                                unaccountedBytes: 1, fullDiskAccess: false, snapshots: [], items: [uv, artifact, sensitive],
                                rootCauses: [RootCauseHint(id: "h", kind: "latestResolver", detail: "in /Users/halalgami/.claude/plugins/x", relatedCategory: "cache.uv")],
                                warnings: [])
        let summary = InsightsSummary.build(report: report, growth: [uv.id: 1_500_000_000], declines: [artifact.id: 3], redactor: redactor())
        let json = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        for leak in ["customers", "crm", "AcmeClient", "halalgami", "exports"] { #expect(!json.contains(leak), "leaked \(leak)") }
        #expect(summary.items.count == 3)
        #expect(summary.items.first { $0.id == sensitive.id }?.path == "[redacted]")
        #expect(summary.items.first { $0.id == uv.id }?.growthPerDay == 1_500_000_000)
        #expect(summary.priorDecisions[artifact.id] == 3)
    }
}

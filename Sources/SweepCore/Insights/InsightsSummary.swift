import Foundation

/// The only data an LLM ever sees. Built by code; no file contents; sensitive items fully redacted.
public struct InsightsSummary: Codable, Sendable {
    public struct BucketTotal: Codable, Sendable { public var name: String; public var bytes: Int64 }
    public struct SummaryItem: Codable, Sendable {
        public var id: String
        public var category: String
        public var title: String
        public var path: String
        public var physicalBytes: Int64
        public var tier: Int
        public var rebuildCost: String
        public var actionable: Bool
        public var lastUsedDaysAgo: Int?
        public var growthPerDay: Double?
        public var evidence: [String]
    }
    public struct Hint: Codable, Sendable { public var kind: String; public var detail: String; public var relatedCategory: String }

    public var totalBytes: Int64
    public var freeBytes: Int64
    public var unaccountedBytes: Int64
    public var fullDiskAccess: Bool
    public var buckets: [BucketTotal]
    public var items: [SummaryItem]
    public var rootCauses: [Hint]
    public var priorDecisions: [String: Int]

    public static func build(report: ScanReport, growth: [String: Double], declines: [String: Int],
                             redactor: Redactor, now: Date = Date(), limit: Int = 40) -> InsightsSummary {
        let top = report.items.sorted { $0.physicalBytes > $1.physicalBytes }.prefix(limit)
        var counters: [String: Int] = [:]
        let items = top.map { i -> SummaryItem in
            // Images, VMs, worktrees and loose files are named after the user's work wherever they live.
            if !i.sensitive, !redactor.revealNames, let label = nameBearing[i.category] {
                counters[i.category, default: 0] += 1
                return SummaryItem(
                    id: i.id, category: i.category, title: String(format: "%@ %02d", label, counters[i.category]!),
                    path: redactor.generic(path: i.path), physicalBytes: i.physicalBytes, tier: i.tier.rawValue,
                    rebuildCost: i.rebuildCost.rawValue, actionable: i.action.isActionable,
                    lastUsedDaysAgo: i.lastUsedSignal.map { max(0, Int(now.timeIntervalSince($0) / 86400)) },
                    growthPerDay: growth[i.id], evidence: [])
            }
            let redactedPath = i.sensitive ? "[redacted]" : redactor.redact(path: i.path)
            let pathChanged = !i.sensitive && redactedPath != redactor.tilde(i.path)
            let title = i.sensitive ? "[redacted]"
                : pathChanged ? redactedPath.split(separator: "/").suffix(2).joined(separator: " / ")
                : redactor.redact(text: i.title)
            return SummaryItem(
                id: i.id, category: i.sensitive ? "sensitive-data" : i.category, title: title, path: redactedPath,
                physicalBytes: i.physicalBytes, tier: i.tier.rawValue, rebuildCost: i.rebuildCost.rawValue,
                actionable: i.action.isActionable,
                lastUsedDaysAgo: i.lastUsedSignal.map { max(0, Int(now.timeIntervalSince($0) / 86400)) },
                growthPerDay: growth[i.id],
                evidence: i.sensitive || pathChanged ? [] : i.evidence.map(redactor.redact(text:)))
        }
        let ids = Set(items.map(\.id))
        return InsightsSummary(
            totalBytes: report.volume.totalBytes, freeBytes: report.volume.freeBytes, unaccountedBytes: report.unaccountedBytes,
            fullDiskAccess: report.fullDiskAccess,
            buckets: report.buckets.map { BucketTotal(name: redactor.redact(path: $0.path), bytes: $0.physicalBytes) },
            items: Array(items),
            rootCauses: report.rootCauses.map { Hint(kind: $0.kind, detail: redactor.redact(text: $0.detail), relatedCategory: $0.relatedCategory) },
            priorDecisions: declines.filter { ids.contains($0.key) })
    }

    /// Categories whose titles and paths carry the user's own names, with the generic label sent instead.
    static let nameBearing: [String: String] = [
        "docker.images": "docker image", "decision.vms": "virtual machine", "git.worktrees": "git worktree",
        "decision.large-files": "large file", "decision.installers": "installer", "leftovers.trash": "app leftovers",
    ]

    public func json() -> String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(self)) ?? Data(), as: UTF8.self)
    }
}

import Foundation

public enum ScanEvent: Sendable {
    case phase(String)
    case item(Item)
    case warning(String)
    case finished(ScanReport)
}

/// Orchestrates accounting + detectors into a ScanReport. Read-only: never modifies anything.
public final class SweepScanner: Sendable {
    public let context: DetectionContext
    public let rules: RuleSet
    public let includeBuckets: Bool
    public let includeSystemInfo: Bool
    let cancelFlag = CancelFlag()

    public init(context: DetectionContext, rules: RuleSet, includeBuckets: Bool = true, includeSystemInfo: Bool = true) {
        self.context = context; self.rules = rules
        self.includeBuckets = includeBuckets; self.includeSystemInfo = includeSystemInfo
    }

    public func cancel() { cancelFlag.set() }

    public func scan() -> AsyncStream<ScanEvent> {
        AsyncStream { cont in
            let task = Task { [self] in
                let report = await run { cont.yield($0) }
                cont.yield(.finished(report))
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func scanReport() async -> ScanReport { await run { _ in } }

    private func run(_ emit: @escaping @Sendable (ScanEvent) -> Void) async -> ScanReport {
        let ctx = context
        let accounting = VolumeAccounting(runner: ctx.runner, probe: ctx.probe, home: ctx.home)
        var volume = VolumeSummary(totalBytes: 0, availableBytes: 0, importantAvailableBytes: 0, usedBytes: 0)
        var apfs: [APFSVolumeInfo] = [], snapshots: [String] = [], fda = false
        if includeSystemInfo {
            emit(.phase("Measuring free space"))
            volume = VolumeAccounting.summary(path: "/")
            apfs = await accounting.apfs()
            snapshots = await accounting.snapshots()
            fda = VolumeAccounting.hasFullDiskAccess(home: ctx.home)
        }
        var warnings = rules.warnings

        let cancel = cancelFlag
        let bucketsTask: Task<[Bucket], Never>? = includeBuckets ? Task.detached(priority: .utility) {
            accounting.buckets(progress: { emit(.phase("Measuring \($0.replacingOccurrences(of: ctx.home, with: "~"))")) },
                               shouldCancel: { cancel.isSet })
        } : nil

        // Detectors, at most 4 at a time, results kept in rule order for deterministic de-duplication.
        var outputs = [DetectorOutput?](repeating: nil, count: rules.rules.count)
        await withTaskGroup(of: (Int, DetectorOutput).self) { group in
            var next = 0
            func add() {
                guard next < rules.rules.count else { return }
                let i = next, rule = rules.rules[i]
                next += 1
                group.addTask {
                    if cancel.isSet { return (i, DetectorOutput()) }
                    emit(.phase("Checking \(rule.title)"))
                    return (i, await DetectorRegistry.detector(for: rule.kind).detect(rule: rule, context: ctx))
                }
            }
            for _ in 0..<4 { add() }
            while let (i, out) = await group.next() {
                outputs[i] = out
                out.warnings.forEach { emit(.warning($0)) }
                add()
            }
        }
        warnings += outputs.compactMap { $0 }.flatMap(\.warnings)
        let protected = ProtectedLocations(home: ctx.home, userProtected: ctx.settings.protectedPaths)
        let items = Self.consolidate(outputs.compactMap { $0 }.flatMap(\.items), protected: protected)
        items.forEach { emit(.item($0)) }

        emit(.phase("Looking for root causes"))
        let hints = RootCauseAnalyzer().analyze(context: ctx)
        let buckets = await bucketsTask?.value ?? []
        let dataUsed = apfs.first { $0.role == "Data" }?.usedBytes ?? volume.usedBytes
        return ScanReport(scannedAt: Date(), volume: volume, apfs: apfs, buckets: buckets,
                          unaccountedBytes: includeBuckets ? VolumeAccounting.unaccounted(used: dataUsed, buckets: buckets) : 0,
                          fullDiskAccess: fda, snapshots: snapshots, items: items, rootCauses: hints, warnings: warnings)
    }

    /// Dedupe by id and path (earlier rule wins), drop items nested in another item, apply protected locations, sort by size.
    static func consolidate(_ raw: [Item], protected: ProtectedLocations) -> [Item] {
        var seenIDs = Set<String>(), seenPaths = Set<String>()
        var items: [Item] = []
        for item in raw where seenIDs.insert(item.id).inserted && seenPaths.insert(item.path).inserted {
            items.append(item)
        }
        let realPaths = items.filter { $0.path.hasPrefix("/") }.map(\.path)
        items.removeAll { item in
            item.path.hasPrefix("/") && realPaths.contains { $0 != item.path && item.path.hasPrefix($0 + "/") }
        }
        for i in items.indices where items[i].path.hasPrefix("/") && items[i].tier != .protected {
            if let reason = protected.reason(for: items[i].path) {
                items[i].tier = .protected
                items[i].action = .none(reason: reason)
                items[i].evidence.append(reason)
                items[i].defaultSelected = false
            }
        }
        return items.sorted { $0.physicalBytes != $1.physicalBytes ? $0.physicalBytes > $1.physicalBytes : $0.path < $1.path }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

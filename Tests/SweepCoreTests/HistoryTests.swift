import Foundation
import Testing
@testable import SweepCore

@Suite struct HistoryTests {
    let day: TimeInterval = 86400
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func report(at date: Date, free: Int64, items: [Item]) -> ScanReport {
        ScanReport(scannedAt: date, volume: VolumeSummary(totalBytes: 1_000_000_000_000, availableBytes: free, importantAvailableBytes: free, usedBytes: 1_000_000_000_000 - free),
                   apfs: [], buckets: [], unaccountedBytes: 0, fullDiskAccess: true, snapshots: [], items: items, rootCauses: [], warnings: [])
    }

    @Test func recordsScansAndReturnsSeries() throws {
        let t = TempDir()
        let store = try HistoryStore(path: t.path + "/h.db")
        let item = testItem("/Users/me/.cache/uv", bytes: 10_000_000_000)
        var bigger = item; bigger.physicalBytes = 11_500_000_000
        try store.record(report(at: t0, free: 100_000_000_000, items: [item]))
        try store.record(report(at: t0.addingTimeInterval(day), free: 98_000_000_000, items: [bigger]))
        let series = try store.series(itemID: item.id, since: t0.addingTimeInterval(-day))
        #expect(series.map(\.bytes) == [10_000_000_000, 11_500_000_000])
        #expect(try store.freeSeries(since: t0.addingTimeInterval(-day)).map(\.bytes) == [100_000_000_000, 98_000_000_000])
    }

    @Test func storeSurvivesReopen() throws {
        let t = TempDir()
        try HistoryStore(path: t.path + "/h.db").record(report(at: t0, free: 5, items: []))
        #expect(try HistoryStore(path: t.path + "/h.db").freeSeries(since: .distantPast).count == 1)
    }

    @Test func growthRateIsLeastSquaresPerDay() {
        let s = [(t0, Int64(10_000_000_000)), (t0.addingTimeInterval(day), 11_500_000_000), (t0.addingTimeInterval(2 * day), 13_000_000_000)]
            .map { SeriesPoint(date: $0.0, bytes: $0.1) }
        let rate = try! #require(Growth.ratePerDay(s))
        #expect(abs(rate - 1_500_000_000) < 15_000_000)
    }

    @Test func growthIgnoresPointsBeforeLastBigDrop() {
        let bytes: [Int64] = [20_000_000_000, 30_000_000_000, 3_000_000_000, 4_000_000_000, 5_000_000_000]
        let s = bytes.enumerated().map { SeriesPoint(date: t0.addingTimeInterval(Double($0.offset) * day), bytes: $0.element) }
        let rate = try! #require(Growth.ratePerDay(s))
        #expect(abs(rate - 1_000_000_000) < 10_000_000)
    }

    @Test func growthNeedsTwoPoints() {
        #expect(Growth.ratePerDay([SeriesPoint(date: t0, bytes: 5)]) == nil)
    }

    @Test func daysToFullWhenShrinking() {
        let s = [(0.0, Int64(104_000_000_000)), (1, 102_000_000_000), (2, 100_000_000_000)]
            .map { SeriesPoint(date: t0.addingTimeInterval($0.0 * day), bytes: $0.1) }
        let d = try! #require(Growth.daysToFull(freeSeries: s))
        #expect(abs(d - 50) < 1)
        let growing = s.reversed().enumerated().map { SeriesPoint(date: t0.addingTimeInterval(Double($0.offset) * day), bytes: $0.element.bytes) }
        #expect(Growth.daysToFull(freeSeries: growing) == nil)
    }

    @Test func decisionsRespectExpiryAndCountDeclines() throws {
        let t = TempDir()
        let store = try HistoryStore(path: t.path + "/h.db")
        try store.setDecision(.keep("a", now: t0, days: 90))
        try store.setDecision(Decision(itemID: "b", kind: .keep, createdAt: t0.addingTimeInterval(-100 * day), expiresAt: t0.addingTimeInterval(-day)))
        try store.setDecision(.neverAsk("c", now: t0))
        try store.setDecision(.keep("a", now: t0.addingTimeInterval(day), days: 90))
        let active = try store.decisions(now: t0.addingTimeInterval(2 * day))
        #expect(Set(active.keys) == ["a", "c"])
        #expect(active["c"]?.expiresAt == nil)
        #expect(try store.declineCounts()["a"] == 2)
        try store.clearDecision("a")
        #expect(try store.decisions(now: t0.addingTimeInterval(2 * day))["a"] == nil)
    }

    @Test func runsAreRecorded() throws {
        let t = TempDir()
        let store = try HistoryStore(path: t.path + "/h.db")
        try store.recordRun([ItemResult(itemID: "x", title: "uv cache", status: .removed, removedPaths: 1, protectedPaths: 0, failedPaths: 0,
                                        message: "Done", expectedBytes: 5)], at: t0, routine: true)
        let runs = try store.recentRuns(limit: 5)
        #expect(runs.first?.results.first?.title == "uv cache")
        #expect(runs.first?.routine == true)
    }
}

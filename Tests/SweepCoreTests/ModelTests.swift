import Foundation
import Testing
@testable import SweepCore

@Suite struct ModelTests {
    @Test func itemIDIsStableAndSixteenHexChars() {
        let a = Item.makeID(category: "cache.uv", key: "/Users/x/.cache/uv")
        let b = Item.makeID(category: "cache.uv", key: "/Users/x/.cache/uv")
        let c = Item.makeID(category: "cache.npm", key: "/Users/x/.cache/uv")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 16)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func byteFormatting() {
        #expect(ByteFormat.string(38_600_000_000) == "38.6 GB")
        #expect(ByteFormat.string(512_000) == "512 KB")
        #expect(ByteFormat.string(0) == "0 bytes")
        #expect(ByteFormat.string(1_500_000_000_000) == "1.5 TB")
    }

    @Test func scanReportRoundTripsThroughJSON() throws {
        let item = Item(
            id: "abc", category: "cache.uv", title: "uv cache", path: "/tmp/uv",
            logicalBytes: 10, physicalBytes: 8, lastModified: Date(timeIntervalSince1970: 1000),
            lastUsedSignal: nil, tier: .safe, action: .toolCommand(executable: "/opt/homebrew/bin/uv", arguments: ["cache", "prune"]),
            rebuildCost: .low, rebuildHint: "uv re-downloads", evidence: ["e"], routine: true,
            defaultSelected: true, sensitive: false)
        let report = ScanReport(
            scannedAt: Date(timeIntervalSince1970: 2000),
            volume: VolumeSummary(totalBytes: 100, availableBytes: 20, importantAvailableBytes: 25, usedBytes: 80),
            apfs: [], buckets: [], unaccountedBytes: 3, fullDiskAccess: false, snapshots: [],
            items: [item], rootCauses: [], warnings: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ScanReport.self, from: enc.encode(report))
        #expect(back.items == [item])
        #expect(back.unaccountedBytes == 3)
        #expect(back.tierTotal(.safe) == 8)
        #expect(back.tierTotal(.needsDecision) == 0)
    }
}

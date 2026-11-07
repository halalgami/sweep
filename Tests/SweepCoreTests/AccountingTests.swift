import Foundation
import Testing
@testable import SweepCore

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

@Suite struct AccountingTests {
    @Test func parsesBootContainerAndSimulatorVolumes() throws {
        let vols = APFSParser.parse(plistData: try fixture("apfs_list.plist"))
        let names = vols.map(\.name)
        #expect(names.contains("Macintosh HD"))
        #expect(names.contains("Data"))
        #expect(names.contains("VM"))
        #expect(names.contains("Preboot"))
        #expect(!names.contains("iSCPreboot"))     // other container dropped
        let data = try #require(vols.first { $0.role == "Data" })
        #expect(data.usedBytes == 400_546_955_264)
        let sims = vols.filter(\.isSimulator)
        #expect(sims.count == 2)
        #expect(sims.allSatisfy { $0.role == "Simulator" })
    }

    @Test func unaccountedIsClampedDifference() {
        let b = [Bucket(path: "/a", physicalBytes: 60, inaccessible: 0, children: []),
                 Bucket(path: "/b", physicalBytes: 30, inaccessible: 0, children: [])]
        #expect(VolumeAccounting.unaccounted(used: 100, buckets: b) == 10)
        #expect(VolumeAccounting.unaccounted(used: 50, buckets: b) == 0)
    }

    @Test func parsesSnapshotList() {
        let out = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-11-01-120000.local
        com.apple.os.update-ABC123

        """
        #expect(VolumeAccounting.parseSnapshots(out) == [
            "com.apple.TimeMachine.2026-11-01-120000.local", "com.apple.os.update-ABC123"])
    }

    @Test func bucketsMeasuredWithTopChildren() {
        let fake = FakeFileSystemProbe()
        fake.addDir("/Users/me")
        fake.addFile("/Users/me/Library/big.bin", logical: 5000)
        fake.addFile("/Users/me/Documents/a.txt", logical: 1000)
        fake.addDir("/Applications")
        fake.addFile("/Applications/X.app/bin", logical: 2000)
        let acc = VolumeAccounting(runner: FakeCommandRunner(), probe: fake, home: "/Users/me",
                                   roots: ["/Users/me", "/Applications", "/opt"])
        let buckets = acc.buckets(progress: { _ in })
        #expect(buckets.map(\.path) == ["/Users/me", "/Applications"])   // missing /opt skipped
        #expect(buckets[0].physicalBytes == 6000)
        #expect(buckets[0].children.first?.path == "/Users/me/Library")
    }

    @Test func realVolumeSummaryIsSane() {
        let s = VolumeAccounting.summary(path: "/")
        #expect(s.totalBytes > 0)
        #expect(s.usedBytes > 0)
        #expect(s.freeBytes <= s.totalBytes)
    }
}

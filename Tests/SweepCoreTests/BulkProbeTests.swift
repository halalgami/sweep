import Foundation
import Testing
@testable import SweepCore

@Suite struct BulkProbeTests {
    @Test func bulkEntriesMatchLstat() throws {
        let t = TempDir()
        t.file("a.bin", bytes: 123_456)
        t.file("مجلد/ملف.txt", bytes: 10)
        t.file("sub dir/x.dat", bytes: 70_000)
        try FileManager.default.createSymbolicLink(atPath: t.path + "/link", withDestinationPath: "/etc")
        try FileManager.default.linkItem(atPath: t.path + "/a.bin", toPath: t.path + "/a-hard.bin")
        let probe = RealFileSystemProbe()
        let bulk = try #require(probe.entries(t.path))
        #expect(Set(bulk.map(\.name)) == Set(try FileManager.default.contentsOfDirectory(atPath: t.path)))
        for e in bulk {
            let m = try #require(probe.meta(t.path + "/" + e.name))
            #expect(e.meta.isDirectory == m.isDirectory, "\(e.name)")
            #expect(e.meta.isSymlink == m.isSymlink, "\(e.name)")
            #expect(e.meta.device == m.device, "\(e.name)")
            #expect(e.meta.inode == m.inode, "\(e.name)")
            #expect(e.meta.flags == m.flags, "\(e.name)")
            #expect(abs(e.meta.mtime.timeIntervalSince(m.mtime)) < 1, "\(e.name)")
            if !m.isDirectory && !m.isSymlink {
                #expect(e.meta.allocatedSize == m.allocatedSize, "\(e.name)")
                #expect(e.meta.logicalSize == m.logicalSize, "\(e.name)")
                #expect(e.meta.linkCount == m.linkCount, "\(e.name)")
            }
        }
    }

    @Test func unreadableDirReturnsNil() {
        let t = TempDir()
        let d = t.dir("locked")
        chmod(d, 0)
        #expect(RealFileSystemProbe().entries(d) == nil)
    }
}

import Foundation
import Testing
@testable import SweepCore

/// Creates a scratch directory removed at deinit.
final class TempDir {
    let url: URL
    var path: String { url.path }
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        // restore perms so cleanup works
        if let e = FileManager.default.enumerator(atPath: path) {
            for case let p as String in e { chmod((path as NSString).appendingPathComponent(p), 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }
    @discardableResult
    func file(_ rel: String, bytes: Int, mtime: Date? = nil) -> String {
        let p = (path as NSString).appendingPathComponent(rel)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        FileManager.default.createFile(atPath: p, contents: data)
        if let mtime { try! FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: p) }
        return p
    }
    func dir(_ rel: String) -> String {
        let p = (path as NSString).appendingPathComponent(rel)
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
}

@Suite struct SizeCalculatorTests {
    let sizer = SizeCalculator(probe: RealFileSystemProbe())

    @Test func hardLinksCountedOnce() throws {
        let t = TempDir()
        let f = t.file("a/one.bin", bytes: 1_000_000)
        try FileManager.default.linkItem(atPath: f, toPath: t.path + "/a/two.bin")
        let r = sizer.measure(t.path)
        #expect(r.physical >= 1_000_000)
        #expect(r.physical < 1_500_000)
    }

    @Test func symlinksAreNotFollowed() throws {
        let outside = TempDir()
        let big = outside.file("big.bin", bytes: 10_000_000)
        let t = TempDir()
        try FileManager.default.createSymbolicLink(atPath: t.path + "/link", withDestinationPath: big)
        try FileManager.default.createSymbolicLink(atPath: t.path + "/dirlink", withDestinationPath: outside.path)
        let r = sizer.measure(t.path)
        #expect(r.physical < 1_000_000)
    }

    @Test func unicodeAndSpacesMeasured() {
        let t = TempDir()
        t.file("مجلد مهم/ملف مهم.txt", bytes: 100_000)
        t.file("with space/file (1).txt", bytes: 100_000)
        let r = sizer.measure(t.path)
        #expect(r.physical >= 200_000)
        #expect(r.files == 2)
    }

    @Test func unreadableDirectoryCountedNotThrown() {
        let t = TempDir()
        t.file("locked/secret.bin", bytes: 50_000)
        t.file("open/ok.bin", bytes: 50_000)
        chmod(t.path + "/locked", 0o000)
        let r = sizer.measure(t.path)
        #expect(r.inaccessible == 1)
        #expect(r.physical >= 50_000)
    }

    @Test func skipDirNamesExcludedAndNewestMTimeTracked() {
        let t = TempDir()
        let old = Date(timeIntervalSinceNow: -30 * 86400)
        t.file("src/main.ts", bytes: 10, mtime: old)
        t.file("node_modules/x/index.js", bytes: 500_000)
        let r = sizer.measure(t.path, skipDirNames: ["node_modules"])
        #expect(r.physical < 100_000)
        #expect(abs((r.newestMTime ?? .distantFuture).timeIntervalSince(old)) < 2)
    }

    @Test func datalessFilesCountZeroPhysical() {
        let fake = FakeFileSystemProbe()
        fake.addDir("/r")
        fake.addFile("/r/cloud.mov", logical: 30_000_000_000, allocated: 30_000_000_000, flags: FileMeta.datalessFlag)
        fake.addFile("/r/local.txt", logical: 4096, allocated: 4096)
        let r = SizeCalculator(probe: fake).measure("/r")
        #expect(r.physical == 4096)
        #expect(r.logical == 30_000_004_096)
        #expect(r.dataless == 1)
    }

    @Test func restrictedFlagCounted() {
        let fake = FakeFileSystemProbe()
        fake.addDir("/r")
        fake.addFile("/r/dyld", logical: 100, allocated: 4096, flags: FileMeta.restrictedFlag)
        #expect(SizeCalculator(probe: fake).measure("/r").restricted == 1)
    }

    @Test func otherDeviceSubtreeSkipped() {
        let fake = FakeFileSystemProbe()
        fake.addDir("/r")
        fake.addDir("/r/mnt", device: 9)
        fake.addFile("/r/mnt/huge.dmg", logical: 9_000_000_000, allocated: 9_000_000_000, device: 9)
        fake.addFile("/r/a.txt", logical: 4096, allocated: 4096)
        #expect(SizeCalculator(probe: fake).measure("/r").physical == 4096)
    }
}

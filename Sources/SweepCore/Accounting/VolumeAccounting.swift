import Darwin
import Foundation

/// Headline accounting: free space, APFS container breakdown, top-level buckets, snapshots.
public struct VolumeAccounting: Sendable {
    public static func defaultRoots(home: String) -> [String] {
        [home, "/Applications", "/Library", "/opt", "/usr/local", "/private/var", "/System/Volumes/Data/System"]
    }

    public let runner: CommandRunner
    public let probe: FileSystemProbe
    public let home: String
    public let roots: [String]
    public let sizer: SizeCalculator

    public init(runner: CommandRunner, probe: FileSystemProbe, home: String, roots: [String]? = nil) {
        self.runner = runner; self.probe = probe; self.home = home
        self.roots = roots ?? Self.defaultRoots(home: home)
        self.sizer = SizeCalculator(probe: probe)
    }

    public static func summary(path: String = "/") -> VolumeSummary {
        var fs = statfs()
        var total: Int64 = 0, avail: Int64 = 0
        if statfs(path, &fs) == 0 {
            total = Int64(fs.f_blocks) * Int64(fs.f_bsize)
            avail = Int64(fs.f_bavail) * Int64(fs.f_bsize)
        }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage ?? avail
        if let t = values?.volumeTotalCapacity, t > 0 { total = Int64(t) }
        return VolumeSummary(totalBytes: total, availableBytes: avail,
                             importantAvailableBytes: important, usedBytes: max(0, total - avail))
    }

    public func apfs() async -> [APFSVolumeInfo] {
        let r = await runner.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 30)
        guard r.ok else { return [] }
        return APFSParser.parse(plistData: Data(r.stdout.utf8))
    }

    /// Measures each root; children are the 12 largest immediate subfolders.
    public func buckets(progress: (String) -> Void, shouldCancel: (@Sendable () -> Bool)? = nil) -> [Bucket] {
        roots.compactMap { root in
            guard let meta = probe.meta(root), meta.isDirectory else { return nil }
            progress(root)
            var kids: [Bucket] = []
            var inaccessible = 0
            var total: Int64 = meta.allocatedSize
            if let paths = probe.childPaths(root) {
                let candidates = paths.filter { p in
                    guard let m = probe.meta(p) else { return false }
                    return !m.isSymlink && m.device == meta.device && !SizeCalculator.defaultExcluded.contains(p)
                }
                // Measure top-level children in parallel; the walk is I/O bound.
                let box = MeasureBox()
                DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
                    if shouldCancel?() == true { return }
                    let p = candidates[i]
                    let r = sizer.measure(p, shouldCancel: shouldCancel)
                    box.append((p, r, probe.meta(p)?.isDirectory ?? false))
                }
                for (p, r, isDir) in box.values {
                    total += r.physical
                    inaccessible += r.inaccessible
                    if isDir { kids.append(Bucket(path: p, physicalBytes: r.physical, inaccessible: r.inaccessible, children: [])) }
                }
            } else {
                inaccessible += 1
            }
            kids.sort { $0.physicalBytes > $1.physicalBytes }
            return Bucket(path: root, physicalBytes: total, inaccessible: inaccessible, children: Array(kids.prefix(12)))
        }
    }

    public func snapshots() async -> [String] {
        let r = await runner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 20)
        return Self.parseSnapshots(r.stdout)
    }

    public static func parseSnapshots(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Snapshots for") }
    }

    public static func unaccounted(used: Int64, buckets: [Bucket]) -> Int64 {
        max(0, used - buckets.reduce(0) { $0 + $1.physicalBytes })
    }

    /// Full Disk Access probe: the user TCC database is only readable with FDA.
    public static func hasFullDiskAccess(home: String = NSHomeDirectory()) -> Bool {
        let fd = open("\(home)/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    public static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

final class MeasureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, SizeResult, Bool)] = []
    func append(_ v: (String, SizeResult, Bool)) { lock.withLock { items.append(v) } }
    var values: [(String, SizeResult, Bool)] { lock.withLock { items } }
}

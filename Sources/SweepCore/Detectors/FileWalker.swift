import Foundation

enum FileWalker {
    static let packageSuffixes = [".app", ".photoslibrary", ".pvm", ".utm", ".vmwarevm", ".xcarchive", ".bundle", ".framework"]

    /// Regular files under `root` up to `maxDepth` levels, not following symlinks, skipping named dirs and packages.
    static func files(under root: String, maxDepth: Int, skipDirs: Set<String> = [], probe: FileSystemProbe) async -> [(String, FileMeta)] {
        await Blocking.run { walkFiles(under: root, maxDepth: maxDepth, skipDirs: skipDirs, probe: probe) }
    }

    static func walkFiles(under root: String, maxDepth: Int, skipDirs: Set<String>, probe: FileSystemProbe) -> [(String, FileMeta)] {
        var out: [(String, FileMeta)] = []
        var queue: [(String, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            for name in probe.children(dir) ?? [] {
                let p = dir + "/" + name
                guard let m = probe.meta(p), !m.isSymlink else { continue }
                if m.isDirectory {
                    if depth < maxDepth, !skipDirs.contains(name), !name.hasPrefix("."),
                       !packageSuffixes.contains(where: name.hasSuffix) { queue.append((p, depth + 1)) }
                } else {
                    out.append((p, m))
                }
            }
        }
        return out
    }

    static func newestMTime(under root: String, suffix: String, maxDepth: Int, probe: FileSystemProbe) async -> Date? {
        await Blocking.run { walkNewestMTime(under: root, suffix: suffix, maxDepth: maxDepth, probe: probe) }
    }

    static func walkNewestMTime(under root: String, suffix: String, maxDepth: Int, probe: FileSystemProbe) -> Date? {
        var best: Date?
        var queue: [(String, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            for name in probe.children(dir) ?? [] {
                let p = dir + "/" + name
                guard let m = probe.meta(p), !m.isSymlink else { continue }
                if m.isDirectory { if depth < maxDepth { queue.append((p, depth + 1)) } }
                else if name.hasSuffix(suffix), best.map({ m.mtime > $0 }) ?? true { best = m.mtime }
            }
        }
        return best
    }

    static func size(_ m: FileMeta) -> SizeResult {
        var s = SizeResult()
        s.logical = m.logicalSize
        s.physical = m.isDataless ? 0 : m.allocatedSize
        s.dataless = m.isDataless ? 1 : 0
        s.files = 1
        s.newestMTime = m.mtime
        return s
    }

    static func days(_ d: Date, _ now: Date) -> Int { max(0, Int(now.timeIntervalSince(d) / 86400)) }
}

import Foundation

public struct SizeResult: Sendable, Hashable {
    public var logical: Int64 = 0
    public var physical: Int64 = 0
    public var files: Int = 0
    public var inaccessible: Int = 0
    public var dataless: Int = 0
    public var restricted: Int = 0
    public var newestMTime: Date?
    public init() {}
}

/// `du -x`-style physical size: no symlink following, no crossing devices,
/// each (device, inode) counted once, dataless (cloud placeholder) files count 0 bytes.
public struct SizeCalculator: Sendable {
    public static let defaultExcluded: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/private/var/vm",
        "/Library/Developer/CoreSimulator/Volumes", "/Library/Developer/CoreSimulator/Cryptex",
    ]

    public let probe: FileSystemProbe
    public let excludedPaths: Set<String>

    public init(probe: FileSystemProbe, excludedPaths: Set<String> = SizeCalculator.defaultExcluded) {
        self.probe = probe; self.excludedPaths = excludedPaths
    }

    public func measure(_ root: String, skipDirNames: Set<String> = [],
                        shouldCancel: (@Sendable () -> Bool)? = nil) -> SizeResult {
        var result = SizeResult()
        guard let rootMeta = probe.meta(root) else { return result }
        var seen = Set<InodeKey>()
        account(rootMeta, &result, &seen)
        guard rootMeta.isDirectory else { return result }
        var stack = [root]
        var visited = 0
        while let dir = stack.popLast() {
            visited += 1
            if visited % 512 == 0, shouldCancel?() == true { break }
            guard let names = probe.children(dir) else { result.inaccessible += 1; continue }
            for name in names {
                let path = dir == "/" ? "/" + name : dir + "/" + name
                guard let m = probe.meta(path) else { continue }
                if m.isSymlink { continue }
                if m.device != rootMeta.device { continue }
                if m.isDirectory {
                    if skipDirNames.contains(name) || excludedPaths.contains(path) { continue }
                    account(m, &result, &seen)
                    stack.append(path)
                } else {
                    account(m, &result, &seen)
                    result.files += 1
                    if result.newestMTime.map({ m.mtime > $0 }) ?? true { result.newestMTime = m.mtime }
                }
            }
        }
        return result
    }

    private struct InodeKey: Hashable { let dev: Int32; let ino: UInt64 }

    private func account(_ m: FileMeta, _ r: inout SizeResult, _ seen: inout Set<InodeKey>) {
        if m.isRestricted { r.restricted += 1 }
        if m.linkCount > 1, !m.isDirectory {
            guard seen.insert(InodeKey(dev: m.device, ino: m.inode)).inserted else { return }
        }
        r.logical += m.logicalSize
        if m.isDataless { r.dataless += 1; return }
        r.physical += m.allocatedSize
    }
}

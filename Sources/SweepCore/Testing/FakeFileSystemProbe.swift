import Foundation

/// In-memory filesystem for tests: dataless files, clones, SIP flags and mount points.
public final class FakeFileSystemProbe: FileSystemProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: FileMeta] = [:]
    private var unreadable: Set<String> = []
    private var nextInode: UInt64 = 100

    public init() {}

    private func parentChain(_ path: String) {
        var p = (path as NSString).deletingLastPathComponent
        while p != "/" && !p.isEmpty && entries[p] == nil {
            entries[p] = FileMeta(isDirectory: true, isSymlink: false, device: 1, inode: bump(),
                                  logicalSize: 0, allocatedSize: 0, flags: 0, mtime: .distantPast)
            p = (p as NSString).deletingLastPathComponent
        }
    }
    private func bump() -> UInt64 { nextInode += 1; return nextInode }

    public func addDir(_ path: String, device: Int32 = 1, mtime: Date = .distantPast, unreadable: Bool = false) {
        lock.withLock {
            parentChain(path)
            entries[path] = FileMeta(isDirectory: true, isSymlink: false, device: device, inode: bump(),
                                     logicalSize: 0, allocatedSize: 0, flags: 0, mtime: mtime)
            if unreadable { self.unreadable.insert(path) }
        }
    }

    public func addFile(_ path: String, logical: Int64, allocated: Int64? = nil, flags: UInt32 = 0,
                        device: Int32 = 1, inode: UInt64? = nil, mtime: Date = .distantPast) {
        lock.withLock {
            parentChain(path)
            entries[path] = FileMeta(isDirectory: false, isSymlink: false, device: device, inode: inode ?? bump(),
                                     logicalSize: logical, allocatedSize: allocated ?? logical, flags: flags, mtime: mtime)
        }
    }

    public func addSymlink(_ path: String) {
        lock.withLock {
            parentChain(path)
            entries[path] = FileMeta(isDirectory: false, isSymlink: true, device: 1, inode: bump(),
                                     logicalSize: 10, allocatedSize: 0, flags: 0, mtime: .distantPast)
        }
    }

    public func remove(_ path: String) {
        lock.withLock { entries = entries.filter { $0.key != path && !$0.key.hasPrefix(path + "/") } }
    }

    public func meta(_ path: String) -> FileMeta? { lock.withLock { entries[path] } }

    public func children(_ path: String) -> [String]? {
        lock.withLock {
            guard entries[path]?.isDirectory == true, !unreadable.contains(path) else { return nil }
            let prefix = path == "/" ? "/" : path + "/"
            return entries.keys.compactMap { k in
                guard k.hasPrefix(prefix) else { return nil }
                let rest = k.dropFirst(prefix.count)
                return rest.contains("/") || rest.isEmpty ? nil : String(rest)
            }.sorted()
        }
    }
}

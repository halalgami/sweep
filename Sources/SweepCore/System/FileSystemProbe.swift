import Darwin
import Foundation

public struct FileMeta: Sendable, Hashable {
    public static let datalessFlag: UInt32 = 0x4000_0000   // SF_DATALESS
    public static let restrictedFlag: UInt32 = 0x0008_0000 // SF_RESTRICTED (SIP)

    public var isDirectory: Bool
    public var isSymlink: Bool
    public var device: Int32
    public var inode: UInt64
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var flags: UInt32
    public var mtime: Date
    public var linkCount: UInt16

    public var isDataless: Bool { flags & Self.datalessFlag != 0 }
    public var isRestricted: Bool { flags & Self.restrictedFlag != 0 }

    public init(isDirectory: Bool, isSymlink: Bool, device: Int32, inode: UInt64, logicalSize: Int64,
                allocatedSize: Int64, flags: UInt32, mtime: Date, linkCount: UInt16 = 1) {
        self.isDirectory = isDirectory; self.isSymlink = isSymlink; self.device = device; self.inode = inode
        self.logicalSize = logicalSize; self.allocatedSize = allocatedSize; self.flags = flags
        self.mtime = mtime; self.linkCount = linkCount
    }
}

/// Source of filesystem metadata. Never follows symlinks.
public protocol FileSystemProbe: Sendable {
    /// lstat-like metadata, nil if the path doesn't exist or can't be stat'd.
    func meta(_ path: String) -> FileMeta?
    /// Child names (not full paths); nil when the directory can't be read.
    func children(_ path: String) -> [String]?
    /// Whether the current user can remove `path` (its parent directory is writable).
    func isDeletable(_ path: String) -> Bool
}

public extension FileSystemProbe {
    func exists(_ path: String) -> Bool { meta(path) != nil }
    func childPaths(_ path: String) -> [String]? {
        children(path)?.map { (path as NSString).appendingPathComponent($0) }
    }
}

public struct RealFileSystemProbe: FileSystemProbe {
    public init() {}

    public func meta(_ path: String) -> FileMeta? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        return FileMeta(
            isDirectory: type == S_IFDIR, isSymlink: type == S_IFLNK,
            device: st.st_dev, inode: st.st_ino, logicalSize: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512, flags: st.st_flags,
            mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                        + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9),
            linkCount: st.st_nlink)
    }

    public func isDeletable(_ path: String) -> Bool {
        access((path as NSString).deletingLastPathComponent, W_OK) == 0
    }

    public func children(_ path: String) -> [String]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var names: [String] = []
        while let ent = readdir(dir) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(ent.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }
}

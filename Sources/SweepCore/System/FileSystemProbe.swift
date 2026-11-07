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
    /// Children with their metadata in one go; nil when the directory can't be read.
    func entries(_ path: String) -> [DirEntry]?
}

public struct DirEntry: Sendable, Hashable {
    public var name: String
    public var meta: FileMeta
}

public extension FileSystemProbe {
    func entries(_ path: String) -> [DirEntry]? {
        guard let names = children(path) else { return nil }
        return names.compactMap { n in meta(path == "/" ? "/" + n : path + "/" + n).map { DirEntry(name: n, meta: $0) } }
    }

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

    /// Fast path: one `getattrlistbulk` call returns many entries with their metadata (no per-file lstat).
    public func entries(_ path: String) -> [DirEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID)
                                    | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FLAGS) | UInt32(ATTR_CMN_FILEID))
        al.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        let size = 128 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buf.deallocate() }
        var out: [DirEntry] = []
        var first = true
        while true {
            let n = getattrlistbulk(fd, &al, buf, size, 0)
            if n < 0 { return first ? nil : out }
            if n == 0 { break }
            first = false
            var entry = buf
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry + 4
                let ret = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                var name = "", dev: Int32 = 0, type: UInt32 = 0, mtime = Date.distantPast, flags: UInt32 = 0, ino: UInt64 = 0
                var links: UInt32 = 1, alloc: Int64 = 0, len: Int64 = 0
                let c = ret.commonattr, f = ret.fileattr
                if c & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (p + Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                    p += MemoryLayout<attrreference_t>.size
                }
                if c & attrgroup_t(ATTR_CMN_DEVID) != 0 { dev = p.loadUnaligned(as: Int32.self); p += 4 }
                if c & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = p.loadUnaligned(as: UInt32.self); p += 4 }
                if c & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let ts = p.loadUnaligned(as: timespec.self)
                    mtime = Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
                    p += MemoryLayout<timespec>.size
                }
                if c & attrgroup_t(ATTR_CMN_FLAGS) != 0 { flags = p.loadUnaligned(as: UInt32.self); p += 4 }
                if c & attrgroup_t(ATTR_CMN_FILEID) != 0 { ino = p.loadUnaligned(as: UInt64.self); p += 8 }
                if f & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { links = p.loadUnaligned(as: UInt32.self); p += 4 }
                if f & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }
                if f & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 { len = p.loadUnaligned(as: Int64.self); p += 8 }
                if !name.isEmpty, name != ".", name != ".." {
                    out.append(DirEntry(name: name, meta: FileMeta(
                        isDirectory: type == UInt32(VDIR.rawValue), isSymlink: type == UInt32(VLNK.rawValue), device: dev, inode: ino,
                        logicalSize: len, allocatedSize: alloc, flags: flags, mtime: mtime, linkCount: UInt16(clamping: links))))
                }
                entry += length
            }
        }
        return out
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

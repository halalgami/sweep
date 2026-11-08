import Darwin
import Foundation

public struct RunningProcess: Sendable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    /// Process group; nil when unknown. A helper whose group leader has exited was left behind by its parent.
    public var pgid: Int32?
    public var command: String
    public var arguments: [String]
    public var cwd: String?
    public init(pid: Int32, ppid: Int32, pgid: Int32? = nil, command: String, arguments: [String], cwd: String?) {
        self.pid = pid; self.ppid = ppid; self.pgid = pgid; self.command = command; self.arguments = arguments; self.cwd = cwd
    }
    public var commandLine: String { arguments.isEmpty ? command : arguments.joined(separator: " ") }
}

public protocol ProcessListing: Sendable {
    func processes() -> [RunningProcess]
}

public extension ProcessListing {
    /// Processes whose full command line matches the regex (like `pgrep -f`).
    func matching(_ pattern: String) -> [RunningProcess] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return processes().filter { p in
            let s = p.commandLine
            return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
    }
}

public struct StaticProcessListing: ProcessListing {
    public let list: [RunningProcess]
    public init(_ list: [RunningProcess]) { self.list = list }
    public func processes() -> [RunningProcess] { list }
}

/// Lists processes via sysctl (no `ps`/`pgrep` subprocess).
public struct SystemProcessListing: ProcessListing {
    public init() {}

    public func processes() -> [RunningProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(n).compactMap { kp in
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { return nil }
            let comm = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return RunningProcess(pid: pid, ppid: kp.kp_eproc.e_ppid, pgid: kp.kp_eproc.e_pgid, command: comm,
                                  arguments: Self.arguments(pid: pid), cwd: Self.cwd(pid: pid))
        }
    }

    static func arguments(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size, buf[i] != 0 { i += 1 } // exec path
        while i < size, buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func cwd(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}

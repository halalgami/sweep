import Foundation

public struct IdleVerdict: Sendable, Hashable {
    public var idle: Bool
    public var idleDays: Int
    public var lastCommit: Date?
    public var newestSource: Date?
    public var reasons: [String]
}

/// A project is idle only if: no source edits in N days, no commits in N days, a clean working tree,
/// and no dev server running for it. All date math is done here (never `find -newermt`).
public struct IdleChecker: Sendable {
    public static let devServerPattern = #"next dev|next-server|sst dev|vite|turbo (run|dev)|webpack serve|nodemon"#

    public init() {}

    public func verdict(project: String, context ctx: DetectionContext) async -> IdleVerdict {
        let n = ctx.settings.idleDays
        var reasons: [String] = []
        var idle = true
        let src = ctx.sizer.measure(project, skipDirNames: ProjectDiscovery.artifactNames.union([".git"])).newestMTime
        func days(_ d: Date) -> Int { max(0, Int(ctx.now.timeIntervalSince(d) / 86400)) }
        if let src, days(src) < n { idle = false; reasons.append("A source file was edited \(days(src)) days ago") }

        var lastCommit: Date?
        if ctx.probe.exists(project + "/.git"), let git = ctx.tools.path(for: "git") {
            let log = await ctx.runner.run(git, ["-C", project, "log", "-1", "--format=%ct"], timeout: 15)
            if let t = TimeInterval(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
                lastCommit = Date(timeIntervalSince1970: t)
                if days(lastCommit!) < n { idle = false; reasons.append("Last commit was \(days(lastCommit!)) days ago") }
            }
            let status = await ctx.runner.run(git, ["-C", project, "status", "--porcelain"], timeout: 30)
            if !status.ok { idle = false; reasons.append("Couldn't read git status, so it's treated as active") }
            else if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                idle = false; reasons.append("Has uncommitted changes")
            }
        }
        let servers = ctx.processes.matching(Self.devServerPattern).filter { p in
            (p.cwd.map { $0 == project || $0.hasPrefix(project + "/") } ?? false) || p.arguments.contains { $0.hasPrefix(project) }
        }
        if let s = servers.first { idle = false; reasons.append("A dev server is running for it (pid \(s.pid))") }

        let newest = [src, lastCommit].compactMap { $0 }.max()
        return IdleVerdict(idle: idle, idleDays: newest.map(days) ?? n, lastCommit: lastCommit, newestSource: src, reasons: reasons)
    }
}

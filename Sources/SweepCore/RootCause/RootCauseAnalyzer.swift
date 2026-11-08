import Foundation

/// Deterministic hints about *why* caches regrow: `@latest` MCP servers, duplicate servers, orphaned processes.
public struct RootCauseAnalyzer: Sendable {
    public init() {}

    struct Server { var name: String; var command: String; var package: String; var file: String }

    public func analyze(context ctx: DetectionContext) -> [RootCauseHint] {
        var hints: [RootCauseHint] = []
        func tilde(_ p: String) -> String { p.replacingOccurrences(of: ctx.home, with: "~") }
        func add(_ kind: String, _ detail: String, _ cat: String) {
            hints.append(RootCauseHint(id: Item.makeID(category: kind, key: detail), kind: kind, detail: detail, relatedCategory: cat))
        }

        let all = configFiles(ctx).flatMap { self.servers(in: $0) }
        let latest = Dictionary(grouping: all.filter { $0.package.hasSuffix("@latest") }) { "\($0.command) \($0.package)" }
        for (cmdline, group) in latest.sorted(by: { $0.key < $1.key }) {
            let isNpx = group[0].command == "npx"
            let places = group.count == 1 ? tilde(group[0].file) : "\(group.count) config files, e.g. \(tilde(group[0].file))"
            add("latestResolver", "MCP server \"\(group[0].name)\" runs `\(cmdline)` (\(places)). It re-resolves on every agent session and keeps growing the \(isNpx ? "npx" : "uv") cache.",
                isNpx ? "cache.npx" : "cache.uv")
        }
        let byPackage = Dictionary(grouping: all) { Self.baseName($0.package) }
        for (pkg, group) in byPackage.sorted(by: { $0.key < $1.key }) {
            let versions = Set(group.map(\.package))
            if versions.count > 1 {
                add("duplicateMCP", "\(pkg) is configured \(group.count) times with different versions (\(versions.sorted().joined(separator: ", "))). Each version gets its own cache copy.",
                    group.first?.command == "npx" ? "cache.npx" : "cache.uv")
            }
        }

        let procs = ctx.processes.processes()
        let alive = Set(procs.map(\.pid))
        // launchd (pid 1) also parents services it started on purpose; those lead their own process group.
        // An orphan's group leader (the agent session that spawned it) is gone.
        let orphans = procs.filter { p in
            guard p.ppid == 1, let g = p.pgid, g != p.pid, !alive.contains(g) else { return false }
            return p.commandLine.range(of: "mcp|modelcontextprotocol", options: [.regularExpression, .caseInsensitive]) != nil
                && p.commandLine.range(of: #"uvx|npx|node|python|uv run"#, options: .regularExpression) != nil
        }
        if !orphans.isEmpty {
            add("orphanMCP", "\(orphans.count) MCP server process(es) outlived their agent session (pids \(orphans.map { String($0.pid) }.joined(separator: ", "))). They hold memory and cache locks.", "cache.uv")
        }
        let writers = procs.filter { $0.commandLine.range(of: #"(^|/| )(uvx|npx)( |$)|uv run|npm exec"#, options: .regularExpression) != nil }
        if !writers.isEmpty {
            add("activeWriter", "\(writers.count) process(es) are writing to package caches right now (uvx / uv run / npx).", "cache.uv")
        }
        return hints
    }

    func configFiles(_ ctx: DetectionContext) -> [String] {
        var files = ["\(ctx.home)/.claude.json", "\(ctx.home)/.cursor/mcp.json",
                     "\(ctx.home)/Library/Application Support/Code/User/mcp.json",
                     "\(ctx.home)/Library/Application Support/Claude/claude_desktop_config.json"]
        let plugins = "\(ctx.home)/.claude/plugins"
        var queue: [(String, Int)] = [(plugins, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            for name in ctx.probe.children(dir) ?? [] {
                let p = dir + "/" + name
                if name == ".mcp.json" { files.append(p) }
                else if depth < 7, name != "node_modules", ctx.probe.meta(p)?.isDirectory == true { queue.append((p, depth + 1)) }
            }
        }
        return files.filter { ctx.probe.exists($0) }
    }

    func servers(in file: String) -> [Server] {
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var blocks: [[String: Any]] = []
        if let m = json["mcpServers"] as? [String: Any] { blocks.append(m) }
        if let projects = json["projects"] as? [String: Any] {
            for case let p as [String: Any] in projects.values { if let m = p["mcpServers"] as? [String: Any] { blocks.append(m) } }
        }
        if blocks.isEmpty, json.values.contains(where: { ($0 as? [String: Any])?["command"] != nil }) { blocks.append(json) }
        return blocks.flatMap { block in
            block.compactMap { name, value -> Server? in
                guard let v = value as? [String: Any], let cmd = v["command"] as? String else { return nil }
                let base = (cmd as NSString).lastPathComponent
                guard base == "uvx" || base == "npx" else { return nil }
                let args = v["args"] as? [String] ?? []
                guard let pkg = args.first(where: { !$0.hasPrefix("-") }) else { return nil }
                return Server(name: name, command: base, package: pkg, file: file)
            }
        }
    }

    static func baseName(_ pkg: String) -> String {
        let scoped = pkg.hasPrefix("@")
        let body = scoped ? String(pkg.dropFirst()) : pkg
        guard let at = body.lastIndex(of: "@") else { return pkg }
        return (scoped ? "@" : "") + body[..<at]
    }
}

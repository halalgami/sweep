import Foundation

/// Plain paths from the rule (with globs). Each existing match becomes one item.
struct PathDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        let minBytes = rule.minBytes ?? 1_000_000
        let paths = (rule.paths ?? []).flatMap(ctx.expand)
        for path in paths {
            let size = ctx.measure(path)
            guard size.physical >= minBytes else { continue }
            let title = paths.count > 1 ? "\(rule.title): \((path as NSString).lastPathComponent)" : rule.title
            out.items.append(ItemFactory.make(rule: rule, path: path, title: title, size: size,
                                              action: ItemFactory.action(for: rule, path: path, toolPath: nil, ctx: ctx)))
        }
        return out
    }
}

/// Caches managed by a CLI tool: measured on disk, cleaned with the tool's own command.
struct ToolCacheDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        guard let toolName = rule.tool else { return DetectorOutput() }
        guard let tool = ctx.tools.path(for: toolName) else {
            return DetectorOutput(warnings: ["\(toolName) isn't installed, so \(rule.title) was skipped"])
        }
        var dir: String?
        if let cmd = rule.params?["dirCommand"] {
            let r = await ctx.runner.run(tool, cmd.split(separator: " ").map(String.init), timeout: 15)
            let candidate = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok, candidate.hasPrefix("/"), ctx.probe.exists(candidate) { dir = candidate }
        }
        if dir == nil { dir = (rule.paths ?? []).flatMap(ctx.expand).first }
        guard let dir else { return DetectorOutput() }
        let size = ctx.measure(dir)
        guard size.physical >= (rule.minBytes ?? 1_000_000) else { return DetectorOutput() }
        let action = ItemFactory.action(for: rule, path: dir, toolPath: tool, ctx: ctx)
        return DetectorOutput(items: [ItemFactory.make(rule: rule, path: dir, size: size, action: action,
                                                       evidence: ["Cleaned with `\(action.preview(path: dir))`"])])
    }
}

/// ~/Library/Caches split per app. Unreadable (Apple-protected) entries are counted, not reported as failures.
struct LibraryCachesDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        var protected = 0
        for base in (rule.paths ?? []).flatMap(ctx.expand) {
            for child in ctx.probe.childPaths(base) ?? [] {
                guard let meta = ctx.probe.meta(child), !meta.isSymlink else { continue }
                if meta.isDirectory, ctx.probe.children(child) == nil { protected += 1; continue }
                let size = ctx.measure(child)
                guard size.physical >= (rule.minBytes ?? 50_000_000) else { continue }
                let name = (child as NSString).lastPathComponent
                var evidence: [String] = []
                let kids = ctx.probe.children(child) ?? []
                if name.contains("ShipIt") || kids.contains(where: { $0.contains("Sparkle") || $0.contains("ShipIt") }) {
                    evidence.append("Contains a staged app update (Sparkle/ShipIt); the app downloads it again if needed")
                }
                out.items.append(ItemFactory.make(rule: rule, path: child, title: "\(name) cache", size: size,
                                                  action: ItemFactory.action(for: rule, path: child, toolPath: nil, ctx: ctx),
                                                  evidence: evidence))
            }
        }
        if protected > 0 {
            out.warnings.append("\(protected) Apple-protected cache folder(s) in ~/Library/Caches were skipped. That's normal.")
        }
        return out
    }
}

/// Tier 4: shown so totals add up, never actionable.
struct ProtectedDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        func list(_ key: String) -> [String] { (rule.params?[key] ?? "").split(separator: ",").map(String.init) }
        for pattern in list("clonePatterns") {
            for path in ctx.expand(pattern) {
                let size = ctx.measure(path)
                guard size.physical > 0 else { continue }
                out.items.append(ItemFactory.make(rule: rule, path: path, title: "APFS clone: \((path as NSString).lastPathComponent)",
                    size: size, action: .none(reason: "APFS clone: du overstates it and deleting it won't free space")))
            }
        }
        for pattern in list("sipPaths") {
            for path in ctx.expand(pattern) {
                let size = ctx.measure(path)
                guard size.physical > 0 else { continue }
                out.items.append(ItemFactory.make(rule: rule, path: path, title: "System-protected: \((path as NSString).lastPathComponent)",
                    size: size, action: .none(reason: "Protected by macOS System Integrity Protection")))
            }
        }
        return out
    }
}

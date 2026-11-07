import Foundation

/// Tier 2: build artifacts in idle projects. One item per artifact folder.
struct ProjectArtifactsDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        for root in ctx.settings.projectRoots.map({ PathPattern.expandHome($0, home: ctx.home) })
        where ctx.probe.exists(root) && ctx.probe.children(root) == nil {
            out.warnings.append("Sweep couldn't read \(root.replacingOccurrences(of: ctx.home, with: "~")) (macOS privacy). Allow access when asked, or grant Full Disk Access, to find idle projects there.")
        }
        let names = Set((rule.params?["artifacts"] ?? "").split(separator: ",").map(String.init))
        for project in ProjectDiscovery.projects(ctx) {
            let artifacts = findArtifacts(in: project, names: names, ctx: ctx)
            guard !artifacts.isEmpty else { continue }
            let v = await IdleChecker().verdict(project: project, context: ctx)
            guard v.idle else { continue }
            let projectName = (project as NSString).lastPathComponent
            var evidence = ["Project idle \(v.idleDays) days"]
            if let c = v.lastCommit { evidence.append("Last commit \(c.formatted(date: .abbreviated, time: .omitted))") }
            evidence.append("No dev server running")
            for path in artifacts {
                let size = ctx.sizer.measure(path)
                guard size.physical >= (rule.minBytes ?? 1_000_000) else { continue }
                let artifact = (path as NSString).lastPathComponent
                let rel = String(path.dropFirst(project.count + 1))
                var r = rule
                r.rebuildHint = rebuildCommand(artifact: artifact, dir: (path as NSString).deletingLastPathComponent, ctx: ctx)
                out.items.append(ItemFactory.make(rule: r, path: path, title: "\(projectName) / \(rel)", size: size,
                                                  action: ItemFactory.action(for: r, path: path, toolPath: nil, ctx: ctx),
                                                  evidence: evidence, lastUsed: [v.newestSource, v.lastCommit].compactMap { $0 }.max()))
            }
        }
        return out
    }

    func findArtifacts(in project: String, names: Set<String>, ctx: DetectionContext, maxDepth: Int = 4) -> [String] {
        var result: [String] = []
        var queue: [(String, Int)] = [(project, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let kids = ctx.probe.children(dir) else { continue }
            for k in kids.sorted() {
                let p = dir + "/" + k
                guard let m = ctx.probe.meta(p), m.isDirectory, !m.isSymlink else { continue }
                if names.contains(k) {
                    if k == "target", !kids.contains("Cargo.toml") { continue }
                    if k == "dist", !kids.contains("package.json"), !kids.contains("pyproject.toml") { continue }
                    result.append(p)
                } else if depth < maxDepth, k != ".git", !k.hasPrefix(".") {
                    queue.append((p, depth + 1))
                }
            }
        }
        return result
    }

    func rebuildCommand(artifact: String, dir: String, ctx: DetectionContext) -> String {
        let kids = Set(ctx.probe.children(dir) ?? [])
        switch artifact {
        case "node_modules":
            if kids.contains("pnpm-lock.yaml") { return "pnpm install" }
            if kids.contains("yarn.lock") { return "yarn install" }
            if kids.contains("bun.lockb") || kids.contains("bun.lock") { return "bun install" }
            return "npm install"
        case ".next": return "next build (or next dev)"
        case "target": return "cargo build"
        case ".venv", "venv":
            if kids.contains("uv.lock") { return "uv sync" }
            if kids.contains("poetry.lock") { return "poetry install" }
            return "python -m venv \(artifact) && pip install -r requirements.txt"
        case "dist": return "the project's build command (e.g. npm run build)"
        case ".sst", ".open-next": return "sst build / open-next build"
        case ".turbo": return "rebuilt by turbo on next run"
        default: return "rebuilt automatically on next run"
        }
    }
}

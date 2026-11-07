import Foundation

/// Offers `git worktree remove` only for worktrees that are clean, tracked upstream, and fully pushed.
struct GitWorktreeDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        guard let git = ctx.tools.path(for: "git") else { return DetectorOutput() }
        var out = DetectorOutput()
        for repo in ProjectDiscovery.projects(ctx) where ctx.probe.meta(repo + "/.git")?.isDirectory == true {
            let list = await ctx.runner.run(git, ["-C", repo, "worktree", "list", "--porcelain"], timeout: 15)
            guard list.ok else { continue }
            let paths = list.stdout.components(separatedBy: "\n\n").compactMap { block -> String? in
                guard let line = block.split(separator: "\n").first(where: { $0.hasPrefix("worktree ") }) else { return nil }
                if block.contains("\nbare") { return nil }
                return String(line.dropFirst("worktree ".count))
            }
            for wt in paths.dropFirst() where ctx.probe.exists(wt) {
                let status = await ctx.runner.run(git, ["-C", wt, "status", "--porcelain"], timeout: 30)
                guard status.ok, status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let upstream = await ctx.runner.run(git, ["-C", wt, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: 15)
                guard upstream.ok else { continue }
                let ahead = await ctx.runner.run(git, ["-C", wt, "rev-list", "--count", "@{u}..HEAD"], timeout: 15)
                guard ahead.ok, ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { continue }
                var merged = false
                for base in ["main", "master"] {
                    if await ctx.runner.run(git, ["-C", wt, "merge-base", "--is-ancestor", "HEAD", base], timeout: 15).ok { merged = true; break }
                }
                let size = ctx.sizer.measure(wt, skipDirNames: [])
                out.items.append(ItemFactory.make(
                    rule: rule, path: wt, title: "Worktree \((wt as NSString).lastPathComponent)", size: size,
                    action: ctx.probe.isDeletable(wt) ? .gitWorktreeRemove(repo: repo) : .revealInFinder,
                    evidence: ["Clean, no unpushed commits (upstream \(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))",
                               "merged to main: \(merged ? "yes" : "no")", "The branch is kept"]))
            }
        }
        return out
    }
}

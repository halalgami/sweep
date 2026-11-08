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
                let status = await ctx.runner.run(git, ["-C", wt, "status", "--porcelain", "--ignored"], timeout: 30)
                guard status.ok else { continue }
                let st = Self.parseStatus(status.stdout)
                guard st.changes.isEmpty else { continue }
                let upstream = await ctx.runner.run(git, ["-C", wt, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], timeout: 15)
                guard upstream.ok else { continue }
                let ahead = await ctx.runner.run(git, ["-C", wt, "rev-list", "--count", "@{u}..HEAD"], timeout: 15)
                guard ahead.ok, ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { continue }
                var merged = false
                for base in ["main", "master"] {
                    if await ctx.runner.run(git, ["-C", wt, "merge-base", "--is-ancestor", "HEAD", base], timeout: 15).ok { merged = true; break }
                }
                let size = ctx.measure(wt, skipDirNames: [])
                var evidence = ["Clean, no unpushed commits (upstream \(upstream.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))",
                                "merged to main: \(merged ? "yes" : "no")", "The branch is kept"]
                // `git worktree remove` permanently deletes ignored files. Build folders are fine; anything else
                // (.env, local data) means the user has to look first.
                if !st.personalIgnored.isEmpty {
                    evidence.append("Has ignored files git would delete permanently: \(st.personalIgnored.prefix(3).joined(separator: ", "))\(st.personalIgnored.count > 3 ? "…" : ""). Check them in Finder first")
                }
                let removable = ctx.probe.isDeletable(wt) && st.personalIgnored.isEmpty
                out.items.append(ItemFactory.make(
                    rule: rule, path: wt, title: "Worktree \((wt as NSString).lastPathComponent)", size: size,
                    action: removable ? .gitWorktreeRemove(repo: repo) : .revealInFinder,
                    evidence: evidence))
            }
        }
        return out
    }

    /// Ignored folders that are safe to lose with the worktree: build output and caches that rebuild.
    static let rebuildableIgnored: Set<String> = ProjectDiscovery.artifactNames.union([
        ".DS_Store", ".build", "build", "DerivedData", ".gradle", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        "coverage", ".cache", ".parcel-cache", ".swiftpm", "out", ".expo", ".nuxt", ".svelte-kit", ".angular",
    ])

    /// Splits `git status --porcelain --ignored` into real changes and ignored entries that aren't rebuildable.
    static func parseStatus(_ out: String) -> (changes: [String], personalIgnored: [String]) {
        var changes: [String] = [], personal: [String] = []
        for line in out.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard line.hasPrefix("!! ") else { changes.append(line); continue }
            let entry = String(line.dropFirst(3))
            let name = entry.split(separator: "/").last.map(String.init) ?? entry
            if !rebuildableIgnored.contains(name) && !name.hasSuffix(".pyc") { personal.append(entry) }
        }
        return (changes, personal)
    }
}

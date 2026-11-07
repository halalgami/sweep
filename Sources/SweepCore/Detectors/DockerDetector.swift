import Foundation

/// Docker cleanup. Never touches running containers or volumes. Only runs when the daemon is already up.
struct DockerDetector: Detector {
    static let trimArguments = ["run", "--rm", "--privileged", "--pid=host", "alpine", "nsenter", "-t", "1", "-m", "--", "fstrim", "-av"]

    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        guard let docker = ctx.tools.path(for: "docker") else { return DetectorOutput() }
        let info = await ctx.runner.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 8)
        guard info.ok else {
            return DetectorOutput(warnings: ["Docker isn't running, so \(rule.title.lowercased()) was skipped. Sweep never starts Docker itself."])
        }
        switch rule.params?["op"] {
        case "builder": return await builders(rule, ctx, docker)
        case "dangling": return await dangling(rule, ctx, docker)
        case "trim": return await trim(rule, ctx, docker)
        case "images": return await images(rule, ctx, docker)
        default: return DetectorOutput()
        }
    }

    private func builders(_ rule: Rule, _ ctx: DetectionContext, _ docker: String) async -> DetectorOutput {
        let ls = await ctx.runner.run(docker, ["buildx", "ls", "--format", "{{.Name}}"], timeout: 15)
        var names: [String] = []
        if ls.ok {
            for line in ls.stdout.split(separator: "\n") {
                let n = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
                if !n.isEmpty, !names.contains(n), !n.hasPrefix("\\_") { names.append(n) }
            }
        }
        guard !names.isEmpty else {
            // No buildx: fall back to the classic builder cache.
            let df = await ctx.runner.run(docker, ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"], timeout: 20)
            let bytes = df.stdout.split(separator: "\n").first { $0.hasPrefix("Build Cache") }
                .map { Self.parseSize(String($0.split(separator: "\t").last ?? "")) } ?? 0
            var s = SizeResult(); s.physical = bytes; s.logical = bytes
            return DetectorOutput(items: [ItemFactory.make(rule: rule, path: "docker://builder", size: s,
                                                           action: .dockerCommand(arguments: ["builder", "prune", "-f"]))])
        }
        var out = DetectorOutput()
        for name in names {
            let du = await ctx.runner.run(docker, ["buildx", "du", "--builder", name], timeout: 30)
            let reclaim = du.stdout.split(separator: "\n").first { $0.hasPrefix("Reclaimable:") }
                .map { Self.parseSize($0.replacingOccurrences(of: "Reclaimable:", with: "")) } ?? 0
            var s = SizeResult(); s.physical = reclaim; s.logical = reclaim
            out.items.append(ItemFactory.make(rule: rule, path: "docker://builder/\(name)", title: "Docker build cache (\(name))",
                                              size: s, action: .dockerCommand(arguments: ["buildx", "prune", "-f", "--builder", name]),
                                              evidence: du.ok ? [] : ["Couldn't measure this builder; it may be stopped"]))
        }
        return out
    }

    private func dangling(_ rule: Rule, _ ctx: DetectionContext, _ docker: String) async -> DetectorOutput {
        let r = await ctx.runner.run(docker, ["images", "-f", "dangling=true", "--format", "{{.ID}}\t{{.Size}}"], timeout: 20)
        let lines = r.stdout.split(separator: "\n")
        guard r.ok, !lines.isEmpty else { return DetectorOutput() }
        let bytes = lines.reduce(Int64(0)) { $0 + Self.parseSize(String($1.split(separator: "\t").last ?? "")) }
        var s = SizeResult(); s.physical = bytes; s.logical = bytes
        return DetectorOutput(items: [ItemFactory.make(rule: rule, path: "docker://images/dangling", title: "\(lines.count) dangling Docker image(s)",
                                                       size: s, action: .dockerCommand(arguments: ["image", "prune", "-f"]),
                                                       evidence: ["Shared layers mean the space actually freed may be smaller"])])
    }

    private func trim(_ rule: Rule, _ ctx: DetectionContext, _ docker: String) async -> DetectorOutput {
        let candidates = ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                          "~/.colima/_lima/colima/diffdisk", "~/.colima/_lima/_disks/colima/datadisk"]
        guard let raw = candidates.flatMap(ctx.expand).first, let meta = ctx.probe.meta(raw) else { return DetectorOutput() }
        let df = await ctx.runner.run(docker, ["system", "df", "--format", "{{.Size}}"], timeout: 20)
        let inUse = df.stdout.split(separator: "\n").reduce(Int64(0)) { $0 + Self.parseSize(String($1)) }
        let reclaim = max(0, meta.allocatedSize - inUse)
        guard reclaim > 1_000_000_000 else { return DetectorOutput() }
        var s = SizeResult(); s.physical = reclaim; s.logical = reclaim
        return DetectorOutput(items: [ItemFactory.make(
            rule: rule, path: raw, title: "Shrink Docker disk image", size: s, action: .dockerCommand(arguments: Self.trimArguments),
            evidence: ["Disk image uses \(ByteFormat.string(meta.allocatedSize)) but Docker reports \(ByteFormat.string(inUse)) in use",
                       "Runs fstrim inside Docker's VM (pulls the small alpine image if missing); \"discard not supported\" lines are harmless"])])
    }

    private func images(_ rule: Rule, _ ctx: DetectionContext, _ docker: String) async -> DetectorOutput {
        let r = await ctx.runner.run(docker, ["images", "--format", "{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}"], timeout: 20)
        let used = await ctx.runner.run(docker, ["ps", "-a", "--format", "{{.Image}}"], timeout: 20)
        guard r.ok, used.ok else { return DetectorOutput() }
        let inUse = Set(used.stdout.split(separator: "\n").map(String.init))
        var out = DetectorOutput()
        for line in r.stdout.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 3, !f[1].contains("<none>") else { continue }
            let id = f[0], name = f[1]
            if inUse.contains(name) || inUse.contains(id) || inUse.contains(where: { id.hasPrefix($0) || $0.hasPrefix(id) }) { continue }
            if name.hasSuffix(":latest"), inUse.contains(String(name.dropLast(7))) { continue }
            var s = SizeResult(); s.physical = Self.parseSize(f[2]); s.logical = s.physical
            out.items.append(ItemFactory.make(rule: rule, path: "docker://image/\(id)", title: "Docker image \(name)", size: s,
                                              action: .dockerCommand(arguments: ["image", "rm", id]), evidence: ["No container uses this image"]))
        }
        return out
    }

    /// Docker prints decimal sizes like "1.2GB", "512kB", "0B".
    static func parseSize(_ raw: String) -> Int64 {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, mult) in units where s.hasSuffix(u) {
            guard let v = Double(s.dropLast(u.count).trimmingCharacters(in: .whitespaces)) else { return 0 }
            return Int64((v * mult).rounded())
        }
        return 0
    }
}

import Foundation

/// Docker cleanup. Never touches running containers or volumes. Only runs when the daemon is already up.
struct DockerDetector: Detector {
    /// Pinned by digest (multi-arch index of alpine 3.22) so a re-pushed tag can't change what runs privileged.
    static let trimImage = "alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f"
    static let trimArguments = ["run", "--rm", "--privileged", "--pid=host", Self.trimImage, "nsenter", "-t", "1", "-m", "--", "fstrim", "-av"]

    /// Docker settings from the environment (`DOCKER_HOST`, `DOCKER_CONTEXT`) can point the CLI at another machine.
    /// Sweep drops them, so the CLI uses the context in ~/.docker/config.json, and `isLocal` checks that one.
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"].contains($0.key) }
    }

    static func run(_ runner: CommandRunner, _ docker: String, _ args: [String], timeout: TimeInterval) async -> CommandResult {
        await runner.run(docker, args, timeout: timeout, environment: environment, currentDirectory: nil)
    }

    /// True only when the active Docker context talks to a daemon on this Mac (a unix socket).
    static func isLocal(_ docker: String, _ runner: CommandRunner) async -> Bool {
        let r = await run(runner, docker, ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout: 8)
        return r.ok && r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://")
    }

    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        guard let docker = ctx.tools.path(for: "docker") else { return DetectorOutput() }
        let info = await Self.run(ctx.runner, docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 8)
        guard info.ok else {
            return DetectorOutput(warnings: ["Docker isn't running, so \(rule.title.lowercased()) was skipped. Sweep never starts Docker itself."])
        }
        guard await Self.isLocal(docker, ctx.runner) else {
            return DetectorOutput(warnings: ["Docker is set up to use a daemon that isn't on this Mac, so \(rule.title.lowercased()) was skipped."])
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
        let ls = await Self.run(ctx.runner, docker, ["buildx", "ls", "--format", "{{.Name}}"], timeout: 15)
        var names: [String] = []
        if ls.ok {
            for line in ls.stdout.split(separator: "\n") {
                let n = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
                if !n.isEmpty, !names.contains(n), !n.hasPrefix("\\_") { names.append(n) }
            }
        }
        guard !names.isEmpty else {
            // No buildx: fall back to the classic builder cache.
            let df = await Self.run(ctx.runner, docker, ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"], timeout: 20)
            let bytes = df.stdout.split(separator: "\n").first { $0.hasPrefix("Build Cache") }
                .map { Self.parseSize(String($0.split(separator: "\t").last ?? "")) } ?? 0
            var s = SizeResult(); s.physical = bytes; s.logical = bytes
            return DetectorOutput(items: [ItemFactory.make(rule: rule, path: "docker://builder", size: s,
                                                           action: .dockerCommand(arguments: ["builder", "prune", "-f"]))])
        }
        var out = DetectorOutput()
        for name in names {
            let du = await Self.run(ctx.runner, docker, ["buildx", "du", "--builder", name], timeout: 30)
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
        let r = await Self.run(ctx.runner, docker, ["images", "-f", "dangling=true", "--format", "{{.ID}}\t{{.Size}}"], timeout: 20)
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
        let df = await Self.run(ctx.runner, docker, ["system", "df", "--format", "{{.Size}}"], timeout: 20)
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
        let r = await Self.run(ctx.runner, docker, ["images", "--format", "{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}"], timeout: 20)
        let used = await Self.run(ctx.runner, docker, ["ps", "-a", "--format", "{{.Image}}"], timeout: 20)
        guard r.ok, used.ok else { return DetectorOutput() }
        let inUse = Set(used.stdout.split(separator: "\n").map(String.init))
        // One image can carry several tags; `docker image rm <id>` refuses those, so remove it by all its tags at once.
        var order: [String] = []
        var tags: [String: [String]] = [:]
        var sizes: [String: Int64] = [:]
        for line in r.stdout.split(separator: "\n") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 3, !f[1].contains("<none>") else { continue }
            if tags[f[0]] == nil { order.append(f[0]) }
            tags[f[0], default: []].append(f[1])
            sizes[f[0]] = Self.parseSize(f[2])
        }
        func isUsed(_ id: String, _ name: String) -> Bool {
            if inUse.contains(name) || inUse.contains(id) || inUse.contains(where: { id.hasPrefix($0) || $0.hasPrefix(id) }) { return true }
            return name.hasSuffix(":latest") && inUse.contains(String(name.dropLast(7)))
        }
        var out = DetectorOutput()
        for id in order {
            let names = tags[id] ?? []
            guard !names.contains(where: { isUsed(id, $0) }) else { continue }
            var s = SizeResult(); s.physical = sizes[id] ?? 0; s.logical = s.physical
            let title = "Docker image \(names[0])" + (names.count > 1 ? " (+\(names.count - 1) more tag\(names.count > 2 ? "s" : ""))" : "")
            out.items.append(ItemFactory.make(rule: rule, path: "docker://image/\(id)", title: title, size: s,
                                              action: .dockerCommand(arguments: ["image", "rm"] + names), evidence: ["No container uses this image"]))
        }
        return out
    }

    /// Docker prints decimal sizes like "1.2GB", "512kB", "0B".
    static func parseSize(_ raw: String) -> Int64 {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let paren = s.firstIndex(of: "(") { s = s[..<paren].trimmingCharacters(in: .whitespaces) }   // "1.2GB (50%)"
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, mult) in units where s.hasSuffix(u) {
            guard let v = Double(s.dropLast(u.count).trimmingCharacters(in: .whitespaces)) else { return 0 }
            return Int64((v * mult).rounded())
        }
        return 0
    }
}

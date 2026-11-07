import Foundation

/// Xcode simulator runtimes, sized by `simctl` (CoreSimulator `du` is inflated by mounted disk images).
struct SimRuntimeDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        guard let xcrun = ctx.tools.path(for: "xcrun") else { return DetectorOutput() }
        let r = await ctx.runner.run(xcrun, ["simctl", "runtime", "list", "-j"], timeout: 60)
        guard r.ok, let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: [String: Any]] else {
            return DetectorOutput(warnings: r.ok ? [] : ["Couldn't list simulator runtimes (is Xcode installed?)"])
        }
        let iso = ISO8601DateFormatter()
        var out = DetectorOutput()
        for (key, rt) in obj.sorted(by: { $0.key < $1.key }) {
            let id = rt["identifier"] as? String ?? key
            let bytes = (rt["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let platform = (rt["runtimeIdentifier"] as? String ?? "").components(separatedBy: ".").last?
                .components(separatedBy: "-").first ?? "Simulator"
            let version = rt["version"] as? String ?? "?"
            let lastUsed = (rt["lastUsedAt"] as? String).flatMap(iso.date(from:))
            var s = SizeResult(); s.physical = bytes; s.logical = bytes
            var evidence = ["Size reported by simctl (du overstates mounted runtimes)"]
            if let lastUsed { evidence.append("Last used \(FileWalker.days(lastUsed, ctx.now)) days ago") }
            let deletable = rt["deletable"] as? Bool ?? false
            out.items.append(ItemFactory.make(
                rule: rule, path: "simruntime://\(id)", title: "\(platform) \(version) simulator runtime", size: s,
                action: deletable ? .toolCommand(executable: xcrun, arguments: ["simctl", "runtime", "delete", id])
                                  : .none(reason: "macOS manages this runtime and it can't be deleted"),
                evidence: evidence, tier: deletable ? rule.tier : .protected, lastUsed: lastUsed))
        }
        return out
    }
}

struct VMDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        for path in (rule.paths ?? []).flatMap(ctx.expand) {
            let size = ctx.sizer.measure(path)
            guard size.physical > 0 else { continue }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let booted = FileWalker.newestMTime(under: path, suffix: ".log", maxDepth: 3, probe: ctx.probe)
            let evidence = booted.map { ["Last booted \(FileWalker.days($0, ctx.now)) days ago"] } ?? ["No boot logs found"]
            out.items.append(ItemFactory.make(rule: rule, path: path, title: "\(name) (VM)", size: size,
                                              action: ItemFactory.action(for: rule, path: path, toolPath: nil, ctx: ctx),
                                              evidence: evidence, lastUsed: booted))
        }
        return out
    }
}

struct CondaDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = await PathDetector().detect(rule: rule, context: ctx)
        let shellFiles = [".zshrc", ".bash_profile", ".bashrc", ".zprofile"].map { "\(ctx.home)/\($0)" }
        let initialized = shellFiles.contains { (try? String(contentsOfFile: $0, encoding: .utf8))?.contains("conda initialize") == true }
        for i in out.items.indices {
            let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
            let first = pathEnv.split(separator: ":").first { FileManager.default.isExecutableFile(atPath: "\($0)/python3") }
            if initialized || first.map({ $0.hasPrefix(out.items[i].path) }) == true {
                out.items[i].evidence.append("Warning: conda is set up in your shell and may provide your python3. Removing it changes which Python runs.")
                out.items[i].defaultSelected = false
            }
        }
        return out
    }
}

struct LLMModelsDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        if let ollama = ctx.tools.path(for: "ollama") {
            let r = await ctx.runner.run(ollama, ["list"], timeout: 20)
            if r.ok {
                for line in r.stdout.split(separator: "\n").dropFirst() {
                    let cols = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard cols.count >= 3 else { continue }
                    var s = SizeResult(); s.physical = Self.parseHumanSize(cols[2]); s.logical = s.physical
                    out.items.append(ItemFactory.make(rule: rule, path: "ollama://\(cols[0])", title: "Ollama model \(cols[0])", size: s,
                                                      action: .toolCommand(executable: ollama, arguments: ["rm", cols[0]]),
                                                      evidence: cols.count > 3 ? ["Modified \(cols[3])", "Layers shared between models free less"] : []))
                }
            }
        }
        // LM Studio: one item per model folder; flag files duplicated elsewhere.
        var bigFiles: [(String, FileMeta)] = []
        for base in (rule.paths ?? []).filter({ !$0.contains(".ollama") }).flatMap(ctx.expand) {
            for publisher in ctx.probe.childPaths(base) ?? [] {
                for model in ctx.probe.childPaths(publisher) ?? [] where ctx.probe.meta(model)?.isDirectory == true {
                    let size = ctx.sizer.measure(model)
                    guard size.physical > 0 else { continue }
                    out.items.append(ItemFactory.make(rule: rule, path: model, title: "LM Studio model \((model as NSString).lastPathComponent)",
                                                      size: size, action: ItemFactory.action(for: rule, path: model, toolPath: nil, ctx: ctx)))
                    bigFiles += FileWalker.files(under: model, maxDepth: 2, probe: ctx.probe).filter { $0.1.logicalSize > 100_000_000 }
                }
            }
        }
        bigFiles += ctx.expand("~/.ollama/models/blobs").flatMap { FileWalker.files(under: $0, maxDepth: 0, probe: ctx.probe) }
            .filter { $0.1.logicalSize > 100_000_000 }
        let dupes = Self.duplicates(bigFiles)
        for i in out.items.indices {
            if let d = dupes.first(where: { $0.0.hasPrefix(out.items[i].path + "/") }) {
                out.items[i].evidence.append("Contains a file identical to \(d.1)")
            }
        }
        return out
    }

    /// Same size + same SHA-256 of first and last MB.
    static func duplicates(_ files: [(String, FileMeta)]) -> [(String, String)] {
        var result: [(String, String)] = []
        for group in Dictionary(grouping: files, by: { $0.1.logicalSize }).values where group.count > 1 {
            var seen: [String: String] = [:]
            for (path, meta) in group {
                guard let h = partialHash(path, size: meta.logicalSize) else { continue }
                if let other = seen[h] { result.append((path, other)) } else { seen[h] = path }
            }
        }
        return result
    }

    static func partialHash(_ path: String, size: Int64) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let chunk = 1 << 20
        var data = (try? fh.read(upToCount: chunk)) ?? Data()
        if size > Int64(chunk) {
            try? fh.seek(toOffset: UInt64(size - Int64(chunk)))
            data += (try? fh.read(upToCount: chunk)) ?? Data()
        }
        return Item.makeID(category: "hash", key: data.base64EncodedString())
    }

    static func parseHumanSize(_ s: String) -> Int64 {
        let parts = s.split(separator: " ")
        guard parts.count == 2, let v = Double(parts[0]) else { return 0 }
        let mult: Double = ["KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12][String(parts[1])] ?? 1
        return Int64(v * mult)
    }
}

struct LargeFilesDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        for base in (rule.paths ?? []).flatMap(ctx.expand) {
            for (path, m) in FileWalker.files(under: base, maxDepth: 6, skipDirs: ProjectDiscovery.artifactNames, probe: ctx.probe)
            where !m.isDataless && m.allocatedSize >= ctx.settings.largeFileBytes {
                out.items.append(ItemFactory.make(rule: rule, path: path, title: (path as NSString).lastPathComponent, size: FileWalker.size(m),
                                                  action: ItemFactory.action(for: rule, path: path, toolPath: nil, ctx: ctx),
                                                  evidence: ["Modified \(FileWalker.days(m.mtime, ctx.now)) days ago"], lastUsed: m.mtime))
            }
        }
        return out
    }
}

struct InstallersDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        let exts = Set((rule.params?["extensions"] ?? "dmg,pkg,zip").split(separator: ",").map(String.init))
        let olderThan = Int(rule.params?["olderThanDays"] ?? "30") ?? 30
        for base in (rule.paths ?? []).flatMap(ctx.expand) {
            for (path, m) in FileWalker.files(under: base, maxDepth: 1, probe: ctx.probe)
            where exts.contains((path as NSString).pathExtension.lowercased()) && !m.isDataless
                && m.allocatedSize >= 1_000_000 && FileWalker.days(m.mtime, ctx.now) >= olderThan {
                out.items.append(ItemFactory.make(rule: rule, path: path, title: (path as NSString).lastPathComponent, size: FileWalker.size(m),
                                                  action: ItemFactory.action(for: rule, path: path, toolPath: nil, ctx: ctx),
                                                  evidence: ["Downloaded \(FileWalker.days(m.mtime, ctx.now)) days ago"], lastUsed: m.mtime))
            }
        }
        return out
    }
}

/// Old Xcode device support folders: keep the newest N per platform.
struct DeviceSupportDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        let keep = Int(rule.params?["keepNewest"] ?? "2") ?? 2
        for base in (rule.paths ?? []).flatMap(ctx.expand) {
            let dirs = (ctx.probe.childPaths(base) ?? []).compactMap { p in ctx.probe.meta(p).flatMap { $0.isDirectory ? (p, $0.mtime) : nil } }
                .sorted { $0.1 > $1.1 }
            for (path, mtime) in dirs.dropFirst(keep) {
                let size = ctx.sizer.measure(path)
                out.items.append(ItemFactory.make(rule: rule, path: path,
                                                  title: "\((base as NSString).lastPathComponent) \((path as NSString).lastPathComponent)",
                                                  size: size, action: ItemFactory.action(for: rule, path: path, toolPath: nil, ctx: ctx),
                                                  evidence: ["Newer versions are kept"], lastUsed: mtime))
            }
        }
        return out
    }
}

/// Large data extracts inside projects. Shown, never deleted by Sweep, never sent to the AI.
struct SensitiveDataDetector: Detector {
    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        let exts = Set((rule.params?["extensions"] ?? "").split(separator: ",").map(String.init))
        for project in ProjectDiscovery.projects(ctx) {
            for (path, m) in FileWalker.files(under: project, maxDepth: 6, skipDirs: ProjectDiscovery.artifactNames.union([".git"]), probe: ctx.probe)
            where exts.contains((path as NSString).pathExtension.lowercased()) && m.logicalSize >= ctx.settings.sensitiveBytes {
                out.items.append(ItemFactory.make(rule: rule, path: path,
                                                  title: "Data file in \((project as NSString).lastPathComponent): \((path as NSString).lastPathComponent)",
                                                  size: FileWalker.size(m), action: .revealInFinder,
                                                  evidence: ["May contain personal data. Consider moving it to approved storage."],
                                                  sensitive: true, defaultSelected: false))
            }
        }
        return out
    }
}

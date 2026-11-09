import Foundation

/// VS Code / Cursor keep old extension versions. Group `<publisher.name>-<version>` and keep the one in use:
/// the folder the editor's own `extensions.json` points at, or the highest version when that file is missing.
/// (Newest-by-date is wrong after a downgrade.)
struct EditorExtensionsDetector: Detector {
    static let versionPattern = try! NSRegularExpression(pattern: #"^(.+?)-(\d+\.\d+\.\d+.*)$"#)

    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        for base in (rule.paths ?? []).flatMap(ctx.expand) {
            let inUse = Self.installedLocations(base: base)
            var groups: [String: [(path: String, name: String, version: String)]] = [:]
            for name in ctx.probe.children(base) ?? [] {
                let path = base + "/" + name
                guard let m = ctx.probe.meta(path), m.isDirectory,
                      let match = Self.versionPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let idR = Range(match.range(at: 1), in: name), let vR = Range(match.range(at: 2), in: name) else { continue }
                groups[String(name[idR]), default: []].append((path, name, String(name[vR])))
            }
            for (ext, versions) in groups.sorted(by: { $0.key < $1.key }) where versions.count > 1 {
                let sorted = versions.sorted { Self.isNewer($0.version, than: $1.version) }
                let keep = sorted.first { inUse?.contains($0.name) == true } ?? sorted[0]
                for old in sorted where old.path != keep.path {
                    let size = await ctx.measure(old.path)
                    out.items.append(ItemFactory.make(
                        rule: rule, path: old.path, title: "\(ext) \(old.version) (old version)", size: size,
                        action: ItemFactory.action(for: rule, path: old.path, toolPath: nil, ctx: ctx),
                        evidence: ["Version \(keep.version) is the one installed"]))
                }
            }
        }
        return out
    }

    /// Folder names listed in the editor's `extensions.json` (`relativeLocation`), or nil when it can't be read.
    static func installedLocations(base: String) -> Set<String>? {
        guard let data = FileManager.default.contents(atPath: base + "/extensions.json"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let names = list.compactMap { entry -> String? in
            if let rel = entry["relativeLocation"] as? String { return rel }
            if let loc = entry["location"] as? [String: Any], let p = loc["path"] as? String { return (p as NSString).lastPathComponent }
            return nil
        }
        return names.isEmpty ? nil : Set(names)
    }

    /// Numeric, component-wise version comparison ("2025.10.0" is newer than "2025.9.0").
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return a > b
    }
}

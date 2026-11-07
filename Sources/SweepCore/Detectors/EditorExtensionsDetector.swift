import Foundation

/// VS Code / Cursor keep old extension versions. Group `<publisher.name>-<version>` and keep the newest by mtime.
struct EditorExtensionsDetector: Detector {
    static let versionPattern = try! NSRegularExpression(pattern: #"^(.+?)-(\d+\.\d+\.\d+.*)$"#)

    func detect(rule: Rule, context ctx: DetectionContext) async -> DetectorOutput {
        var out = DetectorOutput()
        for base in (rule.paths ?? []).flatMap(ctx.expand) {
            var groups: [String: [(path: String, version: String, mtime: Date)]] = [:]
            for name in ctx.probe.children(base) ?? [] {
                let path = base + "/" + name
                guard let m = ctx.probe.meta(path), m.isDirectory,
                      let match = Self.versionPattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let idR = Range(match.range(at: 1), in: name), let vR = Range(match.range(at: 2), in: name) else { continue }
                groups[String(name[idR]), default: []].append((path, String(name[vR]), m.mtime))
            }
            for (ext, versions) in groups.sorted(by: { $0.key < $1.key }) where versions.count > 1 {
                let sorted = versions.sorted { $0.mtime > $1.mtime }
                for old in sorted.dropFirst() {
                    let size = ctx.sizer.measure(old.path)
                    out.items.append(ItemFactory.make(
                        rule: rule, path: old.path, title: "\(ext) \(old.version) (old version)", size: size,
                        action: ItemFactory.action(for: rule, path: old.path, toolPath: nil, ctx: ctx),
                        evidence: ["Newer version \(sorted[0].version) is installed"]))
                }
            }
        }
        return out
    }
}

import Foundation

/// Finds project folders under the configured roots without descending into build artifacts.
public enum ProjectDiscovery {
    public static let markers = [".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "Package.swift", "requirements.txt"]
    public static let artifactNames: Set<String> = ["node_modules", ".next", ".open-next", ".sst", "target", ".venv", "venv",
                                                    ".turbo", "dist", "__pycache__", ".transformers_cache"]
    static let neverDescend: Set<String> = ["Library", ".Trash", ".git", "Pods", "DerivedData", "build", ".build"]

    public static func projects(_ ctx: DetectionContext, maxDepth: Int = 4) -> [String] {
        var found: [String] = []
        for root in ctx.settings.projectRoots {
            var queue: [(String, Int)] = [(PathPattern.expandHome(root, home: ctx.home), 0)]
            while !queue.isEmpty {
                let (dir, depth) = queue.removeFirst()
                guard let names = ctx.probe.children(dir) else { continue }
                if names.contains(where: markers.contains) { found.append(dir); continue }
                guard depth < maxDepth else { continue }
                for n in names.sorted() where !n.hasPrefix(".") && !artifactNames.contains(n) && !neverDescend.contains(n)
                    && !n.hasSuffix(".app") && !n.hasSuffix(".photoslibrary") {
                    let p = dir + "/" + n
                    if let m = ctx.probe.meta(p), m.isDirectory, !m.isSymlink { queue.append((p, depth + 1)) }
                }
            }
        }
        return found
    }
}

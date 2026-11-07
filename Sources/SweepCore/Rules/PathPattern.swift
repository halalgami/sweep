import Darwin
import Foundation

/// Expands `~` and single-component globs (`*`, `?`) without a shell. Unmatched patterns yield [].
public enum PathPattern {
    public static func expand(_ pattern: String, home: String, probe: FileSystemProbe) -> [String] {
        var p = pattern
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        guard p.hasPrefix("/") else { return [] }
        var current = ["/"]
        for comp in p.split(separator: "/").map(String.init) {
            var next: [String] = []
            for base in current {
                if comp.contains("*") || comp.contains("?") {
                    for name in (probe.children(base) ?? []).sorted() where fnmatch(comp, name, 0) == 0 {
                        next.append(join(base, name))
                    }
                } else {
                    let candidate = join(base, comp)
                    if probe.meta(candidate) != nil { next.append(candidate) }
                }
            }
            current = next
            if current.isEmpty { return [] }
        }
        return current
    }

    public static func expandHome(_ path: String, home: String) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }

    static func join(_ base: String, _ name: String) -> String { base == "/" ? "/" + name : base + "/" + name }
}

import Foundation

/// Removes identifying names before anything is sent to an LLM.
/// Usernames become `~` / `<user>`; under sensitive roots, project and file names become `project_NN` / `file.ext`.
public final class Redactor: @unchecked Sendable {
    public let home: String
    public let sensitiveRoots: [String]
    public let revealNames: Bool
    private var projects: [String: Int] = [:]
    private let lock = NSLock()
    static let keepNames: Set<String> = ProjectDiscovery.artifactNames.union([".git", "Library", "Caches"])

    public init(home: String, sensitiveRoots: [String], revealNames: Bool) {
        self.home = home
        self.sensitiveRoots = sensitiveRoots.map { PathPattern.expandHome($0, home: home) }.sorted { $0.count > $1.count }
        self.revealNames = revealNames
    }

    public convenience init(settings: ScanSettings, home: String = NSHomeDirectory()) {
        let roots = ["Documents", "Desktop", "Downloads"].map { "\(home)/\($0)" } + settings.projectRoots
        self.init(home: home, sensitiveRoots: roots, revealNames: settings.revealProjectNames)
    }

    public func redact(path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        if !revealNames, let root = sensitiveRoots.first(where: { path.hasPrefix($0 + "/") }) {
            let comps = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            guard !comps.isEmpty else { return tilde(root) }
            let n = lock.withLock { () -> Int in
                if let n = projects[comps[0]] { return n }
                let n = projects.count + 1; projects[comps[0]] = n; return n
            }
            var out = tilde(root) + String(format: "/project_%02d", n)
            let rest = comps.dropFirst()
            if let last = rest.last {
                let keptLast = Self.keepNames.contains(last) ? last
                    : ((last as NSString).pathExtension.isEmpty ? "folder" : "file." + (last as NSString).pathExtension.lowercased())
                if rest.count > 1 { out += "/…" }
                out += "/" + keptLast
            }
            return out
        }
        return tilde(path)
    }

    /// Replaces home and other users' paths inside free text.
    public func redact(text: String) -> String {
        var s = text.replacingOccurrences(of: home, with: "~")
        s = s.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "/Users/<user>", options: .regularExpression)
        return s
    }

    func tilde(_ p: String) -> String {
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "/Users/<user>", options: .regularExpression)
    }
}

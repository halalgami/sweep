import Darwin
import Foundation

public enum SafetyVerdict: Sendable, Hashable {
    case allowed
    case blocked(String)
}

/// Re-checks every item immediately before it's acted on. Plan-time checks are not trusted at execution time.
public struct SafetyGuard: Sendable {
    public let context: DetectionContext
    public let rules: RuleSet
    public let protected: ProtectedLocations

    static let allowedTools: Set<String> = ["uv", "npm", "pnpm", "brew", "go", "xcrun", "ollama", "git"]

    public init(context: DetectionContext, rules: RuleSet, protected: ProtectedLocations) {
        self.context = context; self.rules = rules; self.protected = protected
    }

    public func check(_ item: Item) async -> SafetyVerdict {
        if item.tier == .protected { return .blocked("Protected items are never touched") }
        switch item.action {
        case let .none(reason): return .blocked(reason)
        case .revealInFinder: return .blocked("This one has to be removed by hand in Finder")
        default: break
        }
        if let rule = rules.rule(item.category), let b = ItemFactory.blocker(rule, context) { return .blocked(b) }

        switch item.action {
        case let .dockerCommand(args):
            return Self.dockerAllowed(args) ? .allowed : .blocked("That Docker command isn't on Sweep's allow list")
        case let .toolCommand(exe, _):
            let tool = (exe as NSString).lastPathComponent
            guard Self.allowedTools.contains(tool) else { return .blocked("\(exe) isn't on Sweep's allow list") }
            guard context.tools.path(for: tool) == exe else { return .blocked("\(tool) is no longer installed at \(exe)") }
            return .allowed
        default:
            return await checkPath(item)
        }
    }

    static func dockerAllowed(_ a: [String]) -> Bool {
        if a == ["builder", "prune", "-f"] || a == ["image", "prune", "-f"] || a == DockerDetector.trimArguments { return true }
        if a.count == 5, Array(a.prefix(4)) == ["buildx", "prune", "-f", "--builder"], !a[4].hasPrefix("-") { return true }
        if a.count == 3, a[0] == "image", a[1] == "rm", !a[2].hasPrefix("-") { return true }
        return false
    }

    /// Strip the /private prefix macOS adds when resolving /var, /tmp and /etc.
    static func normalize(_ p: String) -> String {
        for pre in ["/private/var/", "/private/tmp/", "/private/etc/"] where p.hasPrefix(pre) { return String(p.dropFirst(8)) }
        return p
    }

    func checkPath(_ item: Item) async -> SafetyVerdict {
        let path = item.path
        guard path.hasPrefix("/") else { return .blocked("Not a file path") }
        guard let meta = context.probe.meta(path) else { return .blocked("It no longer exists") }
        if meta.isSymlink { return .blocked("It was replaced by a link since the scan") }
        if let resolved = realpath(path, nil) {
            let r = String(cString: resolved); free(resolved)
            if Self.normalize(r) != Self.normalize(path) { return .blocked("Its location now goes through a link to \(r)") }
        }
        if let reason = protected.reason(for: path) ?? protected.reason(for: Self.normalize(path)) { return .blocked(reason) }

        if item.tier == .idleArtifact, case .hardDelete = item.action, let project = projectRoot(of: path) {
            var now = context
            now.now = Date()   // judge idleness at execution time, not scan time
            let v = await IdleChecker().verdict(project: project, context: now)
            if !v.idle { return .blocked("The project is active again: \(v.reasons.first ?? "recent activity")") }
        }
        if case .gitWorktreeRemove = item.action, let git = context.tools.path(for: "git") {
            let s = await context.runner.run(git, ["-C", path, "status", "--porcelain"], timeout: 30)
            if !s.ok || !s.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .blocked("The worktree now has uncommitted changes")
            }
        }
        return .allowed
    }

    func projectRoot(of artifact: String) -> String? {
        var dir = (artifact as NSString).deletingLastPathComponent
        while dir.count > 1 {
            if let kids = context.probe.children(dir), kids.contains(where: ProjectDiscovery.markers.contains) { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
}

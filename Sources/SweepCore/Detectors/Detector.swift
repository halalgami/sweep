import Foundation

public struct ScanSettings: Codable, Sendable, Hashable {
    public var projectRoots: [String]
    public var idleDays: Int = 14
    public var protectedPaths: [String] = []
    public var largeFileBytes: Int64 = 1_000_000_000
    public var sensitiveBytes: Int64 = 50_000_000
    public var revealProjectNames: Bool = false

    public init(projectRoots: [String], idleDays: Int = 14, protectedPaths: [String] = [],
                largeFileBytes: Int64 = 1_000_000_000, sensitiveBytes: Int64 = 50_000_000, revealProjectNames: Bool = false) {
        self.projectRoots = projectRoots; self.idleDays = idleDays; self.protectedPaths = protectedPaths
        self.largeFileBytes = largeFileBytes; self.sensitiveBytes = sensitiveBytes; self.revealProjectNames = revealProjectNames
    }

    public static func defaults(home: String = NSHomeDirectory()) -> ScanSettings {
        ScanSettings(projectRoots: ["Documents", "Developer", "Projects", "code", "src", "Desktop"].map { "\(home)/\($0)" })
    }
}

public struct DetectionContext: Sendable {
    public var home: String
    public var runner: CommandRunner
    public var tools: ToolLocating
    public var probe: FileSystemProbe
    public var processes: ProcessListing
    public var settings: ScanSettings
    public var now: Date
    /// Checked by long walks so "Stop" takes effect promptly.
    public var isCancelled: @Sendable () -> Bool = { false }
    public var sizer: SizeCalculator { SizeCalculator(probe: probe) }
    /// Physical size of `path`, measured off the cooperative thread pool (see `Blocking`).
    public func measure(_ path: String, skipDirNames: Set<String> = []) async -> SizeResult {
        let sizer = sizer, cancelled = isCancelled
        return await Blocking.run { sizer.measure(path, skipDirNames: skipDirNames, shouldCancel: cancelled) }
    }

    public init(home: String, runner: CommandRunner, tools: ToolLocating, probe: FileSystemProbe,
                processes: ProcessListing, settings: ScanSettings, now: Date) {
        self.home = home; self.runner = runner; self.tools = tools; self.probe = probe
        self.processes = processes; self.settings = settings; self.now = now
    }

    public static func live(settings: ScanSettings = .defaults()) -> DetectionContext {
        DetectionContext(home: NSHomeDirectory(), runner: ProcessCommandRunner(), tools: ToolLocator(),
                         probe: RealFileSystemProbe(), processes: SystemProcessListing(), settings: settings, now: Date())
    }

    public func expand(_ pattern: String) -> [String] { PathPattern.expand(pattern, home: home, probe: probe) }
}

public struct DetectorOutput: Sendable {
    public var items: [Item] = []
    public var warnings: [String] = []
    public init(items: [Item] = [], warnings: [String] = []) { self.items = items; self.warnings = warnings }
}

public protocol Detector: Sendable {
    func detect(rule: Rule, context: DetectionContext) async -> DetectorOutput
}

public enum DetectorRegistry {
    public static func detector(for kind: RuleKind) -> Detector {
        switch kind {
        case .pathCache, .texlive: PathDetector()
        case .conda: CondaDetector()
        case .simRuntimes: SimRuntimeDetector()
        case .vms: VMDetector()
        case .llmModels: LLMModelsDetector()
        case .largeFiles: LargeFilesDetector()
        case .installers: InstallersDetector()
        case .xcodeOldDerivedData: DeviceSupportDetector()
        case .sensitiveData: SensitiveDataDetector()
        case .leftovers: LeftoversDetector()
        case .toolCache: ToolCacheDetector()
        case .libraryCaches: LibraryCachesDetector()
        case .vscodeExtensions: EditorExtensionsDetector()
        case .docker: DockerDetector()
        case .protectedPaths: ProtectedDetector()
        case .projectArtifacts: ProjectArtifactsDetector()
        case .gitWorktrees: GitWorktreeDetector()
        }
    }
}

struct EmptyDetector: Detector {
    func detect(rule: Rule, context: DetectionContext) async -> DetectorOutput { DetectorOutput() }
}

// MARK: - Shared item construction

enum ItemFactory {
    /// Reason the item can't be acted on right now (a required-quiet process is running), if any.
    static func blocker(_ rule: Rule, _ ctx: DetectionContext) -> String? {
        for pattern in rule.requiresAppQuit ?? [] where !ctx.processes.matching(pattern).isEmpty {
            return "Quit \(appName(fromPattern: pattern)) first"
        }
        for pattern in rule.requiresNoProcess ?? [] {
            if let p = ctx.processes.matching(pattern).first {
                return "\(p.command) is running (pid \(p.pid)); try again when it finishes"
            }
        }
        return nil
    }

    static func appName(fromPattern p: String) -> String {
        if let r = p.range(of: ".app") { return String(p[..<r.lowerBound]).replacingOccurrences(of: "\\", with: "") }
        return p
    }

    static func action(for rule: Rule, path: String, toolPath: String?, ctx: DetectionContext) -> ItemAction {
        if let b = blocker(rule, ctx) { return .none(reason: b) }
        switch rule.action.type {
        case "tool":
            guard let toolPath, let args = rule.action.command else { return .none(reason: "\(rule.tool ?? "tool") isn't installed") }
            return .toolCommand(executable: toolPath, arguments: args)
        case "hardDelete": return ctx.probe.isDeletable(path) ? .hardDelete : .revealInFinder
        case "trash": return ctx.probe.isDeletable(path) ? .trash : .revealInFinder
        case "reveal": return .revealInFinder
        default: return .none(reason: rule.explanation)
        }
    }

    static func make(rule: Rule, path: String, title: String? = nil, size: SizeResult, action: ItemAction,
                     evidence: [String] = [], tier: Tier? = nil, lastUsed: Date? = nil, key: String? = nil,
                     sensitive: Bool = false, defaultSelected: Bool? = nil) -> Item {
        var ev = evidence
        if size.dataless > 0 { ev.append("\(size.dataless) cloud placeholder file(s) take no local space") }
        if size.inaccessible > 0 { ev.append("\(size.inaccessible) folder(s) couldn't be read") }
        if case let .none(reason) = action { ev.append(reason) }
        if !action.isActionable, case .revealInFinder = action { ev.append("Owned by an administrator: remove it in Finder") }
        return Item(
            id: Item.makeID(category: rule.id, key: key ?? path), category: rule.id, title: title ?? rule.title,
            path: path, logicalBytes: size.logical, physicalBytes: size.physical, lastModified: size.newestMTime,
            lastUsedSignal: lastUsed, tier: tier ?? rule.tier, action: action, rebuildCost: rule.rebuildCost,
            rebuildHint: rule.rebuildHint, evidence: ev, routine: rule.isRoutine,
            defaultSelected: defaultSelected ?? rule.selectedByDefault, sensitive: sensitive)
    }
}

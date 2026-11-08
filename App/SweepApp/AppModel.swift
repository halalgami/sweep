import AppKit
import Foundation
import Observation
import SweepCore
import UserNotifications

enum Screen: Equatable { case dashboard, plan, execute, verify }

@MainActor
@Observable
final class AppModel {
    // Scan
    var report: ScanReport?
    var scanning = false
    var scanPhase = ""
    var scanStartedAt: Date?
    var warnings: [String] = []
    var measuringFolders = false
    private var scanner: SweepScanner?
    private var folderCancel = CancelBox()

    // Navigation + plan/execute/verify
    var screen: Screen = .dashboard
    var plan: Plan?
    var planRoutineOnly = false
    var executing = false
    var executionLog: [String] = []
    var results: [ItemResult] = []
    var currentItem: Item?
    var volumeBefore: VolumeSummary?
    var verification: Verification?
    var recheckAt: Date?
    var mascotHop = 0
    var selectedItem: Item?
    var settingsTab = "general"

    // History
    let history: HistoryStore?
    var decisions: [String: Decision] = [:]
    var growthRates: [String: Double] = [:]
    var freeSeries: [SeriesPoint] = []
    var lastRun: RunRecord?

    // Preferences
    var settings: ScanSettings { didSet { SettingsStore.save(settings) } }
    var flavor: Flavor { didSet { prefs.set(flavor.rawValue, forKey: "flavor") } }
    var balloonHelp: Bool { didSet { prefs.set(balloonHelp, forKey: "balloonHelp") } }
    var lowSpacePercent: Double { didSet { prefs.set(lowSpacePercent, forKey: "lowSpacePercent") } }

    // Insights
    var insightsEnabled: Bool { didSet { prefs.set(insightsEnabled, forKey: "insightsEnabled") } }
    var insightsProvider: InsightsProviderKind { didSet { prefs.set(insightsProvider.rawValue, forKey: "insightsProvider") } }
    var claudeModel: String { didSet { prefs.set(claudeModel, forKey: "claudeModel") } }
    var claudeCodeModel: String { didSet { prefs.set(claudeCodeModel, forKey: "claudeCodeModel") } }
    var ollamaModel: String { didSet { prefs.set(ollamaModel, forKey: "ollamaModel") } }
    /// Read from the Keychain once and after each change, not on every redraw.
    private(set) var hasClaudeKey = false
    var claudeCodePath: String?
    var ollamaModels: [String] = []
    var providerStatus: String?
    var payloadViewed: Bool { didSet { prefs.set(payloadViewed, forKey: "payloadViewed") } }
    var insights: InsightsResponse?
    var insightsError: String?
    var insightsLoading = false

    // Maintenance
    let consent = ConsentStore()
    var rules = RuleSet.loadOrBundled()
    var scheduleInstalled = LaunchAgentManager().isInstalled
    var maintenanceMessage: String?

    private let prefs = AppModel.isDemo ? (UserDefaults(suiteName: "dev.algamthe.sweep.demo") ?? .standard) : SettingsStore.defaults

    #if DEBUG
    static var isDemo: Bool { ProcessInfo.processInfo.environment["SWEEP_DEMO"] != nil }
    #else
    static let isDemo = false
    #endif
    let home = NSHomeDirectory()

    init() {
        history = AppModel.isDemo ? nil : try? HistoryStore()   // the demo never reads or writes your history
        settings = SettingsStore.load()
        flavor = Flavor(rawValue: prefs.string(forKey: "flavor") ?? "") ?? .blueberry
        balloonHelp = prefs.bool(forKey: "balloonHelp")
        lowSpacePercent = prefs.object(forKey: "lowSpacePercent") as? Double ?? 10
        insightsEnabled = prefs.bool(forKey: "insightsEnabled")
        insightsProvider = InsightsProviderKind(rawValue: prefs.string(forKey: "insightsProvider") ?? "") ?? .default
        claudeModel = prefs.string(forKey: "claudeModel") ?? AnthropicProvider.defaultModel
        claudeCodeModel = prefs.string(forKey: "claudeCodeModel") ?? ClaudeCodeProvider.defaultModel
        hasClaudeKey = Keychain.load(account: "anthropic") != nil
        claudeCodePath = ClaudeCodeProvider.locate()
        ollamaModel = prefs.string(forKey: "ollamaModel") ?? "llama3.1:8b"
        payloadViewed = prefs.bool(forKey: "payloadViewed")
        refreshHistory()
    }

    // MARK: Derived

    var volume: VolumeSummary { report?.volume ?? VolumeAccounting.summary() }
    var freeFraction: Double { volume.totalBytes > 0 ? Double(volume.freeBytes) / Double(volume.totalBytes) : 1 }
    var safeItems: [Item] { activeItems.filter { $0.tier == .safe && $0.action.isActionable } }
    var reclaimableNow: Int64 { safeItems.filter(\.defaultSelected).reduce(0) { $0 + $1.physicalBytes } }
    var decisionItems: [Item] { activeItems.filter { $0.tier == .needsDecision || $0.tier == .idleArtifact } }
    var protectedItems: [Item] { report?.items.filter { $0.tier == .protected } ?? [] }
    var activeItems: [Item] {
        (report?.items ?? []).filter { item in decisions[item.id].map { !$0.isActive(at: Date()) } ?? true }
    }
    var mascotMood: MascotMood {
        if scanning || executing { return .working }
        return MascotView.mood(freeFraction: freeFraction, hasWork: reclaimableNow > 500_000_000)
    }
    var routineManifest: RoutineManifest { RoutineManifest.current(rules: rules) }
    var routineConsented: Bool { consent.isValid(for: routineManifest) }
    var routineRules: [Rule] { routineManifest.rules(in: rules) }
    var routineEstimate: Int64 {
        let ids = Set(routineManifest.ruleIDs)
        return (report?.items ?? []).filter { ids.contains($0.category) && $0.action.isActionable }.reduce(0) { $0 + $1.physicalBytes }
    }
    var context: DetectionContext { .live(settings: settings) }

    var bubbleText: String {
        if scanning { return "Sniffing around… \(scanPhase)" }
        guard report != nil else { return "Hi! Press Scan and I'll find where your space went." }
        if freeFraction < 0.05 { return "Eek, under 5% free. Let's sweep!" }
        if reclaimableNow > 1_000_000_000 { return "Found \(ByteFormat.string(reclaimableNow)) of crumbs. Sweep?" }
        return "Looking tidy. Nothing big to sweep."
    }

    // MARK: Scan

    func scan() {
        guard !scanning else { return }
        #if DEBUG
        if AppModel.isDemo { DemoTour.load(into: self); return }
        #endif
        scanning = true
        scanStopped = false
        scanStartedAt = Date()
        warnings = []
        rules = RuleSet.loadOrBundled()
        // Phase 1: findings (fast). Phase 2: folder sizes for the treemap, in the background.
        let s = SweepScanner(context: context, rules: rules, includeBuckets: false)
        scanner = s
        Task {
            for await event in s.scan() {
                switch event {
                case let .phase(p): scanPhase = p
                case let .warning(w): if !warnings.contains(w) { warnings.append(w) }
                case let .finished(r):
                    // A stopped scan has truncated sizes: never record it or let it replace a complete one.
                    if scanStopped {
                        if let previous = report {
                            warnings = previous.warnings + ["The scan was stopped. These are the results of the previous scan."]
                        } else {
                            report = r
                            warnings = r.warnings + ["The scan was stopped, so these results are incomplete. Scan again for the full picture."]
                        }
                        continue
                    }
                    let previous = (try? history?.previousSizes()) ?? [:]
                    report = r
                    warnings = r.warnings
                    try? history?.record(r)
                    refreshHistory()
                    checkAlerts(report: r, previous: previous)
                    measureFolders()
                case .item: break
                }
            }
            scanning = false
            scanPhase = ""
        }
    }

    private var scanStopped = false

    func cancelScan() { scanStopped = true; scanner?.cancel(); folderCancel.cancel() }

    func measureFolders() {
        guard !measuringFolders else { return }
        measuringFolders = true
        folderCancel = CancelBox()
        let cancel = folderCancel
        let accounting = VolumeAccounting(runner: ProcessCommandRunner(), probe: RealFileSystemProbe(), home: home)
        Task {
            let buckets = await Task.detached(priority: .utility) {
                accounting.buckets(progress: { _ in }, shouldCancel: { cancel.isCancelled })
            }.value
            if !cancel.isCancelled, var r = report {
                r.buckets = buckets
                let dataUsed = r.apfs.first { $0.role == "Data" }?.usedBytes ?? r.volume.usedBytes
                r.unaccountedBytes = VolumeAccounting.unaccounted(used: dataUsed, buckets: buckets)
                report = r
            }
            measuringFolders = false
        }
    }

    func refreshHistory() {
        decisions = (try? history?.decisions()) ?? [:]
        growthRates = (try? history?.growthRates(since: Date().addingTimeInterval(-30 * 86400))) ?? [:]
        freeSeries = (try? history?.freeSeries(since: Date().addingTimeInterval(-30 * 86400))) ?? []
        lastRun = (try? history?.recentRuns(limit: 1))?.first
    }

    var daysToFull: Double? { Growth.daysToFull(freeSeries: freeSeries) }

    func series(for item: Item) -> [SeriesPoint] {
        (try? history?.series(itemID: item.id, since: Date().addingTimeInterval(-60 * 86400))) ?? []
    }

    // MARK: Decisions

    func keep(_ item: Item, days: Int = 90) {
        try? history?.setDecision(.keep(item.id, days: days))
        plan = plan?.removing(itemID: item.id)   // a decision made from inside an open plan applies immediately
        refreshHistory()
    }
    func neverAsk(_ item: Item) {
        try? history?.setDecision(.neverAsk(item.id))
        plan = plan?.removing(itemID: item.id)
        refreshHistory()
    }
    func forget(_ item: Item) { try? history?.clearDecision(item.id); refreshHistory() }

    // MARK: Plan → Execute → Verify

    func openPlan(routineOnly: Bool = false) {
        guard let report else { return }
        planRoutineOnly = routineOnly
        plan = Plan.build(from: report, routineOnly: routineOnly, decisions: decisions)
        screen = .plan
    }

    func setSelected(_ id: String, _ on: Bool) {
        guard let i = plan?.entries.firstIndex(where: { $0.id == id }) else { return }
        plan?.entries[i].selected = on
    }

    func setTierSelected(_ tier: Tier, _ on: Bool) {
        guard var p = plan else { return }
        for i in p.entries.indices where p.entries[i].item.tier == tier { p.entries[i].selected = on }
        plan = p
    }

    func execute() {
        guard let plan, !executing else { return }
        executing = true
        results = []
        executionLog = ["Dry run confirmed. Starting \(plan.selected.count) item(s)…"]
        volumeBefore = VolumeAccounting.summary()
        screen = .execute
        let ctx = context
        let guardian = SafetyGuard(context: ctx, rules: rules, protected: ProtectedLocations(home: home, userProtected: settings.protectedPaths))
        let executor = Executor(guardian: guardian, context: ctx)
        let routine = planRoutineOnly
        Task {
            for await e in executor.execute(plan) {
                switch e {
                case let .started(item): currentItem = item; executionLog.append("• \(item.title)")
                case let .log(line): executionLog.append(line.replacingOccurrences(of: home, with: "~"))
                case let .finished(r): results.append(r); executionLog.append("  \(r.status.label): \(r.message)")
                }
            }
            try? history?.recordRun(results, at: Date(), routine: routine)
            currentItem = nil
            executing = false
            verify()
            screen = .verify
            mascotHop += 1
        }
    }

    func verify() {
        guard let before = volumeBefore else { return }
        verification = Verifier.verification(before: before, after: VolumeAccounting.summary(), results: results)
        // APFS often frees space a little later: always measure once more after 60 seconds.
        recheckAt = Date().addingTimeInterval(60)
        Task {
            try? await Task.sleep(for: Verifier.recheckDelay)
            if let b = volumeBefore { verification = Verifier.verification(before: b, after: VolumeAccounting.summary(), results: results) }
            recheckAt = nil
        }
    }

    func finishRun() {
        screen = .dashboard
        plan = nil
        scan()
    }

    // MARK: Finder helpers

    func reveal(_ path: String) {
        guard path.hasPrefix("/") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func emptyTrash() {
        Task {
            let r = await ProcessCommandRunner().run("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"], timeout: 120)
            executionLog.append(r.ok ? "Trash emptied." : "Couldn't empty the Trash: \(r.stderr)")
            verify()
        }
    }

    func openFullDiskAccessSettings() { NSWorkspace.shared.open(VolumeAccounting.fullDiskAccessSettingsURL) }

    // MARK: Insights

    var summary: InsightsSummary? {
        guard let report else { return nil }
        return InsightsSummary.build(report: report, growth: growthRates, declines: (try? history?.declineCounts()) ?? [:],
                                     redactor: Redactor(settings: settings, home: home))
    }

    func saveClaudeKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: "anthropic") } else { try? Keychain.save(trimmed, account: "anthropic") }
        hasClaudeKey = Keychain.load(account: "anthropic") != nil
    }

    /// One line describing the chosen provider, for the payload sheet and the panel.
    var providerDescription: String {
        switch insightsProvider {
        case .claudeCode: "Claude Code (\(claudeCodeModel)), signed in with your Claude account. Sent to Anthropic."
        case .ollama: ollamaModel.contains("-cloud")
            ? "Ollama (\(ollamaModel)). This is a cloud model: the summary goes to Ollama's servers."
            : "Ollama on this Mac (\(ollamaModel)). Nothing leaves your Mac."
        case .anthropicAPI: "Anthropic API (\(claudeModel)) with your API key. Sent to Anthropic."
        }
    }

    /// Re-detects Claude Code and lists Ollama's installed models.
    func refreshProviders() {
        claudeCodePath = ClaudeCodeProvider.locate()
        providerStatus = nil
        Task {
            do {
                ollamaModels = try await OllamaProvider.installedModels()
                if insightsProvider == .ollama, !ollamaModels.contains(ollamaModel), let first = ollamaModels.first { ollamaModel = first }
            } catch {
                ollamaModels = []
                if insightsProvider == .ollama { providerStatus = (error as? InsightsError)?.description ?? "\(error)" }
            }
        }
    }

    func runInsights() {
        guard insightsEnabled, payloadViewed, let summary, !insightsLoading else { return }
        let provider: InsightsProvider
        switch insightsProvider {
        case .claudeCode:
            guard let exe = claudeCodePath ?? ClaudeCodeProvider.locate() else { insightsError = InsightsError.claudeCodeMissing.description; return }
            provider = ClaudeCodeProvider(executable: exe, model: claudeCodeModel)
        case .anthropicAPI:
            guard let key = Keychain.load(account: "anthropic") else { insightsError = InsightsError.notConfigured.description; return }
            provider = AnthropicProvider(apiKey: key, model: claudeModel)
        case .ollama:
            provider = OllamaProvider(model: ollamaModel)
        }
        insightsLoading = true
        insightsError = nil
        Task {
            switch await InsightsService.run(summary: summary, provider: provider) {
            case let .success(r): insights = r
            case let .failure(e): insightsError = e.description
            }
            insightsLoading = false
        }
    }

    func item(id: String) -> Item? { report?.items.first { $0.id == id } }

    // MARK: Maintenance

    func acknowledgeRoutine() { consent.acknowledge(routineManifest) }

    func revokeRoutine() {
        consent.revoke()
        if scheduleInstalled { setSchedule(false) }
    }

    var agentPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SweepAgent").path }

    func setSchedule(_ on: Bool) {
        let mgr = LaunchAgentManager()
        Task {
            do {
                if on {
                    guard routineConsented else { maintenanceMessage = "Approve the routine list first."; return }
                    try await mgr.install(agentPath: agentPath)
                    maintenanceMessage = "Weekly routine sweep scheduled for Sundays at 10:00."
                } else {
                    try await mgr.uninstall()
                    maintenanceMessage = "Weekly routine sweep turned off."
                }
            } catch { maintenanceMessage = "Couldn't change the schedule: \(error)" }
            scheduleInstalled = mgr.isInstalled
        }
    }

    func runRoutineNow() {
        guard routineConsented, !executing else { return }
        executing = true
        maintenanceMessage = "Running routine sweep…"
        let runner = MaintenanceRunner(context: context, rules: rules, consent: consent, history: history, notifier: OSAScriptNotifier())
        Task {
            switch await runner.runRoutine() {
            case let .refused(reason): maintenanceMessage = reason
            case let .ran(results):
                let done = results.filter { $0.status == .removed || $0.status == .partial }
                maintenanceMessage = "Routine sweep finished: \(done.count) cleaned, \(results.count - done.count) skipped."
            }
            executing = false
            mascotHop += 1
            refreshHistory()
            scan()
        }
    }

    // MARK: Alerts

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func checkAlerts(report: ScanReport, previous: [String: Int64]) {
        var bodies: [String] = []
        let freePct = report.volume.totalBytes > 0 ? Double(report.volume.freeBytes) / Double(report.volume.totalBytes) * 100 : 100
        if freePct < lowSpacePercent {
            bodies.append("Only \(ByteFormat.string(report.volume.freeBytes)) free (\(Int(freePct))%).")
        }
        for item in report.items {
            if let before = previous[item.id], item.physicalBytes - before > 5_000_000_000 {
                bodies.append("\(item.title) grew \(ByteFormat.string(item.physicalBytes - before)) since the last scan.")
            }
        }
        guard !bodies.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "Sweep"
        content.body = bodies.prefix(3).joined(separator: " ")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.withLock { flag = true } }
    var isCancelled: Bool { lock.withLock { flag } }
}

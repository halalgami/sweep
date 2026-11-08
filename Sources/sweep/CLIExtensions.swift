import Foundation
import SweepCore

enum CLIExtensions {
    static func handle(command: String, args: inout Arguments) async -> Bool {
        switch command {
        case "plan":
            let routine = args.flag("--routine"), json = args.flag("--json")
            guard let report = await SweepCLI.collect(SweepCLI.scanner(buckets: false, routineOnly: routine), quiet: json) else { exit(1) }
            let decisions = (try? HistoryStore().decisions()) ?? [:]
            let plan = Plan.build(from: report, routineOnly: routine, decisions: decisions)
            if json {
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: (try? e.encode(plan)) ?? Data(), as: UTF8.self))
            } else {
                print("DRY RUN: nothing is changed.\n")
                for e in plan.entries {
                    print("[\(e.selected ? "x" : " ")] T\(e.item.tier.rawValue) \(ByteFormat.string(e.item.physicalBytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(e.item.title)")
                    print("      \(e.commandPreview)  (rebuild: \(e.item.rebuildCost.rawValue))")
                }
                print("\nWould free about \(ByteFormat.string(plan.expectedFreedBytes)); \(ByteFormat.string(plan.toTrashBytes)) would go to the Trash.")
            }
            return true
        case "insights":
            // sweep insights [--payload] [--provider claude-code|ollama|anthropic] [--model NAME]
            let payloadOnly = args.flag("--payload")
            var kind = InsightsProviderKind.default
            var model: String?
            while let a = args.next() {
                switch a {
                case "--provider":
                    guard let v = args.next(), let k = InsightsProviderKind(cliName: v) else { eprint("--provider takes claude-code, ollama or anthropic"); exit(64) }
                    kind = k
                case "--model": model = args.next()
                default: eprint("unknown option \(a)"); exit(64)
                }
            }
            guard let report = await SweepCLI.collect(SweepCLI.scanner(buckets: false), quiet: true) else { exit(1) }
            let history = try? HistoryStore()
            let settings = SettingsStore.load()
            let summary = InsightsSummary.build(report: report, growth: (try? history?.growthRates(since: Date().addingTimeInterval(-30 * 86400))) ?? [:],
                                                declines: (try? history?.declineCounts()) ?? [:], redactor: Redactor(settings: settings))
            if payloadOnly { print(summary.json()); return true }
            let provider: InsightsProvider
            switch kind {
            case .claudeCode:
                guard let exe = ClaudeCodeProvider.locate() else { eprint(InsightsError.claudeCodeMissing.description); exit(1) }
                provider = ClaudeCodeProvider(executable: exe, model: model ?? ClaudeCodeProvider.defaultModel)
            case .ollama:
                provider = OllamaProvider(model: model ?? "llama3.1:8b")
            case .anthropicAPI:
                guard let key = Keychain.load(account: "anthropic") ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
                    eprint(InsightsError.notConfigured.description); exit(1)
                }
                provider = AnthropicProvider(apiKey: key, model: model ?? AnthropicProvider.defaultModel)
            }
            eprint("… asking \(kind.title) about \(summary.items.count) items (redacted)")
            switch await InsightsService.run(summary: summary, provider: provider) {
            case let .success(r):
                let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: (try? e.encode(r)) ?? Data(), as: UTF8.self))
            case let .failure(e): eprint(e.description); exit(1)
            }
            return true
        case "run":
            guard args.flag("--routine"), args.flag("--yes") else {
                eprint("Only `sweep run --routine --yes` is supported from the CLI. Use the app for everything else.")
                exit(64)
            }
            let runner = MaintenanceRunner(context: .live(settings: SettingsStore.load()), rules: RuleSet.loadOrBundled(),
                                           consent: ConsentStore(), history: try? HistoryStore(), notifier: OSAScriptNotifier())
            switch await runner.runRoutine() {
            case let .refused(reason): eprint(reason); exit(3)
            case let .ran(results): for r in results { print("\(r.status.label): \(r.title) — \(r.message)") }
            }
            return true
        default: return false
        }
    }
}

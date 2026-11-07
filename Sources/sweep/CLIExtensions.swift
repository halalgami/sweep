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

import Foundation
import SweepCore

/// Launched weekly by launchd. Runs only the routine subset the user approved; otherwise exits 3.
@main
struct SweepAgentMain {
    static func main() async {
        let runner = MaintenanceRunner(context: .live(settings: SettingsStore.load()), rules: RuleSet.loadOrBundled(),
                                       consent: ConsentStore(), history: try? HistoryStore(), notifier: OSAScriptNotifier())
        switch await runner.runRoutine() {
        case let .refused(reason):
            print("Refused: \(reason)")
            exit(3)
        case let .ran(results):
            for r in results { print("\(r.status.rawValue)\t\(r.title)\t\(r.message)") }
        }
    }
}

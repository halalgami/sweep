import Foundation
import SweepCore

// Launched weekly by launchd. Runs only the routine subset the user approved; otherwise exits 3.
let rules = RuleSet.loadOrBundled()
let history = try? HistoryStore()
let runner = MaintenanceRunner(context: .live(settings: SettingsStore.load()), rules: rules, consent: ConsentStore(),
                               history: history, notifier: OSAScriptNotifier())
let sem = DispatchSemaphore(value: 0)
final class Code: @unchecked Sendable { var value: Int32 = 0 }
let code = Code()
Task {
    switch await runner.runRoutine() {
    case let .refused(reason): print("Refused: \(reason)"); code.value = 3
    case let .ran(results):
        for r in results { print("\(r.status.rawValue)\t\(r.title)\t\(r.message)") }
    }
    sem.signal()
}
sem.wait()
exit(code.value)

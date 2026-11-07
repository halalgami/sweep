import Foundation
import SweepCore

/// `sweep` — developer CLI for SweepCore. Read-only except `sweep run --routine --yes`.
@main
struct SweepCLI {
    static let usage = """
    usage:
      sweep scan [--json] [--no-buckets]       Scan and print findings (read-only)
      sweep plan [--routine] [--json]          Show what a sweep would do (dry run)
      sweep run --routine --yes                Run the routine sweep (requires consent given in the app)
      sweep rules --validate <file>            Check a rules override file
    """

    static func main() async {
        var args = Arguments(Array(CommandLine.arguments.dropFirst()))
        guard let command = args.next() else { print(usage); exit(64) }
        switch command {
        case "scan": await scan(&args)
        case "rules": rules(&args)
        default:
            if await !CLIExtensions.handle(command: command, args: &args) { print(usage); exit(64) }
        }
    }

    static func scanner(buckets: Bool, routineOnly: Bool = false) -> SweepScanner {
        var rules = RuleSet.loadOrBundled()
        if routineOnly { rules.rules = rules.rules.filter(\.isRoutine) }
        return SweepScanner(context: .live(settings: SettingsStore.load()), rules: rules, includeBuckets: buckets)
    }

    static func collect(_ scanner: SweepScanner, quiet: Bool) async -> ScanReport? {
        var report: ScanReport?
        for await event in scanner.scan() {
            switch event {
            case let .phase(p): if !quiet { eprint("… \(p)") }
            case let .warning(w): if !quiet { eprint("! \(w)") }
            case let .finished(r): report = r
            case .item: break
            }
        }
        return report
    }

    static func scan(_ args: inout Arguments) async {
        let json = args.flag("--json"), noBuckets = args.flag("--no-buckets")
        guard let report = await collect(scanner(buckets: !noBuckets), quiet: json) else { exit(1) }
        if json {
            print(String(decoding: (try? ScanReport.jsonEncoder.encode(report)) ?? Data(), as: UTF8.self))
            return
        }
        print("Free: \(ByteFormat.string(report.volume.freeBytes)) of \(ByteFormat.string(report.volume.totalBytes))")
        for tier in Tier.allCases {
            let items = report.items.filter { $0.tier == tier }
            guard !items.isEmpty else { continue }
            print("\n\(tier.label): \(ByteFormat.string(report.tierTotal(tier)))")
            for i in items.prefix(25) {
                print("  \(ByteFormat.string(i.physicalBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(i.title)")
            }
        }
        if !report.fullDiskAccess {
            print("\nUnaccounted: \(ByteFormat.string(report.unaccountedBytes)). Grant Full Disk Access to measure Mail, Messages and Safari.")
        }
    }

    static func rules(_ args: inout Arguments) {
        guard args.flag("--validate"), let file = args.next(), let data = FileManager.default.contents(atPath: file) else {
            print(usage); exit(64)
        }
        do {
            let set = try RuleSet.load(bundled: try RuleSet.bundledData(), override: data)
            print("OK: \(set.rules.count) rules after merging \(file)")
        } catch { eprint("\(error)"); exit(1) }
    }
}

struct Arguments {
    var items: [String]
    init(_ items: [String]) { self.items = items }
    mutating func next() -> String? { items.isEmpty ? nil : items.removeFirst() }
    mutating func flag(_ name: String) -> Bool {
        if let i = items.firstIndex(of: name) { items.remove(at: i); return true }
        return false
    }
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

#if DEBUG
import Foundation
import SweepCore

/// Debug-only made-up scan used for README screenshots (`SWEEP_DEMO=1`), so no real folder names are published.
enum DemoData {
    static let gb: Int64 = 1_000_000_000
    static let mb: Int64 = 1_000_000

    static func item(_ category: String, _ title: String, _ path: String, _ bytes: Int64, tier: Tier, action: ItemAction,
                     cost: RebuildCost = .low, hint: String? = nil, evidence: [String] = [], routine: Bool = false,
                     selected: Bool = true, daysIdle: Int? = nil) -> Item {
        let used = daysIdle.map { Date().addingTimeInterval(-Double($0) * 86400) }
        return Item(id: Item.makeID(category: category, key: path), category: category, title: title, path: path,
                    logicalBytes: bytes, physicalBytes: bytes, lastModified: used, lastUsedSignal: used, tier: tier, action: action,
                    rebuildCost: cost, rebuildHint: hint, evidence: evidence, routine: routine, defaultSelected: selected, sensitive: false)
    }

    static func items(home h: String) -> [Item] {
        let tool = { (exe: String, args: [String]) in ItemAction.toolCommand(executable: exe, arguments: args) }
        return [
            item("cache.xcode-deriveddata", "Xcode DerivedData", "\(h)/Library/Developer/Xcode/DerivedData", 18_400 * mb, tier: .safe,
                 action: .hardDelete, hint: "Xcode rebuilds it on the next build", evidence: ["Build intermediates for 23 projects"], routine: true),
            item("cache.uv", "uv cache", "\(h)/.cache/uv", 6_200 * mb, tier: .safe, action: tool("/opt/homebrew/bin/uv", ["cache", "prune"]),
                 hint: "uv re-downloads packages when needed", evidence: ["Grew 1.1 GB in the last week"], routine: true),
            item("docker.builder", "Docker build cache (colima)", "docker://builder/colima", 5_300 * mb, tier: .safe,
                 action: .dockerCommand(arguments: ["buildx", "prune", "-f", "--builder", "colima"]), hint: "Next image build is slower", routine: true),
            item("cache.gradle", "Gradle caches", "\(h)/.gradle/caches", 4_400 * mb, tier: .safe, action: .hardDelete, cost: .medium,
                 hint: "Gradle re-downloads dependencies on the next build"),
            item("cache.npm", "npm cache", "\(h)/.npm/_cacache", 3_100 * mb, tier: .safe, action: tool("/opt/homebrew/bin/npm", ["cache", "clean", "--force"]),
                 hint: "npm re-downloads packages when needed", routine: true),
            item("cache.brew", "Homebrew downloads", "\(h)/Library/Caches/Homebrew", 2_400 * mb, tier: .safe,
                 action: tool("/opt/homebrew/bin/brew", ["cleanup", "-s"]), hint: "Old bottles and downloads", routine: true),
            item("cache.pnpm", "pnpm store", "\(h)/Library/pnpm/store", 1_800 * mb, tier: .safe, action: tool("/opt/homebrew/bin/pnpm", ["store", "prune"]),
                 hint: "Only unreferenced packages are removed", routine: true),
            item("cache.dotcache.playwright", "Playwright browsers", "\(h)/Library/Caches/ms-playwright", 1_600 * mb, tier: .safe, action: .hardDelete,
                 cost: .medium, hint: "Re-downloaded by `npx playwright install`"),
            item("cache.go", "Go build cache", "\(h)/Library/Caches/go-build", 1_100 * mb, tier: .safe, action: tool("/opt/homebrew/bin/go", ["clean", "-cache"]),
                 hint: "Go rebuilds it on the next build", routine: true),
            item("cache.dotcache.huggingface", "Hugging Face models", "\(h)/.cache/huggingface", 7_900 * mb, tier: .safe, action: .hardDelete, cost: .high,
                 hint: "Big re-download (7.9 GB) the next time a model loads", selected: false),

            item("artifact.projects", "acme-web / node_modules", "\(h)/Developer/acme-web/node_modules", 1_900 * mb, tier: .idleArtifact,
                 action: .hardDelete, cost: .medium, hint: "`npm install` brings it back",
                 evidence: ["No commits or edits for 74 days", "No uncommitted changes", "No process running from this project"], daysIdle: 74),
            item("artifact.projects", "billing-api / .venv", "\(h)/Developer/billing-api/.venv", 820 * mb, tier: .idleArtifact,
                 action: .hardDelete, cost: .medium, hint: "`uv sync` brings it back", evidence: ["No commits or edits for 112 days"], daysIdle: 112),
            item("artifact.projects", "docs-site / .next", "\(h)/Developer/docs-site/.next", 640 * mb, tier: .idleArtifact,
                 action: .hardDelete, hint: "`next build` recreates it", evidence: ["No commits or edits for 61 days"], daysIdle: 61),
            item("git.worktrees", "acme-web-feature-login (worktree)", "\(h)/Developer/acme-web-feature-login", 1_200 * mb, tier: .idleArtifact,
                 action: .gitWorktreeRemove(repo: "\(h)/Developer/acme-web"), cost: .low, hint: "The branch is kept",
                 evidence: ["Branch merged and pushed", "No uncommitted changes"], daysIdle: 45),

            item("decision.vms", "Windows 11.utm", "\(h)/Library/Containers/com.utmapp.UTM/Data/Documents/Windows 11.utm", 38_000 * mb,
                 tier: .needsDecision, action: .trash, cost: .high, hint: "Goes to the Trash; restore it from there if you change your mind",
                 evidence: ["Last opened 143 days ago", "UTM isn't running"], selected: false, daysIdle: 143),
            item("decision.simruntimes", "iOS 17.5 Simulator runtime", "\(h)/Library/Developer/CoreSimulator/Volumes/iOS_21F79", 7_100 * mb,
                 tier: .needsDecision, action: tool("/usr/bin/xcrun", ["simctl", "runtime", "delete", "21F79"]), cost: .high,
                 hint: "Re-download from Xcode → Settings → Platforms", evidence: ["No simulator device uses it"], selected: false),
            item("decision.llm-models", "Ollama model llama3.1:8b", "\(h)/.ollama/models/manifests/registry.ollama.ai/library/llama3.1/8b", 4_900 * mb,
                 tier: .needsDecision, action: tool("/opt/homebrew/bin/ollama", ["rm", "llama3.1:8b"]), cost: .high,
                 hint: "`ollama pull llama3.1:8b` brings it back", evidence: ["Not used for 96 days"], selected: false, daysIdle: 96),
            item("decision.xcode-old-deriveddata", "iOS DeviceSupport 17.4", "\(h)/Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 17.4 (21E219)", 4_100 * mb,
                 tier: .needsDecision, action: .hardDelete, cost: .medium, hint: "Xcode copies it again when that device connects",
                 evidence: ["Newer versions kept: 18.1, 18.0"], selected: false),
            item("decision.installers", "Xcode_16.4.xip", "\(h)/Downloads/Xcode_16.4.xip", 3_000 * mb, tier: .needsDecision, action: .trash,
                 hint: "Installer you already used", evidence: ["Downloaded 88 days ago"], selected: false, daysIdle: 88),
            item("decision.large-files", "screen-recording-august.mov", "\(h)/Movies/screen-recording-august.mov", 2_200 * mb,
                 tier: .needsDecision, action: .trash, cost: .high, hint: "Can't be recreated", evidence: ["Not opened for 81 days"], selected: false, daysIdle: 81),

            item("protected.paths", "Chrome code-sign clone", "/private/var/folders/xx/X/com.google.Chrome.code_sign_clone", 900 * mb,
                 tier: .protected, action: .none(reason: "APFS clone: deleting it won't free space")),
            item("protected.paths", "iCloud Drive", "\(h)/Library/Mobile Documents", 12_400 * mb, tier: .protected,
                 action: .none(reason: "Cloud-synced folder; Sweep never touches it")),
        ]
    }

    static func report(home: String) -> ScanReport {
        let items = items(home: home)
        let total: Int64 = 494_384 * mb, free: Int64 = 41_200 * mb
        func b(_ p: String, _ gbs: Double, _ kids: [Bucket] = []) -> Bucket { Bucket(path: p, physicalBytes: Int64(gbs * 1e9), inaccessible: 0, children: kids) }
        let buckets = [
            b("\(home)/Library", 168, [b("\(home)/Library/Developer", 61), b("\(home)/Library/Containers", 44), b("\(home)/Library/Caches", 21),
                                       b("\(home)/Library/Application Support", 29), b("\(home)/Library/Mobile Documents", 12.4)]),
            b("\(home)/Developer", 64, [b("\(home)/Developer/acme-web", 9.2), b("\(home)/Developer/billing-api", 3.1), b("\(home)/Developer/docs-site", 2.4)]),
            b("/Applications", 38), b("\(home)/.cache", 22), b("\(home)/Downloads", 14), b("\(home)/Movies", 11), b("\(home)/Documents", 9),
            b("\(home)/.docker", 6.5), b("/opt/homebrew", 7.8), b("/Library", 18), b("/private/var", 24),
        ]
        let used = buckets.reduce(0) { $0 + $1.physicalBytes }
        return ScanReport(
            scannedAt: Date(), volume: VolumeSummary(totalBytes: total, availableBytes: free, importantAvailableBytes: free, usedBytes: total - free),
            apfs: [APFSVolumeInfo(name: "Macintosh HD - Data", role: "Data", usedBytes: used + 21 * gb, container: "disk3", isSimulator: false),
                   APFSVolumeInfo(name: "Macintosh HD", role: "System", usedBytes: 11 * gb, container: "disk3", isSimulator: false),
                   APFSVolumeInfo(name: "VM", role: "VM", usedBytes: 4 * gb, container: "disk3", isSimulator: false),
                   APFSVolumeInfo(name: "iOS 18.1 Simulator", role: "", usedBytes: 8 * gb, container: "disk5", isSimulator: true)],
            buckets: buckets, unaccountedBytes: 21 * gb, fullDiskAccess: false, snapshots: [], items: items,
            rootCauses: [RootCauseHint(id: "h1", kind: "latestResolver",
                                       detail: "MCP server \"fetch\" runs `uvx mcp-server-fetch@latest` (3 config files, e.g. ~/.claude.json). It re-resolves on every agent session and keeps growing the uv cache.",
                                       relatedCategory: "cache.uv")],
            warnings: ["Full Disk Access is off, so Mail, Messages and Safari couldn't be measured (shown as Unaccounted)."])
    }

    static func freeSeries() -> [SeriesPoint] {
        (0..<30).map { (d: Int) -> SeriesPoint in
            let day = Double(d)
            let bump: Double = d % 4 == 0 ? 2.5 : 0
            let gbFree: Double = 78.0 - day * 1.23 + bump
            return SeriesPoint(date: Date().addingTimeInterval(-(29 - day) * 86400), bytes: Int64(gbFree * 1e9))
        }
    }

    static func growth(_ items: [Item]) -> [String: Double] {
        var g: [String: Double] = [:]
        for i in items {
            switch i.category {
            case "cache.uv": g[i.id] = 160_000_000
            case "cache.xcode-deriveddata": g[i.id] = 420_000_000
            case "docker.builder": g[i.id] = 90_000_000
            default: break
            }
        }
        return g
    }

    static func insights(_ items: [Item]) -> InsightsResponse {
        func id(_ c: String) -> String { items.first { $0.category == c }!.id }
        return InsightsResponse(
            headline: "Build caches and one old VM hold most of what you can get back",
            insights: [
                .init(title: "Xcode DerivedData grows fastest",
                      detail: "It gained about 420 MB a day this month. It's safe to clear; the cost is one slower build per project.",
                      evidenceItemIds: [id("cache.xcode-deriveddata")]),
                .init(title: "Your uv cache keeps coming back",
                      detail: "An MCP server runs with `@latest`, so every agent session re-resolves it. Pinning the version slows the regrowth.",
                      evidenceItemIds: [id("cache.uv")]),
                .init(title: "The Windows VM is the biggest single item",
                      detail: "It hasn't been opened in about five months. If you still need it, keep it; otherwise the Trash is a safe first step.",
                      evidenceItemIds: [id("decision.vms")]),
            ],
            recommendations: [
                .init(itemIds: [id("cache.xcode-deriveddata"), id("cache.uv"), id("cache.npm")], action: "Run the safe sweep",
                      expectedBytes: 0, risk: "low", why: "All of these rebuild on their own"),
                .init(itemIds: [id("decision.vms")], action: "Decide on the Windows VM", expectedBytes: 0, risk: "medium",
                      why: "Large, unused for months, but can't be recreated"),
            ],
            maintenanceSuggestions: ["Turn on the weekly routine sweep", "Pin MCP servers to a version instead of @latest"],
            questionsForUser: ["Do you still use the iOS 17.5 simulator for testing?"])
    }

    static func verification(_ items: [Item]) -> ([ItemResult], Verification) {
        let safe = items.filter { $0.tier == .safe && $0.defaultSelected }
        var results = safe.map { i in
            let files = Int(i.physicalBytes / 1_100_000)
            return ItemResult(itemID: i.id, title: i.title, status: .removed, removedPaths: i.action == .hardDelete ? files : 1, protectedPaths: 0,
                              failedPaths: 0, message: i.action == .hardDelete ? "\(files) files removed" : "Done", expectedBytes: i.physicalBytes)
        }
        if let i = results.firstIndex(where: { $0.title == "Gradle caches" }) {
            results[i].status = .partial; results[i].protectedPaths = 3; results[i].message = "9120 removed, 3 protected by macOS"
            results[i].expectedBytes = 4_310 * mb
        }
        let expected = results.reduce(0) { $0 + $1.expectedBytes }
        return (results, Verification(expectedBytes: expected, trashedBytes: 0, freedNowBytes: expected - 600 * mb, lagLikely: false))
    }
}
#endif

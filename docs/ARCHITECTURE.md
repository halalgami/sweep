# Architecture

```
            ┌─────────────── Sweep.app (SwiftUI) ───────────────┐   ┌── sweep (CLI) ──┐   ┌── SweepAgent ──┐
            │ AppModel (@Observable, @MainActor)                │   │ scan/plan/run/  │   │ weekly routine │
            │ Views: Dashboard · Plan · Execute · Verify ·      │   │ rules/insights  │   │ sweep (needs   │
            │ ItemDetail · Insights · Settings · MenuBar        │   │                 │   │ consent)       │
            └────────────────────────┬──────────────────────────┘   └────────┬────────┘   └───────┬────────┘
                                     └──────────────┬────────────────────────┴────────────────────┘
                                              SweepCore (no UI)
```

Everything that matters lives in **SweepCore**, so the app, the CLI and the LaunchAgent behave the same way. The app adds presentation and state only.

## Flow

```
rules.json (+ user override)
      │
      ▼
SweepScanner ──► Detectors (one per RuleKind) ──► [Item]
      │               │ use DetectionContext: home, CommandRunner, ToolLocating,
      │               │ FileSystemProbe, ProcessListing, ScanSettings, now
      │               ▼
      │          consolidate(): one item per path; the earlier rule wins; "sensitive" survives merges;
      │          protected locations become tier 4
      ▼
ScanReport ─────► VolumeAccounting (free space, APFS volumes, folder buckets, unaccounted)
      │           RootCauseAnalyzer (why caches regrow)
      │           HistoryStore.record (sizes per scan → growth rates)
      ▼
Plan.build (dry run; selection rules per tier; decisions hide items)
      ▼
Executor.execute ──► for each selected item: SafetyGuard.check (again, now) ──► action ──► ItemResult
      ▼
Verifier (expected vs. actual free space; re-measured after 60 s)
```

### Items

`Item` is the unit everything shares. It has:

- a stable `id` (SHA256 of category and path);
- `tier`, `action` (`ItemAction`), `physicalBytes`, `rebuildCost`;
- `evidence` (the "why Sweep thinks this" lines);
- the `routine`, `defaultSelected` and `sensitive` flags.

Detectors create items with `ItemFactory.make`, which applies the rule's defaults and any process blockers.

### Tiers

| Tier | Name | Selection in the plan |
|---|---|---|
| 1 | Safe to sweep | Batch, pre-selected unless `rebuildCost == .high` |
| 2 | Idle build artifacts | One at a time, never pre-selected |
| 3 | Needs your decision | One at a time, never pre-selected; mostly Trash |
| 4 | Protected | Display only; `SafetyGuard` refuses them |

## Size accounting

`SizeCalculator` walks with `FileSystemProbe.entries()`, which uses `getattrlistbulk` to read a whole directory in one system call.

- It counts allocated blocks.
- Each `(dev, ino)` is counted once, so hard links aren't double counted.
- Dataless (cloud placeholder) files count as 0, and SIP-restricted files are noted.
- It never crosses into another device.

`VolumeAccounting.buckets` measures the top-level folders in parallel (`DispatchQueue.concurrentPerform`). The app runs it as a second phase after findings are shown. "Unaccounted" is the APFS Data volume's used bytes minus what the buckets could measure. Without Full Disk Access that's mostly Mail, Messages and Safari.

## Processes and tools

- `CommandRunner` / `ProcessCommandRunner` run executables through `Process` with argv and a timeout. There is no shell. Grandchildren that hold pipes open can't hang it, and GUI apps get a usable `PATH`.
- `ToolLocator` resolves tool names in known bin folders, never through a shell.
- `ProcessList` reads processes with sysctl: `KERN_PROCARGS2` for arguments, `proc_pidinfo` for the working directory, and `e_pgid` for the process group. Idle checks and orphan detection use it.

## Concurrency

- Swift 6 strict concurrency. Core types are `Sendable` structs.
- Blocking work never runs on the cooperative pool. That covers `deleteTree`, `concurrentPerform` measuring and process waits, which all use `DispatchQueue.global` behind a continuation.
- `AppModel` is `@MainActor @Observable`. Long work runs in `Task`s, and results are assigned back on the main actor.
- Cancelling uses `SweepScanner.cancel()` and a `CancelBox` that folder walks poll.

## Persistence

| What | Where | Code |
|---|---|---|
| Scan sizes, decisions, runs | `~/Library/Application Support/Sweep/history.db` (SQLite) | `HistoryStore`, `SQLite` |
| Settings | `dev.algamthe.sweep` defaults (`.standard` inside the app/agent, a suite from the CLI) | `SettingsStore` |
| Routine consent | Same defaults domain, a fingerprint of the routine rule ids and actions | `ConsentStore`, `RoutineManifest` |
| Anthropic API key | Keychain, service `dev.algamthe.sweep` | `Keychain` |
| Run logs | `~/Library/Logs/Sweep/` | `Executor.log`, LaunchAgent stdout |

## App structure

- `SweepApp.swift` holds the main `Window`, a `MenuBarExtra` (free GB and a routine sweep button) and `Settings`.
- `AppModel.swift` holds all state and actions: two-phase scan, plan/execute/verify, decisions, insights, maintenance and alerts.
- `Views/`:
  - `DashboardView` (hero, APFS bar, reclaimable, decisions, treemap, growth, insights, notes)
  - `RunViews` (plan, execute, verify)
  - `ItemDetailSheet`
  - `InsightsPanel` (with the payload sheet)
  - `SettingsView` (General, Scanning, Maintenance, Insights)
  - `MenuBarView`
- `Theme/` holds the Platinum and Graphite palettes, the fruit flavours, Gumdrop and Platinum button styles, grooved headers, balloon help and the pixel mascot drawn with `Canvas`.
- `DemoData.swift` and `DebugSnapshot.swift` are compiled in DEBUG only. They provide the demo data and the self-photographing screenshot tour.

## Build

- SwiftPM (`Package.swift`) builds SweepCore, `sweep`, `SweepAgent` and the tests. SQLite comes from the system `sqlite3` library.
- XcodeGen (`App/project.yml`) builds `Sweep.app` and embeds `SweepAgent` in `Contents/MacOS`.
- Signing comes from `App/Signing.xcconfig`: ad-hoc unless a git-ignored `App/Local.xcconfig` sets a team.
- The app uses the hardened runtime and no sandbox. Its only entitlement is `com.apple.security.automation.apple-events`, for Finder.

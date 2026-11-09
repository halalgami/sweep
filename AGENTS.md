# AGENTS.md: working on Sweep

This file is for anyone picking up the code, whether a person or a coding agent (Claude Code, Codex, Cursor…). Read it before changing anything. `CLAUDE.md` simply imports this file.

Sweep is a macOS app that finds and reclaims disk space on a developer's Mac. It **deletes user files**, so the safety rules below are hard requirements, not style preferences.

## 1. Commands

```bash
# Core library + CLI + tests (SwiftPM, Swift 6, macOS 14+, Apple Silicon)
swift build
swift test --parallel --num-workers 3          # keep workers at 3 or fewer: tests use real temp dirs and processes
swift test --filter SafetyGuardTests           # one suite
swift run sweep scan | plan | insights --payload   # read-only CLI against the real disk

# App (XcodeGen generates the Xcode project; it is not checked in)
cd App && xcodegen generate && cd ..
xcodebuild -project App/Sweep.xcodeproj -scheme Sweep -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
scripts/build-app.sh      # Release build, prints the .app path
scripts/install.sh        # Release build -> /Applications/Sweep.app
scripts/screenshots.sh    # regenerate docs/screenshots from demo data (light + dark)
scripts/release.sh        # ad-hoc signed DMG + zip + SHA256SUMS in dist/ (then: gh release create)
```

Never run several full test suites at the same time; they share temp space and spawn processes.

## 2. Map

| Path | What lives there |
|---|---|
| `Sources/SweepCore/Model` | `Item`, `Tier`, `ItemAction`, `ScanReport`, `VolumeSummary`, byte formatting |
| `Sources/SweepCore/System` | `CommandRunner` (runs tools without a shell), `ToolLocator`, `ProcessList` (sysctl, cwd, pgid), `FileSystemProbe` (lstat, `getattrlistbulk`) |
| `Sources/SweepCore/Accounting` | `SizeCalculator` (physical size, hard links once, dataless = 0, no device crossing), `VolumeAccounting` (free space, APFS volumes, folder buckets, unaccounted, Full Disk Access probe) |
| `Sources/SweepCore/Rules` + `Resources/rules.json` | Data-driven rules and the user override merge (`~/Library/Application Support/Sweep/rules.json`) |
| `Sources/SweepCore/Detectors` | One detector per `RuleKind`; `DetectorRegistry.detector(for:)` maps kinds to detectors |
| `Sources/SweepCore/Scanner.swift` | Runs all rules, streams events, merges duplicates (`consolidate`) |
| `Sources/SweepCore/RootCause` | Why caches regrow (`@latest` MCP servers, duplicates, orphaned helpers) |
| `Sources/SweepCore/Safety` | `ProtectedLocations` (never-touch list) and `SafetyGuard` (re-check at execution time) |
| `Sources/SweepCore/Execution` | `Plan` (dry run), `Executor` (per-path results, Trash, tools), `Verifier` (expected vs actual) |
| `Sources/SweepCore/History` | SQLite (system `sqlite3`), growth rates, keep / never-ask decisions |
| `Sources/SweepCore/Insights` | `Redactor`, `InsightsSummary`, `InsightsContract` (schema and validation), providers: `ClaudeCodeProvider`, `OllamaProvider`, `AnthropicProvider`; `Keychain` |
| `Sources/SweepCore/Maintenance` | Routine manifest, consent fingerprint, LaunchAgent, `MaintenanceRunner` |
| `Sources/SweepCore/Testing` | Fakes used by tests and previews: `FakeCommandRunner`, `FakeFileSystemProbe`, `FakeToolLocator` |
| `Sources/sweep` | CLI |
| `Sources/SweepAgent` | LaunchAgent binary for weekly routine sweeps, embedded in `Sweep.app/Contents/MacOS` |
| `App/SweepApp` | SwiftUI app: `AppModel` (all state and actions), `Views/`, `Theme/` (palette, Gumdrop styles, mascot), `DemoData` + `DebugSnapshot` (DEBUG only) |
| `App/project.yml`, `App/Signing.xcconfig` | XcodeGen spec; ad-hoc signing by default, team via git-ignored `App/Local.xcconfig` |
| `Tests/SweepCoreTests` | Swift Testing suites plus fixtures (`apfs_list.plist`, `simctl_runtimes.json`, `lsregister_dump.txt`, `home/`) |
| `docs/` | `ARCHITECTURE.md`, `SAFETY.md`, `INSIGHTS.md`, `RULES.md`, screenshots, original spec and plan |

## 3. Invariants (do not break these)

1. **Deterministic code decides what gets deleted.** The AI only explains a redacted summary. It never chooses items, never runs commands and never sees file contents or names of possibly sensitive files.
2. **No shell, ever.** Every external tool runs through `CommandRunner` with an absolute path and an argv array. Never `sh -c`, never string interpolation into a command.
3. **Every action is re-checked at execution time** by `SafetyGuard.check`. Never trust scan-time state, and judge idleness against `Date()`, not the scan's `now`.
4. **Allow lists.** Tool commands: `SafetyGuard.allowedTools`. Docker: `SafetyGuard.dockerAllowed`. These never include volumes, `system prune` or running containers. Docker only ever talks to a local daemon (`DockerDetector.isLocal`, re-checked before each command). If you widen an allow list, add a test that a dangerous neighbour is still refused.
5. **Never-touch locations** live in `ProtectedLocations`: cloud-synced folders, Keychains, Mail/Messages/Safari/Photos/Notes, `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, `/private/etc`, `/Library/Apple`, whole top-level folders and the user's protected list. An item that *contains* one of these is blocked as well.
6. **Symlinks and mounts:** an item whose path is now a link, or now resolves through one, is blocked. `deleteTree` works on directory handles with `O_NOFOLLOW` and never crosses into another volume.
7. **Caches and build folders are deleted; everything else goes to the Trash.** Admin-owned items are only revealed in Finder.
8. **Physical size, counted once.** Allocated blocks, `(dev, ino)` deduplicated, dataless files as 0, never crossing `st_dev`.
9. **Routine sweeps need consent for the exact routine list** (a SHA256 fingerprint of the routine rules). Changing which rules are routine pauses routine runs until the user approves again. The agent exits with code 3 without consent.
10. **Nothing is pre-selected that's expensive to get back** (`rebuildCost == .high`), and tier 2/3 items are never batch-selected.
11. **Results are honest:** per-path counts, with `protectedByMacOS`, `partial` (counts only the bytes actually unlinked) and `alreadyGone`. Never report "removed" for something that wasn't.

## 4. How to…

**Add a cache or folder rule.** Add an entry to `rules.json`; no code is needed for `pathCache`/`toolCache`. Order matters: when two rules match the same path, the earlier one wins. A `toolCache` rule's tool must be in `SafetyGuard.allowedTools`. Add the id to `RuleTests`' expected list. See [docs/RULES.md](docs/RULES.md).

**Add a new detector kind.**
1. Add a case to `RuleKind`.
2. Write a `Detector` in `Detectors/`.
3. Register it in `DetectorRegistry`.
4. Test it with `FakeFileSystemProbe`/`FakeCommandRunner`, or `TempDir` + `RealFileSystemProbe` when real filesystem behaviour matters.

**Add an action type.** Extend `ItemAction`. Handle it in `Executor.run`, in `SafetyGuard.check` (blocked by default) and in `ItemAction.preview`. Add a test that it's refused when unsafe.

**Add an AI provider.**
1. Implement `InsightsProvider.complete(system:user:schema:)`, honouring the schema it's given (item ids are constrained to the scan's ids).
2. Add a case to `InsightsProviderKind`, with `title`, `isLocal` and `init(cliName:)`.
3. Wire it into `AppModel.runInsights`, the Settings provider section and the CLI `insights` command.
4. Use `FakeCommandRunner` (or a captured request) in tests.

**Change the UI.** Run `scripts/screenshots.sh` and look at the PNGs; the Debug app can photograph itself without Screen Recording permission. `SWEEP_DEMO=1` loads made-up data and never reads or writes your history or preferences. Use the `Palette`, `Fonts`, `GumdropButtonStyle`, `PlatinumButtonStyle`, `.platinumPanel()` and `.platinumWell()` helpers in `Theme/Theme.swift`.

## 5. Gotchas

- **`Bundle.module` is only a last resort.** The embedded agent has no resource bundle beside it, so `RuleSet.locateBundledRules` looks in known places first. SwiftPM's generated `Bundle.module` crashes (rather than throwing) if the bundle is missing, so don't add new uses of it.
- **UserDefaults:** inside `Sweep.app` (the app or the embedded agent) settings live in `.standard`, because macOS ignores a suite named after the current bundle id. The CLI reads them as suite `dev.algamthe.sweep`. See `SettingsStore`.
- **Swift 6 strict concurrency:** use `lock.withLock {}` in async code (not `lock()`/`unlock()`). Copy `var`s into `let`s before sending closures. Long blocking work (`deleteTree`, `concurrentPerform`) runs on `DispatchQueue.global`, never on the cooperative pool.
- **`Scanner` clashes with Foundation's `Scanner`.** Ours is `SweepScanner`.
- **Speed:** the app scans in two phases (findings first, then folder sizes for the treemap). `getattrlistbulk` reads whole directories in one call, and top-level folders are measured in parallel.
- **Finder Automation prompt:** the first Trash listing waits for the user's answer (90 s timeout). A timeout is reported as "waiting for you to allow", not as an error.
- **Process orphans:** launchd (pid 1) also parents services it started on purpose. A helper only counts as orphaned when its process group leader is gone.
- **Docker:** Sweep never starts Docker. Images with several tags are removed by tag, not by id. `docker system df` prints sizes like `1.2GB (50%)`.
- **Editor extensions:** the installed version comes from the editor's `extensions.json`, not from the newest folder.
- **Signing:** macOS ties privacy permissions to the code signature. Ad-hoc builds lose permissions on rebuild; use `App/Local.xcconfig` with a team for day-to-day use.
- **This Mac has 16 GB of RAM.** Keep test workers at 3 or fewer and don't run suites in parallel sessions.

## 6. Testing rules

- Write the failing test first, watch it fail, then fix. Bug fixes always come with a regression test (see `ReviewFixTests.swift`, `MinorFixTests.swift` and `ReleaseReviewTests.swift`).
- Prefer fakes for tools and processes. Use `TempDir` (in `SizeCalculatorTests.swift`) for real filesystem behaviour (hard links, immutable flags, permissions).
- Tests must never touch the real home folder, except `trashMovesToTrash`, which cleans up after itself.
- The suite must be green before every commit: `swift test --parallel --num-workers 3`.

## 7. Conventions

- Commits: Conventional Commits (`feat(core):`, `fix(app):`, `docs:`…).
- User-facing copy is plain, friendly and specific: say what happens and what it costs. Don't blame the user, and don't use jargon without explaining it.
- Keep `README.md`, `docs/*.md` and this file accurate when behaviour changes.
- Bundle ids: app `dev.algamthe.sweep`, agent `dev.algamthe.sweep.agent`. Changing them loses users' settings, consent and permissions.

## 8. Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `App/project.yml`, update the status line in `README.md`, add a `CHANGELOG.md` entry.
2. `swift test --parallel --num-workers 3` must be green; commit and push; wait for CI.
3. `scripts/release.sh` builds the Release app ad-hoc signed (it refuses a build signed with a team) and writes `dist/Sweep-<version>.dmg`, `.zip` and `SHA256SUMS.txt`. `dist/` is git-ignored.
4. `gh release create v<version> dist/Sweep-<version>.dmg dist/Sweep-<version>.zip dist/SHA256SUMS.txt --target main --title "Sweep <version>" --notes "..."`. Keep the notes short: install steps (including "not notarized → Open Anyway / `xattr -dr com.apple.quarantine`"), what's new, link to the changelog.

Rules: release builds never contain a personal team id or organisation name (`codesign -dv` must show no TeamIdentifier). Never publish screenshots of a real disk; use `scripts/screenshots.sh` (demo data).

## 9. Open work

Known issues found in the 0.3.0 pre-release review and deliberately deferred (all minor). Each should get a failing test first, per section 6.

- **Consent fingerprint misses some rule fields.** `RoutineManifest.current` (`Maintenance/Maintenance.swift`) hashes id, title, kind, tool, action, paths, rebuild cost and params, but not `requiresNoProcess`, `requiresAppQuit` or `minBytes`. Loosening those in a user override doesn't pause routine sweeps.
- **Removed rule doesn't block its items.** `SafetyGuard.check` only applies rule blockers when `rules.rule(item.category)` exists; an item whose rule was removed from the override still runs. Fixing it means tests that use empty rule sets need a rule.
- **`fstrim` uses an unpinned image.** `DockerDetector.trimArguments` runs `alpine` by tag; pin it by digest.
- **Detector filesystem walks run on the cooperative pool.** Long synchronous walks in detectors should move to `DispatchQueue.global`, like `deleteTree`.
- **`Bundle.module` fallback** in `RuleSet.bundledData()` can crash instead of throwing (see Gotchas).

Not yet done at all: Developer ID signing and notarization, automatic updates, Intel builds.


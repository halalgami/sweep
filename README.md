# Sweep

A native macOS app for developers that finds where your disk space went, explains it, and reclaims it safely.
Mac OS 8 "Platinum" structure with iMac-era candy controls ("Gumdrop Platinum"), six fruit flavours, and a pixel trash-can mascot.

- **Everything that scans, measures, classifies or deletes is deterministic, tested Swift code.**
- An LLM is used only (and only if you turn it on) to explain a redacted summary of a finished scan. It never decides what is deleted, never sees file contents, and never runs commands.

Built by halalgami Technological Solutions.

## Requirements

- macOS 14 or later, Apple Silicon
- Xcode 26+ (Swift 6), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and run

```bash
# Core library, CLI and tests
swift test --parallel --num-workers 3
swift run sweep scan              # human summary (read-only)
swift run sweep scan --json       # full report as JSON
swift run sweep plan              # dry run: what a sweep would do
swift run sweep plan --routine    # dry run of the routine subset

# The app
cd App && xcodegen generate
xcodebuild -project Sweep.xcodeproj -scheme Sweep -configuration Release build
# or open App/Sweep.xcodeproj in Xcode and press Run
```

`App/Sweep.xcodeproj` is generated from `App/project.yml` and is not checked in. Signing uses the halalgami team (`YOURTEAMID`); change `DEVELOPMENT_TEAM` in `project.yml` to build under another team. Distribution is outside the Mac App Store (the sandbox would prevent Sweep from doing its job), Developer ID signed and notarized.

## Layout

| Path | What it is |
|---|---|
| `Sources/SweepCore` | Scanners, size accounting, rule engine, safety guard, executors, history, redaction, insights client, maintenance. No UI. |
| `Sources/SweepCore/Resources/rules.json` | Every detector rule (data, not code) |
| `Sources/sweep` | `sweep` developer CLI |
| `Sources/SweepAgent` | LaunchAgent binary for scheduled routine sweeps (embedded in Sweep.app) |
| `App/` | SwiftUI app: dashboard, plan → confirm → execute → verify, settings, menu-bar extra |
| `Tests/SweepCoreTests` | Unit tests and fixtures |
| `docs/superpowers/specs`, `docs/superpowers/plans` | Design and implementation plan |

## Permissions

| Permission | Needed for | Without it |
|---|---|---|
| **Full Disk Access** (optional) | Measuring Mail, Messages, Safari and other folders macOS protects | Everything works; the dashboard shows the gap as **Unaccounted** with a button to System Settings → Privacy & Security → Full Disk Access |
| Documents / Desktop / Downloads (asked on first scan) | Idle projects, large files, old installers | Those folders are skipped and the scan notes say so |
| **Automation → Finder** (asked when needed) | Listing the Trash to find leftovers of deleted apps; emptying the Trash when you press the button | Leftover detection is skipped with a note |
| Notifications | Low-space and growth alerts, routine sweep summaries | No alerts |

Admin-owned leftovers (`/Library/LaunchDaemons`, `PrivilegedHelperTools`, package receipts) are never removed by Sweep in this version. They are listed with **Reveal in Finder** (Finder asks for your password), and receipts show the exact `sudo pkgutil --forget <id>` command to run yourself.

## What Sweep never touches

Enforced by `SafetyGuard`, which re-checks every item immediately before acting on it (not just at scan time):

- Running Docker containers and Docker volumes (Docker commands are on a strict allow list; Sweep never starts Docker itself)
- iCloud Drive, Dropbox, OneDrive, Google Drive and Box folders, and your Desktop/Documents if they sync to iCloud
- Keychains, Mail, Messages, Safari and Photos data, and system folders
- Projects that became active since the scan, and git worktrees with uncommitted changes, unpushed commits or no upstream
- Anything inside a folder on your **protected** list (Settings → Scanning)
- Any path that turned into a symbolic link, or now resolves through one, since the scan
- APFS clones, SIP-protected files and cloud placeholders (shown in the "Protected" list so the totals add up)

Other safety rules:

- **Dry run first, always.** The plan shows every path, size, risk, rebuild cost and the exact command. Safe caches are confirmed together; idle build folders and "your call" items are ticked one by one and never pre-selected. Big re-downloads (AI model caches, Chrome's on-device model) start unticked.
- Caches and build folders are deleted. Everything else (VMs, downloads, installers, models, leftovers) goes to the **Trash**.
- No shell anywhere. Every tool runs as a direct process with its full error output captured. Results are reported per path ("12 removed, 3 protected by macOS").
- After a sweep, Sweep measures again and shows expected vs. actual. APFS often frees space a little later, so it re-checks after 60 seconds.

## Routine sweeps (menu bar and weekly)

One-click and scheduled sweeps run **only** the routine list: `uv cache prune`, `npm cache clean --force`, `brew cleanup -s`, `pnpm store prune`, `go clean -cache`, Xcode DerivedData, and Docker build cache prune by builder name. They are off until you open **Settings → Maintenance → Review and turn on…**, read the list, and tick "I understand what this removes". The menu bar shows what will run before you press the button. Every run posts a notification and writes a per-path log to `~/Library/Logs/Sweep/`. If the routine list ever changes (for example after a rules update), routine sweeps pause until you approve the new list.

The weekly schedule is a LaunchAgent (`~/Library/LaunchAgents/dev.algamthe.sweep.agent.plist`) that runs `Sweep.app/Contents/MacOS/SweepAgent`.

## Insights and redaction

Off by default (Settings → Insights). Providers: Claude via the Anthropic API (default model `claude-sonnet-5-5`, key stored in the Keychain) or a local model through Ollama.

What is sent is built by code (`InsightsSummary`), and you can read it with **View payload** before the first request:

- Bucket totals, the 40 largest items (ids, categories, sizes, tiers, rebuild cost, days since last use), growth rates, root-cause hints, and how often you declined each item.
- Your username becomes `~`; other users become `/Users/<user>`.
- Under Documents, Desktop, Downloads and every project folder, project and file names become `project_01`, `file.csv` and so on, unless you opt in to real names.
- Possible personal-data files are always fully redacted (`[redacted]`). File contents are never read.

The answer must match a strict JSON schema. Any answer that references an item id not in your scan is discarded. Sizes shown next to recommendations are computed by Sweep from the referenced items, never taken from the AI. If the call fails, the rest of the app is unaffected.

## Adding or changing a rule

Rules live in `Sources/SweepCore/Resources/rules.json`. To override or extend them without rebuilding, create `~/Library/Application Support/Sweep/rules.json`:

```json
{
  "version": 1,
  "rules": [
    { "id": "cache.mytool", "title": "MyTool cache", "tier": 1, "kind": "pathCache",
      "paths": ["~/.cache/mytool"], "action": { "type": "hardDelete" },
      "rebuildCost": "low", "rebuildHint": "MyTool re-downloads on next run",
      "explanation": "Downloaded artifacts for MyTool.", "requiresNoProcess": ["(^|/)mytool( |$)"] },
    { "id": "cache.gradle", "disabled": true }
  ]
}
```

- Same `id` as a bundled rule replaces it; `"disabled": true` removes it; new ids are added.
- `tier`: 1 safe cache, 2 idle build artifact, 3 needs your decision, 4 protected (display only).
- `kind` picks the detector logic: `pathCache`, `toolCache` (needs `tool` and an `action.command`), `libraryCaches`, `docker`, `vscodeExtensions`, `projectArtifacts`, `gitWorktrees`, `simRuntimes`, `vms`, `largeFiles`, `installers`, `sensitiveData`, `llmModels`, `conda`, `texlive`, `leftovers`, `protectedPaths`, `xcodeOldDerivedData`.
- `action.type`: `tool`, `hardDelete`, `trash`, `reveal`, `none`. Paths support `~` and `*` within one path component; there is no shell expansion.
- `requiresNoProcess` / `requiresAppQuit`: regexes matched against running command lines; while one matches, the item is shown but not actionable.
- Order matters: when two rules match the same path, the earlier rule wins.
- `"routine": true` adds a rule to the routine sweep (which pauses routine runs until you approve the new list). High rebuild-cost rules are never pre-selected.

Check a file with `swift run sweep rules --validate ~/Library/Application\ Support/Sweep/rules.json`.

## Data Sweep keeps

- `~/Library/Application Support/Sweep/history.db`: per-scan item sizes (for growth rates), your keep / never-ask decisions, and run results
- `~/Library/Logs/Sweep/`: per-run logs
- Preferences in the `dev.algamthe.sweep` defaults domain; API key in the Keychain

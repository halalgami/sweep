# Changelog

## 0.3.1 (2026-11-09)

### Fixed
- Routine sweep consent now covers each routine rule's "don't run while X is running", "quit X first" and minimum-size settings. Loosening any of them in a rules override pauses routine sweeps until you approve again. Because the fingerprint changed, **routine sweeps approved in 0.3.0 or earlier need approving once more.**
- An item whose rule was removed (for example from your rules override) after the scan is now skipped, not removed.
- Shrinking Docker's disk runs `alpine` pinned by digest, so a re-pushed tag can't change what runs with `--privileged`.
- Scanning no longer ties up Swift's shared threads with long folder walks, so the app stays responsive during big scans.
- A missing rules bundle now reports an error instead of crashing.

## 0.3.0 (2026-11-08)

First public release, with a downloadable, ad-hoc signed build (not notarized). Fixes from a pre-release safety review.

### Fixed (safety)
- **A folder that contains a protected place is now blocked.** Before, protecting `~/Library/Caches/com.foo/keep` didn't stop Sweep from deleting `~/Library/Caches/com.foo`, with `keep` inside it.
- **Docker only talks to a daemon on this Mac.** `DOCKER_HOST` and `DOCKER_CONTEXT` are ignored, and the active Docker context must be a local socket, both at scan time and again just before each command. Before, a context pointing at a remote server would have had its build cache and images cleaned.
- **Git worktrees with personal ignored files are no longer removable.** `git worktree remove` permanently deletes ignored files such as `.env`. Worktrees whose only ignored files are build output (`node_modules`, `.next`, …) can still be removed.
- **An item that contains a possible personal-data file becomes reveal-only.** Before, the nested file was dropped from the list and deleted with its parent.
- **Deleting never crosses into another mounted volume** (a disk image or network mount inside `node_modules`, for example), and never follows a folder swapped for a link mid-delete. It now works on directory handles (`openat`/`unlinkat` with `O_NOFOLLOW`).
- `/etc/...` paths are checked against the never-touch list as `/private/etc/...`. A path that can't be resolved is blocked.

### Fixed (honesty and privacy)
- Tool cleanups (`uv cache prune`, `brew cleanup`, …) are measured again afterwards and report what they actually freed, not the whole cache size. Docker results say that Docker may free less than estimated.
- Files written into a folder while Sweep deletes it make the result "partly removed", not "removed".
- A stopped scan no longer replaces the previous results or gets saved to history; it used to cause false "grew by…" alerts.
- The AI summary no longer includes Docker image names, VM names, worktree paths, large-file or installer names, or app-leftover names (unless you turn on "Send real project names"). Before, only names under Documents, Desktop, Downloads and your project folders were hidden.
- README: "Your call" items aren't all moved to the Trash. Simulator runtimes, Ollama models and Docker images are removed by their own tools, which is permanent. Ollama's `-cloud` models run on Ollama's servers, and Settings now says so.

### Changed
- **Bundle ids are now `dev.algamthe.sweep` and `dev.algamthe.sweep.agent`** (Keychain service, defaults domain and LaunchAgent label follow). Builds of 0.2.0 or earlier used the old ids: their settings, saved API key and weekly schedule aren't carried over, and macOS asks again for Full Disk Access and Finder automation.
- **Downloadable release.** `scripts/release.sh` builds an ad-hoc signed DMG and zip with SHA-256 sums; the README explains how to open an app that isn't notarized.
- **Scan Again is easy to find.** The top bar shows a coloured "Scan Again ⌘R" button on the dashboard and on the results screen, and the dashboard has a "Scan again" button next to the time of the last scan. Before, the only button was small and grey, and it was missing from the results screen.

## 0.2.0 (2026-11-08)

Open-sourced under the MIT license.

### Added
- **Claude Code as an AI provider** (now the default). It uses your Claude account through `claude -p`, locked down with no tools, `--safe-mode`, no MCP servers and no saved session. Ollama and the Anthropic API remain available.
- The Ollama model picker lists your installed models, and Settings has a "Check again" button for providers.
- `sweep insights` CLI command (`--payload` prints the exact redacted summary).
- The AI output schema limits item ids to the ids in the current scan, so local models can't invent them.
- Demo mode and a screenshot tour (`SWEEP_DEMO=1`, `scripts/screenshots.sh`).
- `scripts/build-app.sh`, `scripts/install.sh`.
- Docs: `AGENTS.md` / `CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/SAFETY.md`, `docs/INSIGHTS.md`, `docs/RULES.md`, `CONTRIBUTING.md`.

### Fixed
- Docker: `docker system df` sizes like `1.2GB (50%)` parsed as 0. Images with several tags couldn't be removed by id; they're now one item removed by its tags.
- A folder that disappeared before the sweep was reported as "removed (0)". It's now "Already gone".
- Partly removed items counted their full size as freed. Now only the bytes actually unlinked count.
- The 60-second re-check after a sweep only ran when lag was detected. It now always runs, as documented.
- The redactor crashed on a path equal to a sensitive folder plus `/`.
- The AI answer wasn't limited to 6 insights, and the risk value wasn't checked.
- Editor extensions: after a downgrade, the newest folder by date was kept instead of the installed one. Sweep now reads `extensions.json`, or falls back to the highest version.
- Orphaned MCP helpers: services started by launchd were flagged. Now only helpers whose process group leader is gone count.
- The Keychain was read on every Settings redraw.
- The never-touch list covered only `/usr/bin`, `/usr/sbin` and `/usr/lib`. It now covers all of `/usr` except `/usr/local`, plus `/Library/Apple`.
- Keychain and scheduling errors were reported as database errors.
- Large deletions blocked a Swift concurrency thread. They now run on a background queue.
- The first Finder Automation prompt could outlast the 30-second limit and be reported as "couldn't read the Trash". Sweep now waits 90 seconds and says it's waiting for your answer.

### Changed
- Signing is ad-hoc by default. Your team goes in a git-ignored `App/Local.xcconfig`.

## 0.1.0 (2026-11-07)

First working version: scanner, 39 rules, safety guard, plan / execute / verify, history and growth, decisions, routine sweeps with consent and a LaunchAgent, redacted AI insights (Anthropic API, Ollama), and the Gumdrop Platinum app with a menu bar extra.

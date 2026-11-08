# Changelog

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

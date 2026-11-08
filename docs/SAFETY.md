# Safety model

Sweep deletes files on people's computers. This page lists every safeguard, where it lives in the code and which tests pin it. If you change one of these, change its test too and update this page.

## Principles

1. **Read-only until confirmed.** Scanning never changes anything. Every sweep starts with a dry-run plan that shows each path, size, rebuild cost and the exact command.
2. **Check again at the last moment.** `SafetyGuard.check` runs for every item immediately before its action. Scan-time conclusions are never trusted at execution time.
3. **Prefer the tool's own cleanup.** `uv cache prune`, `brew cleanup -s` and `docker buildx prune --builder X` beat `rm`.
4. **Recoverable by default.** Only caches and build folders are deleted. VMs, downloads, installers and leftovers go to the Trash. Simulator runtimes, Ollama models and Docker images are removed by their own tools, which is permanent; the plan shows the exact command first.
5. **Honest reporting.** Each item ends as `removed`, `trashed`, `partial`, `protectedByMacOS`, `blocked`, `failed` or `alreadyGone`, with per-path counts.

## Safeguards

| Safeguard | Where | Tests |
|---|---|---|
| No shell; argv only; timeouts; grandchildren can't hang a run | `System/CommandRunner.swift` | `CommandRunnerTests` |
| Tool commands only from an allow list (`uv npm pnpm brew go xcrun ollama git`), and only at the path found now | `SafetyGuard.allowedTools`, `check` | `SafetyGuardTests`, `ReviewFixTests` |
| Docker: only `builder prune -f`, `buildx prune -f --builder NAME`, `image prune -f`, `image rm TAG…` (no flags), and the fstrim command. Never volumes, `system prune` or containers. Never starts Docker. Only talks to a daemon on this Mac: `DOCKER_HOST`/`DOCKER_CONTEXT` are dropped and the active context must be a `unix://` socket, at scan time and again before each command | `SafetyGuard.dockerAllowed`, `DockerDetector.isLocal` | `SafetyGuardTests.dockerCommandsAreAllowlisted`, `MinorFixTests.imageRemovalByTagIsAllowlisted`, `ReleaseReviewTests` |
| Never-touch locations: cloud folders (and Desktop/Documents when iCloud syncs them), Keychains, Mail, Messages, Safari, Photos, Notes, `/System`, `/usr` (not `/usr/local`), `/bin`, `/sbin`, `/private/etc`, `/Library/Apple`, whole top-level folders, the user's protected list. An item that **contains** one of these is blocked too. Checked on the path as written and as resolved (`/etc` → `/private/etc`); if the path can't be resolved, it's blocked | `Safety/ProtectedLocations.swift`, `SafetyGuard.checkPath` | `SafetyGuardTests`, `MinorFixTests.usrIsNeverTouchedExceptUsrLocal`, `ReleaseReviewTests` |
| Path vanished → `alreadyGone`, nothing done | `Executor.run` | `MinorFixTests.vanishedFolderIsReportedAlreadyGone` |
| Path became a symlink or resolves through one → blocked | `SafetyGuard.checkPath` | `SafetyGuardTests` |
| Idle build folders: project must still be idle **now**. No recent commits or edits, no uncommitted changes, no process running from the project or the folder. In a monorepo the whole git repo counts. No project root found → blocked | `SafetyGuard.checkPath`, `IdleChecker`, `projectRoot(of:)` | `IdleTests`, `ReviewFixTests` |
| Git worktrees: blocked if `git status --porcelain --ignored` shows changes, or ignored files that aren't build output (`git worktree remove` deletes ignored files permanently: `.env`, local data). Checked at scan and execution time; the branch is kept | `SafetyGuard.checkPath`, `GitWorktreeDetector.parseStatus` | `IdleTests`, `ReleaseReviewTests` |
| Apps and tools running → item shown but not actionable (`requiresAppQuit`, `requiresNoProcess`), checked again at execution time. VMs are blocked while running | `ItemFactory.blocker`, `rules.json` | `CacheDetectorTests`, `ReviewFixTests` |
| Leftovers: only for apps actually in the Trash, matched by whole bundle-id components, and never while the app is still installed elsewhere. Admin-owned files are revealed only | `LeftoversDetector` | `DecisionDetectorTests`, `ReviewFixTests` |
| Possible personal-data files are reveal-only and fully redacted from AI. The flag survives merges, and an item that contains one becomes reveal-only too | `SensitiveDataDetector`, `Scanner.consolidate` | `ReviewFixTests`, `ReleaseReviewTests` |
| Hard delete is bottom-up and works on open directory handles (`openat`/`unlinkat`, `O_NOFOLLOW`), so a folder swapped for a link mid-delete is never followed. It never crosses into another mounted volume. Each path is counted; `EPERM`/`EACCES`/`EROFS` count as "protected by macOS". Files that appear during the delete make it `partial`, not `removed`. Partial results count only the bytes actually unlinked; tool cleanups are re-measured afterwards | `Executor.deleteTree`, `Executor.run` | `ExecutorTests`, `MinorFixTests.partialResultCountsOnlyRemovedBytes`, `ReleaseReviewTests` |
| High rebuild cost is never pre-selected; tiers 2 and 3 are never batch-selected; Keep / Never ask hide items, even from an open plan | `Plan.build`, `Plan.removing` | `PlanTests`, `ReviewFixTests` |
| Routine sweeps need consent for the exact routine list (SHA256 of the routine rules). Any change pauses them; the agent exits 3 without consent | `Maintenance.swift`, `SweepAgent` | `MaintenanceTests` |
| Emptying the Trash asks first and says it empties the **whole** Trash | `RunViews.VerifyView` | UI-only |

## What the AI can and can't do

The AI gets a JSON summary built by `InsightsSummary`, after `Redactor` has removed identifying names. It has no tools. Its answer is validated: strict schema, item ids limited to the scan's ids, at most 6 insights and 10 recommendations, and risk must be `low`, `medium` or `high`. A violation discards the whole answer. Nothing in the answer can select, delete or run anything. See [INSIGHTS.md](INSIGHTS.md).

## Reporting a safety problem

If you find a way to make Sweep remove something it shouldn't, please open a GitHub issue titled **"Safety:"**. Describe the situation and what was removed, but not your personal paths. Safety bugs are fixed before anything else.

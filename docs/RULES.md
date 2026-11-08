# Rules

Sweep looks for things through **rules**, which are data. A rule says where to look, what tier the finding is, what action to take and how expensive it is to get back. The logic lives in **detectors**, one per rule `kind`. Rules only parameterize them.

- Bundled rules: [`Sources/SweepCore/Resources/rules.json`](../Sources/SweepCore/Resources/rules.json) (39 rules)
- Your overrides: `~/Library/Application Support/Sweep/rules.json` (no rebuild needed)

## Override file

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

- A rule with the same `id` as a bundled rule replaces it. `"disabled": true` removes it. New ids are added.
- Check the file with `swift run sweep rules --validate ~/Library/Application\ Support/Sweep/rules.json`.

## Fields

| Field | Meaning |
|---|---|
| `id` | Stable id, `area.name` (for example `cache.uv`). Item ids are derived from it, so renaming one forgets the user's decisions |
| `title`, `explanation` | Shown to the user. Plain language: what it is and what removing it costs |
| `tier` | `1` safe cache, `2` idle build artifact, `3` needs your decision, `4` protected (display only) |
| `kind` | Which detector runs it (see below) |
| `paths` | Where to look. `~` and `*` within one path component are supported; there is no shell expansion |
| `tool` | For `toolCache`: the tool's name, resolved by `ToolLocator` (must be in `SafetyGuard.allowedTools`) |
| `action.type` | `tool`, `hardDelete`, `trash`, `reveal`, `none` |
| `action.command` | For `tool`: the arguments (an argv array, never a shell string) |
| `rebuildCost` | `none`, `low`, `medium`, `high`. `high` is never pre-selected |
| `rebuildHint` | How it comes back ("Xcode rebuilds it on the next build") |
| `routine` | `true` adds the rule to the routine sweep. That changes the consent fingerprint, so routine runs pause until the user approves again |
| `defaultSelected` | Override pre-selection (tier 1 only) |
| `requiresNoProcess` | Regexes matched against running command lines. While one matches, the item is shown but not actionable |
| `requiresAppQuit` | The same, phrased as "Quit X first" |
| `minBytes` | Ignore findings smaller than this |
| `params` | Kind-specific settings (see below) |

**Order matters:** when two rules match the same path, the earlier rule wins. That's why the generic `cache.library` comes after the specific cache rules.

## Kinds

| Kind | Detector | Notes / params |
|---|---|---|
| `pathCache` | `PathDetector` | Measures each existing path |
| `toolCache` | `ToolCacheDetector` | Uses the tool's own cleanup command. `params.dirCommand` asks the tool where its cache is (`uv cache dir`, `go env GOCACHE`) |
| `libraryCaches` | `LibraryCachesDetector` | Large folders in `~/Library/Caches` not claimed by an earlier rule |
| `docker` | `DockerDetector` | `params.op`: `builder` (prune per builder name), `dangling`, `trim` (fstrim the VM disk), `images` (unused images, removed by tag). Skipped when Docker isn't running |
| `vscodeExtensions` | `EditorExtensionsDetector` | Old versions; the installed one comes from `extensions.json` |
| `projectArtifacts` | `ProjectArtifactsDetector` | `params.artifacts`: comma list of folder names. Only in idle projects (no recent commits or edits, no uncommitted changes, no process running from it) |
| `gitWorktrees` | `GitWorktreeDetector` | Clean, merged and pushed worktrees; removed with `git worktree remove` |
| `simRuntimes` | `SimRuntimeDetector` | `xcrun simctl runtime` entries no device uses |
| `vms` | `VMDetector` | UTM, Parallels, VMware bundles; blocked while running |
| `largeFiles`, `installers` | `LargeFilesDetector`, `InstallersDetector` | `params.extensions`, `params.olderThanDays` |
| `llmModels` | `LLMModelsDetector` | Ollama (removed with `ollama rm`) and LM Studio models |
| `conda`, `texlive` | `CondaDetector`, `PathDetector` | Falls back to Reveal in Finder when not deletable by the user |
| `xcodeOldDerivedData` | `DeviceSupportDetector` | Old device-support folders; `params.keepNewest` |
| `sensitiveData` | `SensitiveDataDetector` | Data files that may hold personal data: reveal only, always fully redacted from AI |
| `leftovers` | `LeftoversDetector` | Support files of apps in the Trash, matched by bundle id |
| `protectedPaths` | `ProtectedDetector` | APFS clones and SIP paths, shown so totals add up |

## Adding a rule to the bundled set

1. Add the entry to `rules.json` in the right position (specific before generic).
2. Add its id to the expected list in `Tests/SweepCoreTests/RuleTests.swift`.
3. If it's a `toolCache`, make sure the tool is in `SafetyGuard.allowedTools`, and add a test that the command is allowed.
4. If it's `routine: true`, update `MaintenanceTests` (the routine id list) and the README's routine list. Existing users will be asked to approve again.
5. Run `swift test --parallel --num-workers 3`.

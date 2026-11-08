# AI insights

Insights are optional and off by default. When you turn them on, an AI explains a finished scan in plain language and ranks what to do. **It never decides what gets deleted, never runs anything and never sees file contents.** Everything else in Sweep works without it.

## Providers

Pick one in **Settings → Insights**, or with `--provider` on the CLI.

| | Claude Code | Ollama | Anthropic API |
|---|---|---|---|
| Kind (`InsightsProviderKind`) | `.claudeCode` (default) | `.ollama` | `.anthropicAPI` (stored as `"claude"` for 0.1.0 settings) |
| Code | `ClaudeCodeProvider` | `OllamaProvider` | `AnthropicProvider` |
| Account | Whatever `claude` is signed in with (Pro/Max subscription or its configured API key) | None | API key, kept in the Keychain |
| Where data goes | Anthropic | Stays on the Mac (`127.0.0.1:11434`), except `-cloud` models, which Ollama runs on its servers | Anthropic |
| Model | `sonnet` (default), `opus`, `haiku` | Any installed model (listed from `/api/tags`) | `claude-sonnet-5-5` (default) |
| How | `claude -p` as a child process, no shell | `POST /api/chat` with `format` = schema | `POST /v1/messages` with `output_config.format` = JSON schema, automatic fallback model |

### Claude Code lockdown

`ClaudeCodeProvider` runs:

```
claude -p --safe-mode --tools "" --strict-mcp-config --no-session-persistence \
       --output-format json --model sonnet --effort medium \
       --system-prompt <fixed prompt> --json-schema <schema> <redacted summary JSON>
```

| Flag or setting | Effect |
|---|---|
| `--tools ""` | No tools at all: it can't read files, run commands or browse |
| `--safe-mode` | No CLAUDE.md, hooks, plugins, skills or MCP servers from your setup are loaded |
| `--strict-mcp-config` | No MCP servers (none are passed) |
| `--no-session-persistence` | Nothing is saved to your Claude Code history |
| Working directory | An empty `$TMPDIR/SweepInsights` folder |
| Answer | The `structured_output` field of the JSON envelope. `is_error` becomes a readable message ("Run `claude` once in Terminal to check you're signed in") |
| Executable | Found through `ToolLocator`, then in `~/.claude/local`, `~/.local/bin`, `~/.npm-global/bin` and `~/.volta/bin` |

## What is sent

`InsightsSummary.build` produces the only data an AI ever sees. Press **View payload** in the app, or run `sweep insights --payload`, to read it exactly.

- Disk totals, bucket totals and whether Full Disk Access is on.
- The 40 largest items: id, category, title, redacted path, size, tier, rebuild cost, whether it's actionable, days since last use, growth per day and evidence lines. Evidence is dropped for redacted items.
- Root-cause hints, such as `@latest` MCP servers, and how often you declined each item.

The `Redactor` changes names before anything is sent:

| Original | Sent as |
|---|---|
| `/Users/you/...` | `~/...` |
| Other users' folders | `/Users/<user>` |
| Docker images, VMs, git worktrees, large files, installers and app leftovers (anywhere) | A generic label and path (`virtual machine 01`, `~/Parallels/…/item.pvm`, `docker://image`), no evidence lines, unless you turn on "Send real project names" |
| Under Documents, Desktop, Downloads and your project roots | Project and file names become `project_01`, `folder`, `file.csv` and so on, unless you turn on "Send real project names". Well-known folder names (`node_modules`, `.venv`, `.git`, …) are kept |
| Possible personal-data files | `[redacted]`, with category `sensitive-data` |

## Output contract

`InsightsContract` defines the answer:

```json
{ "headline": "…",
  "insights": [{ "title": "…", "detail": "…", "evidenceItemIds": ["…"] }],
  "recommendations": [{ "itemIds": ["…"], "action": "…", "expectedBytes": 0, "risk": "low|medium|high", "why": "…" }],
  "maintenanceSuggestions": ["…"],
  "questionsForUser": ["…"] }
```

- The schema sent to the model limits `itemIds` and `evidenceItemIds` to the **ids in this scan** (`jsonSchema(knownIDs:)`). Providers that enforce schemas therefore can't make ids up. Small local models used to do this before the constraint was added.
- `validate` then rejects the whole answer when:
  - it isn't JSON;
  - the headline is empty;
  - there are more than 6 insights or more than 10 recommendations;
  - a risk isn't `low`, `medium` or `high`;
  - any id isn't in the scan.
- The UI never shows `expectedBytes`. Sizes next to suggestions are computed by Sweep from the referenced items.

## Adding a provider

1. Implement `InsightsProvider.complete(system:user:schema:)`. Pass the schema to the model's structured-output feature if it has one, and return the raw JSON text.
2. Add a case to `InsightsProviderKind` with `title`, `isLocal` and a CLI name in `init(cliName:)`.
3. Wire it into `AppModel.runInsights` and `providerDescription`, the Settings provider section and the CLI `insights` command (`Sources/sweep/CLIExtensions.swift`).
4. Test it with `FakeCommandRunner` (for CLIs) or by checking the request you build (for HTTP). Cover success, error envelopes, timeouts and the schema being passed through.
5. Update this page and the README's provider table.

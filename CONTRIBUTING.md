# Contributing

Thanks for helping. Sweep deletes files on people's Macs, so changes are held to a high bar for safety and honesty. Read [AGENTS.md](AGENTS.md) first: it has the commands, a map of the code, the invariants and the gotchas. It's written for people and coding agents alike.

## Setup

```bash
brew install xcodegen
git clone https://github.com/halalgami/sweep.git && cd sweep
swift test --parallel --num-workers 3
cd App && xcodegen generate && open Sweep.xcodeproj
```

You don't need an Apple Developer account: builds are signed "to run locally" by default. To use your own team, see `App/Signing.xcconfig`.

## Workflow

1. **Open an issue first** for anything bigger than a small fix, especially new rules that delete things.
2. **Test first.** Write a failing test, watch it fail, then make it pass. Bug fixes always come with a regression test.
3. **Keep the suite green:** `swift test --parallel --num-workers 3`. Build the app: `scripts/build-app.sh`.
4. **UI changes:** run `scripts/screenshots.sh` and include before/after images in the PR. Demo mode uses made-up data, so screenshots never show your disk.
5. **Docs:** update `README.md`, `AGENTS.md` and the relevant `docs/*.md` when behaviour changes.
6. **Commits:** Conventional Commits (`feat(core): …`, `fix(app): …`, `docs: …`).

## New rules

Rules are data in `Sources/SweepCore/Resources/rules.json`; see [docs/RULES.md](docs/RULES.md). A new rule needs:

- the right tier (when in doubt, a higher tier: let the user decide);
- an honest `rebuildCost` and `rebuildHint`;
- a plain-language `explanation`;
- `requiresAppQuit` / `requiresNoProcess` when the owning app could be using it;
- a test.

## Safety problems

If Sweep removed, or offered to remove, something it shouldn't, open an issue titled **"Safety: …"**. Describe the situation without your personal paths. These come before everything else.

## Code of conduct

Be kind, be specific and assume good intent.

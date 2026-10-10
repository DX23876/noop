# Fork agent rules (DX23876)

These rules apply in this fork on top of [`AGENTS.md`](../../AGENTS.md), which is ryanbr/noop's guide kept
verbatim. Where the two disagree, this file wins. Everything else that is true here and not upstream is in
[`docs/FORK_GUIDE.md`](../FORK_GUIDE.md); the reasons behind fork choices are in
[`decisions.md`](decisions.md).

## Scope

- Apple-only: iOS, macOS and watchOS. There is no Android tree (removed 2026-08-14).
- The cross-platform parity contract `AGENTS.md` calls the #1 rule is retired here (2026-07-23): no Kotlin
  twin, no byte-identical Room/GRDB or `.noopbak` gate. Offline, no server, no account and anonymity still
  bind.

## Analysis changes and upstream updates

Every RyanBR upstream commit/PR and every local feature must explicitly record:

`Analysis migration required: yes/no`

Choose **yes** if existing derived values can become stale because scoring math, an analytics or input
window, the meaning of a stored derived value, source precedence or provenance, baseline semantics or
cache invalidation changed. Then bump `IntelligenceEngine.currentAnalysisRecipeVersion` (the fork's own
lineage, numbered AI-n), add a resumable versioned migration with regression tests, and describe the
rescore in the release notes. A migration writes its recipe cursor only after success, never erases raw
samples or user sleep/workout corrections, and uses the narrowest affected-day interval it can prove.

Choose **no** for UI, navigation, logging, documentation or output-identical performance work; those must
not bump the recipe. Never tie historical analysis to `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, an
Xcode installation or an ordinary launch. The confirmation-gated manual 21-day reanalysis in Settings is
for diagnostics and does not advance the recipe version.

## Readout and CI invariants

- Resolve repeated readouts of one fact through one gated resolver and one supplied clock. Prefer one
  readout; when several are necessary, test the shared resolver rather than counting its callers.
- A CI gate must observe the change that can invalidate it. Require a stable expected roster and zero
  non-success results; when a trigger cannot cover an invalidator, make that limitation explicit in the
  failure message.

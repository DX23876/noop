# AGENTS.md — repository agent rules

Read and follow `CLAUDE.md` before changing NOOP. Its architecture, safety, parity, build and PR rules
apply to every human or automated agent working in this repository.

## Analysis changes and upstream updates

Every RyanBR upstream commit/PR and every local feature must explicitly record:

`Analysis migration required: yes/no`

Choose **yes** if existing derived values can become stale because scoring math, input/aggregation
windows, stored-value meaning, source precedence/provenance, baselines, or invalidation semantics changed.
Then bump `IntelligenceEngine.currentAnalysisRecipeVersion`, add a resumable versioned migration and
tests, update the Android twin when applicable, and describe the rescore in release notes. The recipe
cursor is written only after success; raw samples and user sleep/workout corrections are never erased.

Choose **no** for UI, navigation, logging, documentation, or output-identical performance work. Never
tie historical analysis to the marketing version, build number, Xcode installation, or ordinary launch.
Use an exact affected-day interval whenever the triggering mutation provides one. The confirmation-gated
manual 21-day reanalysis in Settings is for diagnostics and does not advance the recipe version.

## Readout and CI invariants

- Resolve repeated readouts of one fact through one gated resolver and one supplied clock. Prefer one
  readout; when several are necessary, test the shared resolver rather than counting its callers.
- A CI gate must observe the change that can invalidate it. Require a stable expected roster and zero
  non-success results; when a trigger cannot cover an invalidator, make that limitation explicit in the
  failure message.

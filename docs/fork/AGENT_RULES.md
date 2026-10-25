# Fork agent rules (DX23876)

These rules apply in this fork on top of [`AGENTS.md`](../../AGENTS.md), which is ryanbr/noop's guide kept
verbatim. Where the two disagree, this file wins. Everything else that is true here and not upstream is in
[`docs/FORK_GUIDE.md`](../FORK_GUIDE.md); the reasons behind fork choices are in
[`decisions.md`](decisions.md).

## Scope

- Apple today: iOS, macOS and watchOS. Android returns on a shared Swift core (decided 2026-10-24, see
  [`android/PLAN.md`](android/PLAN.md)); until phase D of that plan restores the tree there is no `android/`
  directory, and iOS restructuring for the core must not drop any feature without the owner's agreement.
- The cross-platform parity contract `AGENTS.md` calls the #1 rule is retired here (2026-07-23): no Kotlin
  twin, no byte-identical Room/GRDB or `.noopbak` gate. Offline, no server, no account and anonymity still
  bind.

## Analysis changes and upstream updates

Every RyanBR upstream commit/PR and every local feature must explicitly record:

`Analysis migration required: yes/no`

Choose **yes** if existing derived values can become stale because scoring math, an analytics or input
window, the meaning of a stored derived value, source precedence or provenance, baseline semantics or
cache invalidation changed. Then bump `AnalysisRecipe.currentVersion` in `Packages/StrandCore` (the fork's
own lineage, numbered AI-n) and describe the rebuild in the release notes. One rule applies to every bump
(decided 2026-10-25, AI-31 onward):

- **At most one bump per release.** While the current recipe has not shipped, a further analysis change
  rides on it instead of bumping again.
- **Every bump runs the same rebuild** (`AnalysisRecipe.RebuildStep`): every day with raw strap data is
  scored again and every derived table is rebuilt from the stored inputs. There are no per-recipe windows.
  A change that adds a derived table or series adds its rebuild as a step, with a test, instead of a
  migration of its own.
- **Repairs of stored inputs** (not derivations, for example re-pricing rows the wearer did not enter) are
  the only exception: an idempotent repair listed in `AnalysisRecipe.legacyRepairs` or guarded by its own
  cursor, with a regression test.
- The rebuild resumes at the step it was in, writes the recipe cursor only after its last step, never
  erases raw samples and never replaces a value an import or the wearer supplied (a corrected night keeps
  its bed and wake times; only its derived stages are recomputed).

Choose **no** for UI, navigation, logging, documentation or output-identical performance work; those must
not bump the recipe. Never tie historical analysis to `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, an
Xcode installation or an ordinary launch. The confirmation-gated manual 21-day reanalysis in Settings is
for diagnostics and does not advance the recipe version.

## Before pushing app or package code

Run `Tools/local-tests.sh` on the committed tree. No CI runs StrandTests or the package tests on a push,
and `.githooks/pre-push` refuses a push to `main` that changes app code, a package or `project.yml` without
a passing run for exactly that tree.

## Readout and CI invariants

- Resolve repeated readouts of one fact through one gated resolver and one supplied clock. Prefer one
  readout; when several are necessary, test the shared resolver rather than counting its callers.
- A CI gate must observe the change that can invalidate it. Require a stable expected roster and zero
  non-success results; when a trigger cannot cover an invalidator, make that limitation explicit in the
  failure message.

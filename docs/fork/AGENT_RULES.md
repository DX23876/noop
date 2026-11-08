# Fork agent rules (DX23876)

These rules apply in this fork on top of [`AGENTS.md`](../../AGENTS.md), which is ryanbr/noop's guide kept
verbatim. Where the two disagree, this file wins. Everything else that is true here and not upstream is in
[`docs/FORK_GUIDE.md`](../FORK_GUIDE.md); the reasons behind fork choices are in
[`decisions.md`](decisions.md).

## Scope

- iOS, macOS and watchOS, and Android on a shared Swift core (decided 2026-10-24, see
  [`android/PLAN.md`](android/PLAN.md)). `android/` is back since 2026-10-25 (phase D); upstream merges
  follow `Tools/resolve-android-merge.py` (see `docs/FORK_GUIDE.md`). iOS restructuring for the core must not
  drop any feature without the owner's agreement.
- The cross-platform parity contract `AGENTS.md` calls the #1 rule is retired here (2026-07-23): no Kotlin
  twin, no byte-identical Room/GRDB or `.noopbak` gate. Offline, no server, no account and anonymity still
  bind.

## Android is a shell around the shared core

`AGENTS.md` describes Android as an independent Kotlin, Compose and Room reimplementation. That is not
true here. Since 2026-11-01 ([`android/CORE-ONLY-PLAN.md`](android/CORE-ONLY-PLAN.md)):

- **Room is gone from the app.** Android stores only in the core's GRDB database, through the generated
  `CoreWhoopDao` (`Tools/gen_core_dao.py`). Room stays only as a transitive WorkManager dependency. Never add
  a Room entity, DAO or migration; a schema change is a `WhoopStore` migration that both platforms run.
- **Logic lives in the core, never in Kotlin.** Scoring, analytics, import, backup and any computation go
  into `Packages/` (`StrandCore`, `StrandAnalytics`, `WhoopStore`, `StrandImport`, `StrandTraining`) and
  reach Android through `NoopCoreJNI`. Kotlin keeps Bluetooth transport, Android services, UI and
  presentation helpers only. A missing Android feature is answered by moving its logic into the core, not
  by writing a Kotlin version.
- **A change to the core changes both platforms.** `Tools/local-tests.sh` builds and tests Android for any
  change under `Packages/**` or `project.yml`; the parity oracles in
  `android/app/src/test/resources/core_parity/` must still pass.
- **Android UI is the Forge Compose screens** (`com.noop.ui.forge`), following iOS feature by feature:
  inventory every iOS screen, setting and action before porting one.
- Running state and open steps: [`android/STATUS.md`](android/STATUS.md). Unverified until a real strap:
  acknowledging strap history only after the core stored it.

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

## Crediting adopted work

When the fork takes someone's work directly (a commit from their fork, or a ryanbr/noop pull request
ryanbr has not merged), the adopting commit says `Adopted from <source> by @handle` and carries their
`Co-authored-by` line. The same change adds them to `ATTRIBUTION.md` ("NOOP Forge: work adopted from
other people") and to `AcknowledgementsView.contributors`, and the release notes thank them by handle.
Work that arrives through an ordinary upstream merge is credited upstream and needs none of this.

## Before pushing app or package code

Run `Tools/local-tests.sh` on the committed tree. No CI runs StrandTests, the package tests or (for a
package change) the Android build on a push, and `.githooks/pre-push` refuses a push to `main` that
changes app code, a package or `project.yml` without a passing run for exactly that tree.

- A full run takes about 45 minutes (macOS StrandTests, iOS build, Android builds). For work in several
  steps, commit each step, test it narrowly (`swift test` in the touched package, the `Tools/` Python
  tests), and run the full script once on the final tree before the one push.
- Finished fork work goes straight to `origin/main`; no pull request. Contributions to `ryanbr/noop` are
  separate branches based on `upstream/main` and go through a pull request there.
- **Do not assume a push ran CI.** No GitHub Actions run has started on `DX23876/noop` since 2026-11-02,
  not even the schedules (account limit suspected, unresolved). Before calling a push green, check that
  `gh run list -R DX23876/noop --commit <sha>` shows runs at all; when it shows none, say so and rely on
  the local run, the `Tools/` Python tests (`cd Tools && python3 -m unittest discover -p 'test_*.py'`) and
  `python3 Tools/i18n_audit.py --ci origin/main`.

## Readout and CI invariants

- Resolve repeated readouts of one fact through one gated resolver and one supplied clock. Prefer one
  readout; when several are necessary, test the shared resolver rather than counting its callers.
- A CI gate must observe the change that can invalidate it. Require a stable expected roster and zero
  non-success results; when a trigger cannot cover an invalidator, make that limitation explicit in the
  failure message.

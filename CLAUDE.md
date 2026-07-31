# CLAUDE.md — working on NOOP

Guidance for anyone (human or AI agent) submitting a pull request. This is the high-signal map;
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) is the full guide (BLE safety contract, design-system
rules, add-a-metric/screen/command recipes), [`docs/BUILD.md`](docs/BUILD.md) covers signing/pairing,
and [`docs/IOS.md`](docs/IOS.md) covers the iOS target. Read this first; follow the links for depth.
The rest of `docs/` is a much larger set than those three links — see
[Documentation & session workflow](#documentation--session-workflow) below for the map, how to use
it, and how to hand off a session without losing context.

## What NOOP is (and the hard scope limits)

NOOP is a **fully offline, on-device** companion app for WHOOP 4.0 and 5.0/MG straps (with
**experimental** Oura support in the tree — gated behind `ExperimentalBrand`, not a shipped supported
strap). It pairs over Bluetooth, stores everything in on-device SQLite, and computes recovery / strain
/ HRV / sleep locally. There is **no server, no account, no cloud sync, no telemetry**, and the project stays
**anonymous** (iOS/Android ship build-from-source / sideload, not via the App Store).

These are hard constraints, not preferences. A PR is out of scope if it:
- adds a server, account, cloud sync, or sends any data off-device;
- adds analytics/telemetry/crash-reporting that phones home;
- adds WHOOP firmware, decompiled app code, logos/assets, or any DRM circumvention. NOOP is
  **clean-room interoperability** with hardware the user owns — keep it that way.

Licensing: by opening a PR you agree your contribution is under the repo's
[PolyForm Noncommercial 1.0.0](LICENSE) license.

## Architecture at a glance

Core logic lives in **cross-platform Swift packages**; each platform is a thin app layer over them.
The **macOS app is the reference implementation**; **Android is a full shipped app**; **iOS is a
build-from-source target** folded into the same repo.

| Layer | Path | What lives here |
|---|---|---|
| Protocol (pure) | `Packages/WhoopProtocol`, `Packages/OuraProtocol` | BLE frame parse, CRC, command/event/packet decode. **No CoreBluetooth.** Builds on Linux; also builds the `whoop-decode` CLI. |
| Storage | `Packages/WhoopStore` | GRDB/SQLite persistence: migrations, streams, caches. |
| Analytics (pure) | `Packages/StrandAnalytics` | HRV / recovery / strain / sleep / correlation math. Database-free. |
| Import | `Packages/StrandImport` | WHOOP CSV + Apple Health importers. |
| Design system | `Packages/StrandDesign` | SwiftUI palette / components / charts. |
| macOS + shared app | `Strand/` (scheme **Strand**, product `NOOP`, macOS 13+) | `BLE/` (CoreBluetooth), `Collect/`, `Data/` (Repository), `Screens/`, `App/` (`RootView`/`ContentView` = sidebar shell). Shared with iOS where a file isn't macOS-only. |
| iOS-only app | `StrandiOS/` (scheme **NOOPiOS**, iOS 17+), `StrandiOSShared/`, `StrandiOSWidgets/`, `NOOPWatch*` | `StrandiOSApp` (@main), `RootTabView` (the iOS tab shell — no macOS analogue), iOS widgets, watch app. |
| Android app | `android/` (Kotlin, Compose, Room; flavors `Full`/`Demo`) | `com.noop.{ble,collect,data,ingest,analytics,protocol,ui,widget,…}` — mirrors the Swift layering with its own reimplementations. |

`project.yml` is the **XcodeGen source of truth**; `Strand.xcodeproj/` is generated — never hand-edit
or commit it. Re-run `xcodegen generate` after adding/removing files or editing `project.yml`.

**Where new code goes:** the more "wire-level" (bytes) or "math-level" a change is, the deeper into
`Packages/` it belongs — and the more it must be covered by a `swift test` that runs with no app, no
strap, no CoreBluetooth. Never add `import AppKit` / `import UIKit` / `import CoreBluetooth` under
`Packages/`; guard framework code with `#if canImport(AppKit)` / `#elseif canImport(UIKit)`.

## The cross-platform parity contract (RETIRED — iOS/macOS-only as of 2026-07-23)

> **This contract no longer binds.** The project is now iOS/macOS-only; the Android target is dropped and
> is no longer kept in sync. Byte-identical analytics, platform-neutral FNV-1a hashing, the `.noopbak`
> byte-identical whitelist, and Room/GRDB schema agreement are **no longer gates** on a change. The
> Android tree may remain in the repo but is not a parity obligation. **Separate and still binding:** the
> app stays fully offline, on-device, no server, no account, no cloud sync, no telemetry, anonymous — see
> "What NOOP is". The historical contract is preserved below for context.

Android is an independent reimplementation of the same logic, **not** a port that shares code with
Swift. So:

- **Analytics and stored data must be byte-identical across Swift and Kotlin.** If you change a
  decoder, an analytics formula, a migration, or a stored value on one platform, change the twin on
  the other in the same PR (or explicitly call out why not). "It's Compose vs SwiftUI" is *not* a
  license to let the numbers diverge.
- **UI parity is feature-level, not pixel-level.** SwiftUI Charts vs Compose Canvas legitimately
  differ; the *behavior* and the *data* must not.
- **Cross-platform hashes/dedup keys must use a platform-neutral algorithm** (e.g. FNV-1a over UTF-16
  code units) — never `hashValue` (Swift randomizes it) or Kotlin `hashCode` if the value crosses the
  `.noopbak` boundary.
- **The `.noopbak` backup whitelist is a byte-identical contract.** `BackupSettings.swift`
  (`Packages/WhoopStore`) and `BackupSettingsCodec` (`android/…/data/BackupSettings.kt`) must carry
  the same canonical keys + JSON kinds. Only Int/Double/String cross the wire — no dates/objects.
- **Room (Android) and GRDB (iOS) migrations must agree** on the resulting schema. Column order in a
  Room `CREATE TABLE` must match the entity field order; pin migrations with tests.

## Build, test & CI — and what actually validates your change

**This is the part people get wrong.** Know exactly what covers your change before you claim it works.

### Prerequisites (toolchain & packages)
Versions are pinned by the repo — install these before the loops below:
- **JDK 17** — Android + Gradle (`sourceCompatibility`/`jvmTarget` are 17 in `android/app/build.gradle.kts`).
  Gradle **8.7** is provisioned by `android/gradlew`; don't install a system Gradle.
- **Android SDK** — `platform-tools`, `platforms;android-34`, `build-tools;34.0.0` (match `compileSdk` /
  build-tools in `android/app/build.gradle.kts`). Point Gradle at it via `android/local.properties`
  (`sdk.dir=…`, gitignored) or `$ANDROID_HOME`.
- **Swift toolchain ≥ 5.9** — the pure packages declare `swift-tools-version: 5.9`; a 6.x toolchain builds
  them. On **macOS** this ships with Xcode (also required for the app targets); on **Linux** use a
  swift.org toolchain.
- **Linux system packages** (a swift.org toolchain tarball does not bundle its build/runtime deps):
  `build-essential libc6-dev` — the C runtime / crt objects the linker needs; without them `swift build`
  fails at link with `cannot find Scrt1.o … -lc`. Plus `libncurses-dev libxml2 libcurl4 zlib1g-dev
  libedit2 pkg-config unzip`.
- **Android build-tools on non-x86-64 Linux (e.g. arm64):** Google ships `aapt2` / `d8` as **x86-64 only**,
  so resource processing dies with `aapt2 … Syntax error` / `Exec format error` on an arm64 host unless x86
  emulation is present — install `qemu-user-static binfmt-support` and the kernel runs them transparently.
  macOS and x86-64 Linux are unaffected.

### Fast local loops
```bash
# Swift packages (fastest; no Xcode, no strap):
cd Packages/WhoopProtocol && swift build && swift test     # also OuraProtocol
# Android JVM unit tests (run on Linux/macOS, no device):
cd android && ./gradlew testFullDebugUnitTest              # add --tests "com.noop.…" to filter
cd android && ./gradlew compileFullDebugKotlin             # compile the whole app module
# macOS app (needs Xcode on macOS):
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

### What each CI job covers — and the gaps
| Workflow | Covers | Runner | Trigger |
|---|---|---|---|
| `swift-packages.yml` | `swift test` for **`Packages/**` only** (WhoopProtocol, WhoopStore, StrandAnalytics, StrandImport, StrandDesign, NoopLocalAccess) | macos-15 | **automatic** — PR + push touching `Packages/**` |
| `app-build.yml` | Compile of the **app targets** (`Strand` macOS + `NOOPiOS` iOS) **plus `xcodebuild … test` (`StrandTests`) on the macOS leg only**. iOS leg needs **macos-26** (iOS 26 SDK / `glassEffect`). | macos-15 / macos-26 | **DISABLED at the GitHub level** (`disabled_manually`) — effectively `workflow_dispatch`-only. Its `pull_request`/`push` triggers are in the file but inert while the workflow is off. |
| `android.yml` | `assembleFullDebug` + `testFullDebugUnitTest` | ubuntu | **automatic** — PR + push touching `android/**`; also `workflow_dispatch` |
| `i18n-coverage.yml` | String/localization audit (EN/DE/FR/ES completeness) | — | **automatic** — every PR, and every push to `main` (so a release pushed straight to `main` is still audited, not just PRs) |
| `sync-upstream.yml` | Pulls upstream `ryanbr/noop` and opens a sync PR | — | weekly cron (Monday 06:00 UTC) + `workflow_dispatch` |
| `fork-testing-build.yml` / `fork-release.yml` | Staging / release builds (apk + mac + ios) | — | `workflow_dispatch` only |

**Read a workflow's trigger from `gh workflow list`, never from its `on:` block alone.** A workflow
disabled in GitHub's UI keeps its `pull_request`/`push` triggers in the file while running for
nobody, and nothing in the repo shows it. `app-build.yml` is in exactly that state — off since
2026-07-21, matching `docs/CONTRIBUTING.md`'s "disabled by design, you build the app yourself".
`android.yml` **is** live, path-filtered CI.

**What that costs: `StrandTests` runs nowhere automatically.** `app-build.yml` is its only home
(added #607, 2026-07-19), so while that workflow is off, app-target logic tests are only as good as
the last person who ran them by hand. A real case: `CoachMemoryDedupTests` was broken on 2026-07-28
by a deliberate `pinnedBlock` change and stayed red on `main` for days, unnoticed. **If you touch
app-target Swift that no `Packages/**` test covers — anything under `Strand/AI/`, `Strand/Data/`,
`Strand/Screens/` — run `xcodebuild -scheme Strand -destination 'platform=macOS' … test` locally, or
dispatch `app-build.yml`. Nothing else will.** Better still, put new pure logic in `Packages/` where
`swift-packages.yml` gates it automatically.

The compile gap is narrower than "no CI at all": a change your local (likely newer) Xcode tolerates
but CI's pinned runner doesn't can still slip through — see "Lessons from the fold-in" in
[`docs/IOS.md`](docs/IOS.md) for a concrete case (a `String?` interpolated into a `LocalizedStringKey`
that a bleeding-edge local Xcode silently accepted and the CI runner correctly rejected). Build the
app yourself for anything non-trivial in `Strand/`/`StrandiOS*/` rather than relying on the git-push
color alone.

### Local walls (things that will *not* build where you expect)
- **On Linux:** only `WhoopProtocol` / `OuraProtocol` (pure) build & test. Every GRDB-linked package —
  `WhoopStore`, `StrandImport`, `StrandAnalytics` (via `WhoopStore`), and `NoopLocalAccess` — fails with
  `sqlite3.h not found` (GRDB's CSQLite), and `StrandDesign` needs SwiftUI — all need **macOS**. Android
  JVM unit tests **do** run on Linux.
- **App targets** (`Strand`, `NOOPiOS`) need **Xcode on macOS**; there is no Linux/CI unit-test target
  for them (`StrandTests` runs only under `xcodebuild … test` on macOS).
- **BLE behavior cannot be CI- or Linux-tested.** Anything on the CoreBluetooth / offload / live-HR
  path (`Strand/BLE`, `Strand/Collect`, Android `com.noop.ble`) must be **validated on a real strap**;
  compile-success proves nothing about connection behavior. Say what you tested on hardware.

## Hard rules before you touch these areas

- **BLE (read [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) §BLE safety contract first):** never add
  destructive/write commands to hardware; CRC-gate every inbound frame; keep the connection path
  stable; no hardcoded hex frame bytes in app code — protocol facts live in the decoders/schema.
- **Device / strap model resolution:** map a registry `model` label to a family through the ONE
  canonical resolver (`DeviceFamily.forRegistryModel` on both platforms), never a scattered
  string compare — the wizard stores `"4.0"`, other paths `"WHOOP 4.0"`, and single-spelling checks
  silently miss straps. Reads must thread the registry's **active** strap id, not a raw BLE address.
- **Design system is law:** UI uses only design tokens — `StrandPalette` / `StrandFont` / shared
  components on Apple, `Palette` / `Metrics` on Android. No hardcoded colors, fonts, or spacing.
- **Migrations:** add a versioned migration + a test; never mutate an existing migration. Watch for
  data-loss traps (window-wide deletes, backfill rewrites) — prefer additive/transactional changes.
- **Deriving a physiological signal from raw sensor data — validate against the artifact, not one
  match:** the WHOOP optical/motion buffers are fixed-N-samples-per-record, so autocorrelation/spectral
  methods can manufacture a peak at the record period that *looks* physiological and coincidentally
  matches the WHOOP app on a stable night — that's why the PPG→HR estimate (#194) was withdrawn. A
  single "matched WHOOP" night is **not** validation. Prove the method **tracks a varying input**
  (different subjects, or nights where the true value moves; for synthetic tests, recover *multiple*
  injected values, not one). Until it does, land it as **instrumentation** (decode + store + log the
  estimate beside the incumbent) or behind a **default-off Experimental toggle** — never make it the
  default or feed it a downstream gate (recovery, illness) on thin evidence. (WHOOP 4.0 motion is
  separately too sparse to reliably stage sleep or tell in-bed from out-of-bed — see #345.)

## iOS / Android specifics worth knowing

- **iOS is `NOOPiOS`**, not `Strand`. `ContentView`/`RootView` (the macOS sidebar) are excluded from
  iOS; the iOS shell is `RootTabView`. A file shared with macOS (`TodayView`, `Repository`, analytics)
  must keep compiling for **both** — check the `Strand` (macOS) build too when you edit shared files.
- **Android** is Compose + Room, flavors `Full` (real) and `Demo`. Profile/prefs live in
  SharedPreferences; the DB is Room. UI state uses a `mutate {}` recomposition-counter idiom in places.
- iOS/macOS deployment targets: macOS 13.0, iOS 17.0 (see `project.yml`).

## Documentation & session workflow

Read this before touching docs, proposing an architecture/feature change, or ending a session
mid-task.

### Source-of-truth precedence

When two sources disagree, higher wins:

1. **Source code** — the current implementation; ground truth for what the system actually does.
2. **`docs/decisions.md`** — architectural intent and rationale (the "why").
3. **Topic documentation** — `docs/FEATURES.md`, `docs/ARCHITECTURE.md`, and the rest of the map below.
4. **This file** — the working guide.
5. **Session handoff** — `.claude/handoff/<branch>.md`.
6. **Chat context** — anything that exists only in the current conversation.

A doc's claim about current behavior that conflicts with the source is wrong until proven otherwise
— trust the code and fix the doc; don't silently prefer one without flagging the conflict (the CI
table above is a real example: it claimed two workflows were disabled when the workflow files show
otherwise).

### Documentation map

`docs/` holds NOOP's full documentation set — far more than the three links at the top of this file.
Core docs, worth reading whenever your change touches their area:

| Doc | Covers |
|---|---|
| `docs/ARCHITECTURE.md` | Module map — how the packages and app layers fit together |
| `docs/FEATURES.md` | User-facing behavior — what the app does today |
| `docs/COACH.md` | The AI coach's design and tools |
| `docs/DATA_MODEL.md` | On-device SQLite schema, migrations |
| `docs/PROTOCOL.md` | WHOOP BLE wire protocol |
| `docs/ANALYTICS.md` | Recovery / strain / sleep scoring math |
| `docs/CROSS_PLATFORM.md` | Shared-code boundary across clients — predates the 2026-07-23 parity-retirement decision, see `docs/decisions.md` |
| `docs/decisions.md` | Project memory — see below |

Everything else, grouped by topic (read the specific file when your change touches it — no per-file
blurb here, that's what goes stale):
- **Protocol/BLE detail:** `BLE_REVERSE_ENGINEERING.md`, `OURA_PROTOCOL.md`, `WHOOP5_DEEP_DATA.md`
- **Scoring detail:** `FITNESS_AGE.md`, `RR-OPTIMIZATION.md`
- **Device support:** `DEVICE_SUPPORT_ROADMAP.md`, `DEVICE_DRIVER_ARCHITECTURE.md`
- **Platform:** `ANDROID.md` — predates the Android-retirement decision, see `docs/decisions.md`
- **Ops/trust:** `PRIVACY_SECURITY.md`, `SAFEGUARDS.md`, `HOMEBREW.md`
- **Reference:** `LIBRARY.md`, `DETAILS.md`
- **In-flight design:** `redesign-briefing.md`, `superpowers/{plans,specs}`

When you add a new doc under `docs/`, file it into the matching group above (or add a new group) in
the same change — this map stays current because whoever adds a doc updates it, not because of a
separate maintenance pass.

### Working with docs

1. **Read before proposing.** Before proposing an architecture or feature change, read the relevant
   doc(s) above — at minimum `docs/ARCHITECTURE.md` and/or `docs/FEATURES.md` for anything touching
   app structure or user-facing behavior.
2. **Classify a new feature before building it.** Determine whether it extends an existing feature,
   replaces one, or is genuinely new, and update `docs/FEATURES.md` accordingly before writing any
   other documentation — this is what keeps `FEATURES.md` permanently current instead of drifting
   behind what's shipped.
3. **Infer from code when docs are silent, and say so.** State the inference explicitly as an
   assumption (e.g. "Assumption: X, inferred from `Y.swift:Z`, not documented") rather than
   presenting a guess as documented fact.
4. **Never fork a second source of truth.** Before creating a new doc file, search for one that
   already covers the topic (the map above, or a repo-wide grep) and extend/refactor it instead.
   This is why NOOP has no separate `PROJECT_MEMORY.md` — see below.
5. **Clean up while you're in there.** When editing a doc, remove or clearly mark deprecated
   anything the change makes obsolete or duplicated — don't just add the new and leave the old
   standing.
6. **Optimize for token efficiency.** Read only the docs relevant to the task; expand into source
   only when a doc is missing, outdated, or ambiguous. Avoid repo-wide scans unless the task
   actually needs one.
7. **Promote durable decisions out of ephemeral spaces.** A handoff file or a chat is never the
   permanent record — once a decision is settled, it belongs in `docs/decisions.md` or the relevant
   topic doc.
8. **Check cross-doc consistency after a merge.** Verify `FEATURES.md`, `ARCHITECTURE.md`,
   `decisions.md`, and this file stayed consistent with what just merged, and fix whichever drifted,
   in the same PR when practical.

### Project memory vs. session handoff

Two different lifetimes, two different places — don't mix them:

| | `docs/decisions.md` (project memory) | `.claude/handoff/<branch>.md` (session handoff) |
|---|---|---|
| Lifetime | Forever | One branch |
| Holds | Architecture choices and why, ideas deliberately rejected, known tech debt, planned future stages | In-progress state for resuming *this specific* branch |
| Tracked in git | Yes | No — git-ignored |
| Read when | Asking "why is X built this way" or "what's worth improving" | Resuming work on this branch |

`docs/decisions.md` already exists as a dated decision log — its stated purpose ("so a question
settled once isn't re-litigated later") is project-wide, not redesign-only; its current all-redesign
entries are a starting point, not a boundary. There is deliberately no separate `PROJECT_MEMORY.md`
or `ENGINEERING_HISTORY.md` file — see rule 4 above.

### Session handoff — branch-scoped, git-ignored

Location: `.claude/handoff/<branch-slug>.md` (sanitize `/` → `-` from
`git rev-parse --abbrev-ref HEAD`), one file per branch. Per-branch rather than a single shared file
because this repo runs many parallel worktrees (`.claude/worktrees/*`) and branches at once — a
shared file would overwrite itself the moment two are in flight. Both `.claude/worktrees/` and
`.claude/handoff/` are in the tracked `.gitignore` (not local excludes), so the ignore behaves the
same for every account and every clone.

**Write or update one before switching Claude Code accounts or sessions mid-task**, using this
template:

```markdown
# Handoff — <branch>

**Branch:** <branch-slug>
**Goal:** <what this branch is trying to accomplish>
**Current status:** <where things stand, one or two lines>

## Done
- <completed step>

## Open TODOs
- <remaining step>

## Architecture decisions (this session, not yet in docs/decisions.md)
- <decision + why>

## Known risks
- <anything risky, untested, or fragile introduced this session>

## Next step
<the single concrete next action>

## Doc references
- <docs/*.md files this branch depends on or should reconcile with>
```

- **Read it first** when resuming a branch that has one — it's the fastest way back to full context.
- **It's temporary.** Scoped to the branch's lifetime, never a substitute for `docs/decisions.md` or
  a topic doc.
- **Promote and discard on merge.** When the branch merges, move anything in "Architecture decisions"
  / "Known risks" into `docs/decisions.md` or the relevant topic doc, in the same PR if practical;
  the handoff file itself is git-ignored and simply dies with the branch.

## PR & commit conventions

- **One concern per PR.** Keep a protocol change, a schema migration, and a UI change separate.
- **Show your verification.** BLE → what you tested on hardware. Analytics → the method + a test.
  UI → confirms design tokens only. App-target Swift → that you compiled the app (CI won't).
- **Keep generated artifacts out of git** (`Strand.xcodeproj/`, `build/`, `.build/`, `*.app`,
  DerivedData). Commit `project.yml`, not the generated project. `Package.resolved` is fine.
- **Cross-platform:** if the change applies to both platforms, do both (or say why not).
- **Versioning (SemVer):** bump `MARKETING_VERSION` in `project.yml` **and** `versionName` in
  `android/app/build.gradle.kts` together; build numbers increment independently. The parts are
  counters, not decimals (`2.0.10` follows `2.0.9`).
- **Voice:** docs/comments are neutral, third-person, project-voice. Keep upstream credits intact.
- **Release-note credits use GitHub handles (#736).** In a release's contributor section, credit
  **third-party** work by `@handle`, not by display name — a plain name is invisible to GitHub, so it
  neither notifies the contributor nor links to their profile. A display name may accompany the handle,
  but the handle is what makes the credit real: `Thanks to @tigercraft4 (Sleep/Health refactors),
  @digitalerdude (workout backfill), …`.
  - Credit both **merged PR authors** and the **issue reporters** whose reports drove a fix — a good bug
    report with a strap log is often the harder half.
  - **Only third-party contributors.** The maintainer's own handles (`@ryanbr` / `@Fanboynz`) are left
    out: self-credit adds noise and self-mentions notify nobody.
  - Collect the handles with **`Tools/release-contributors.sh <since-date|since-tag>`**, which lists every
    third-party merged PR and every issue *closed as completed* in the range, plus a ready credit line,
    with the maintainer's own handles and bot accounts filtered out. A tag argument is bounded at that
    tag's exact instant, so the previous release's work is not re-credited. Writing *what* each person
    contributed is still by hand — that's the judgement part; hunting logins is not. Its output is a work
    list to prune, not a finished line: a reporter whose issue is not worth calling out in the notes can
    be left to the closing "everyone who filed the reports behind these fixes". `Tools/release.sh` warns
    when the notes it is about to publish credit no `@handle`.

When in doubt, open an issue to coordinate first, and prefer the smallest change that's correct and
covered by a test that runs without a strap.

## Redesign (in progress)

An iOS/macOS-focused redesign is underway. Full specs: [`docs/redesign-briefing.md`](docs/redesign-briefing.md);
visual reference (binding when text and image disagree): [`docs/design/mockup-today.html`](docs/design/mockup-today.html);
durable decision log: [`docs/decisions.md`](docs/decisions.md), which supersedes
[`docs/redesign-prompts.md`](docs/redesign-prompts.md) (the original handoff doc, kept only for its
screen specs) wherever the two conflict.

**Strategy — evolve in place, do NOT fork parallel screens.** The screens are shared `Strand/` code and
`StrandDesign` is already fork-owned, so the redesign edits the existing screens and Palette rather than
adding parallel files under `StrandiOS/Redesign/`. Re-theming is done by changing values behind the frozen
`StrandPalette` token API (≈3,170 call sites update for free) — never hardcode hex at a call site.

**Design rules:**
1. One value, one place. Each metric appears once per screen. If it's in a ring on top, it's not also a tile.
2. No empty tiles. Without data, render nothing — no "—", no placeholder.
3. Colour codes family via the "Signature" `ChartStyle` (green Charge, blue Effort, violet Rest, gold
   long-term). Colour only re-skins data encodings (rings/charts/scales), never chrome/surfaces.
4. Size codes importance. Exactly one element per screen is clearly the largest.
5. Tabs are places, not actions. The coach hangs on content (tile/detail), not a tab.
6. Units are small, in a secondary colour, exactly once per value. All numbers use `.monospacedDigit()`.
7. All trend charts go through Swift Charts.
8. iOS 26 Liquid Glass (`glassEffect`, `.navigationTransition(.zoom)`, Material) is the design language.

**Localization:** EN is the source locale; DE, FR, ES are kept complete. New strings ship with all four.
## Heute-Screen-Redesign

Additiv, siehe Fork-Regel oben: neue Screens unter StrandiOS/Redesign/,
Upstream-Dateien bleiben unangetastet.

Zwei getrennte Spezifikationen:
- docs/feature-spec.md   — was der Screen tut (Zustände, Daten, Persistenz)
- docs/design/design-spec.md — wie er aussieht (Farben, Abstände, Animation)
- docs/design/mockup-heute.html — verbindliche visuelle Referenz bei Widerspruch

Bei jeder Änderung: erst klären, ob es sich um Verhalten oder Optik handelt,
und in der jeweils richtigen Spec-Datei nachschlagen bzw. sie aktualisieren.
Vermischt euch beides nicht in derselben Swift-Datei, wo es sich vermeiden lässt.
```

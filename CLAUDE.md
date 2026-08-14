# CLAUDE.md — working on NOOP

Guidance for anyone (human or AI agent) submitting a pull request. This is the high-signal map;
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) is the full guide (BLE safety contract, design-system
rules, add-a-metric/screen/command recipes), [`docs/BUILD.md`](docs/BUILD.md) covers signing/pairing,
and [`docs/IOS.md`](docs/IOS.md) covers the iOS target. Read this first; follow the links for depth.

**Working in the DX23876 fork?** Everything above still applies; the fork's own rules — what it
diverges from upstream on, its commit conventions and its documentation workflow — live in
[`docs/FORK_GUIDE.md`](docs/FORK_GUIDE.md). Read that too before your first change here.

## What NOOP is (and the hard scope limits)

NOOP is a **fully offline, on-device** companion app for WHOOP 4.0 and 5.0/MG straps (with
**experimental** Oura support in the tree — gated behind `ExperimentalBrand`, not a shipped supported
strap). It pairs over Bluetooth, stores everything in on-device SQLite, and computes recovery / strain
/ HRV / sleep locally. There is **no server, no account, no cloud sync, no telemetry**, and the project stays
**anonymous** (build-from-source / sideload, not via the App Store).

These are hard constraints, not preferences. A PR is out of scope if it:
- adds a server, account, cloud sync, or sends any data off-device;
- adds analytics/telemetry/crash-reporting that phones home;
- adds WHOOP firmware, decompiled app code, logos/assets, or any DRM circumvention. NOOP is
  **clean-room interoperability** with hardware the user owns — keep it that way. (That bars
  *implementations* and literals, not every fact learned from one: a protocol offset may be
  re-derived with attribution as an unvalidated candidate — see the "facts vs code" bullet in
  [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) before telling a contributor no.)

Licensing: by opening a PR you agree your contribution is under the repo's
[PolyForm Noncommercial 1.0.0](LICENSE) license.

## Architecture at a glance

Core logic lives in **shared Swift packages**; each app target is a thin layer over them.
The **macOS app is the reference implementation**; **iOS is a build-from-source target** folded into
the same repo.

> **This fork is Apple-only.** Upstream ryanbr/noop also ships a full Android app under `android/`;
> this fork removed it, because nobody here develops it and a tree nobody builds only rots. Two
> consequences worth knowing before you touch anything: an upstream sync will try to reintroduce
> `android/` (see [`docs/FORK_GUIDE.md`](docs/FORK_GUIDE.md)), and the cross-platform parity contract
> that used to be this file's #1 rule no longer applies — see below.

| Layer | Path | What lives here |
|---|---|---|
| Protocol (pure) | `Packages/WhoopProtocol`, `Packages/OuraProtocol` | BLE frame parse, CRC, command/event/packet decode. **No CoreBluetooth.** Builds on Linux; also builds the `whoop-decode` CLI. |
| Storage | `Packages/WhoopStore` | GRDB/SQLite persistence: migrations, streams, caches. |
| Analytics (pure) | `Packages/StrandAnalytics` | HRV / recovery / strain / sleep / correlation math. Database-free. |
| Import | `Packages/StrandImport` | WHOOP CSV + Apple Health importers. |
| Design system | `Packages/StrandDesign` | SwiftUI palette / components / charts. |
| macOS + shared app | `Strand/` (scheme **Strand**, product `NOOP`, macOS 13+) | `BLE/` (CoreBluetooth), `Collect/`, `Data/` (Repository), `Screens/`, `App/` (`RootView`/`ContentView` = sidebar shell). Shared with iOS where a file isn't macOS-only. |
| iOS-only app | `StrandiOS/` (scheme **NOOPiOS**, iOS 17+), `StrandiOSShared/`, `StrandiOSWidgets/`, `NOOPWatch*` | `StrandiOSApp` (@main), `RootTabView` (the iOS tab shell — no macOS analogue), iOS widgets, watch app. |

`project.yml` is the **XcodeGen source of truth**; `Strand.xcodeproj/` is generated — never hand-edit
or commit it. Re-run `xcodegen generate` after adding/removing files or editing `project.yml`.

**Where new code goes:** the more "wire-level" (bytes) or "math-level" a change is, the deeper into
`Packages/` it belongs — and the more it must be covered by a `swift test` that runs with no app, no
strap, no CoreBluetooth. Never add `import AppKit` / `import UIKit` / `import CoreBluetooth` under
`Packages/`; guard framework code with `#if canImport(AppKit)` / `#elseif canImport(UIKit)`.

## What replaced the parity contract

Upstream's #1 rule was that Swift and Kotlin must produce byte-identical analytics and stored data.
With `android/` gone from this fork there is no Kotlin twin to agree with, so **that rule no longer
binds here.** Do not go looking for an Android file to change in the same PR; there isn't one.

Two things it protected are NOT about Android, and still hold:

- **`.noopbak` is a stability contract, not a parity one.** `BackupSettings.swift`
  (`Packages/WhoopStore`) defines the canonical keys + JSON kinds. Only Int/Double/String cross the
  wire — no dates/objects. A backup written by an older build (or by upstream's Android app, which
  users may still be migrating from) has to keep restoring, so keys are additive: never rename or
  repurpose one.
- **Anything crossing the `.noopbak` boundary needs a platform-neutral hash** (e.g. FNV-1a over
  UTF-16 code units) — never `hashValue`, which Swift randomizes per process. That was never really
  about Kotlin: a randomized hash is unstable across two runs of the *same* app.

**Merging upstream:** ryanbr's tree still carries `android/`, and a sync will try to reintroduce it.
Drop it wholesale (`git rm -r --cached android`) rather than resolving those conflicts file by file
— see [`docs/FORK_GUIDE.md`](docs/FORK_GUIDE.md). An upstream change to a Swift analytics file whose
Kotlin twin also changed is still worth reading for intent: their Kotlin diff often explains what
the Swift one is doing.

## Build, test & CI — and what actually validates your change

**This is the part people get wrong.** Know exactly what covers your change before you claim it works.

### Prerequisites (toolchain & packages)
Versions are pinned by the repo — install these before the loops below:
- **Swift toolchain ≥ 5.9** — the pure packages declare `swift-tools-version: 5.9`; a 6.x toolchain builds
  them. On **macOS** this ships with Xcode (also required for the app targets); on **Linux** use a
  swift.org toolchain.
- **Linux system packages** (a swift.org toolchain tarball does not bundle its build/runtime deps):
  `build-essential libc6-dev` — the C runtime / crt objects the linker needs; without them `swift build`
  fails at link with `cannot find Scrt1.o … -lc`. Plus `libncurses-dev libxml2 libcurl4 zlib1g-dev
  libedit2 pkg-config unzip`.

### Fast local loops
```bash
# Swift packages (fastest; no Xcode, no strap):
cd Packages/WhoopProtocol && swift build && swift test     # also OuraProtocol
# macOS app (needs Xcode on macOS):
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

### What each CI job covers — and the gaps
| Workflow | Covers | Runner | Default state |
|---|---|---|---|
| `swift-packages.yml` | `swift test` for **`Packages/**` only** (WhoopProtocol, WhoopStore, StrandAnalytics, StrandImport, StrandDesign, NoopLocalAccess) | macos-15 | **active** |
| `app-build.yml` | **Compile-only** of the **app targets** (`Strand` macOS + `NOOPiOS` iOS). iOS leg needs **macos-26** (iOS 26 SDK / `glassEffect`). | macos-15 / macos-26 | **disabled** (on-demand) |
| `fork-testing-build.yml` / `fork-release.yml` | Staging / release builds (mac + ios) | — | on dispatch |

**The trap:** `swift-packages` does **NOT** compile the app targets. So if you touch **app-target
Swift** — anything under `Strand/`, `StrandiOS/`, `StrandiOSShared/`, `StrandiOSWidgets/` (Views,
`AppModel`, `BLEManager`, `Repository`, `RootTabView`, widget publish, …) — **no default CI validates
it**, because `app-build.yml` is disabled. A compile error there (e.g. `'self' used before all stored
properties are initialized`) will pass every green check and still be broken. If you change app-target
Swift, you MUST build the app yourself: `xcodebuild … build` locally, or run `app-build.yml` on demand.

### Local walls (things that will *not* build where you expect)
- **On Linux:** only `WhoopProtocol` / `OuraProtocol` (pure) build & test. Every GRDB-linked package —
  `WhoopStore`, `StrandImport`, `StrandAnalytics` (via `WhoopStore`), and `NoopLocalAccess` — fails with
  `sqlite3.h not found` (GRDB's CSQLite), and `StrandDesign` needs SwiftUI — all need **macOS**.
- **App targets** (`Strand`, `NOOPiOS`) need **Xcode on macOS**; there is no Linux/CI unit-test target
  for them (`StrandTests` runs only under `xcodebuild … test` on macOS).
- **BLE behavior cannot be CI- or Linux-tested.** Anything on the CoreBluetooth / offload / live-HR
  path (`Strand/BLE`, `Strand/Collect`) must be **validated on a real strap**;
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
  components. No hardcoded colors, fonts, or spacing.
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

## iOS specifics worth knowing

- **iOS is `NOOPiOS`**, not `Strand`. `ContentView`/`RootView` (the macOS sidebar) are excluded from
  iOS; the iOS shell is `RootTabView`. A file shared with macOS (`TodayView`, `Repository`, analytics)
  must keep compiling for **both** — check the `Strand` (macOS) build too when you edit shared files.
- iOS/macOS deployment targets: macOS 13.0, iOS 17.0 (see `project.yml`).

## PR & commit conventions

- **One concern per PR.** Keep a protocol change, a schema migration, and a UI change separate.
- **Show your verification.** BLE → what you tested on hardware. Analytics → the method + a test.
  UI → confirms design tokens only. App-target Swift → that you compiled the app (CI won't).
- **Keep generated artifacts out of git** (`Strand.xcodeproj/`, `build/`, `.build/`, `*.app`,
  DerivedData). Commit `project.yml`, not the generated project. `Package.resolved` is fine.
- **Versioning (SemVer):** `MARKETING_VERSION` in `project.yml` is the single source of truth — the
  release workflow reads it, and the in-app update check compares against it. Build numbers
  (`CURRENT_PROJECT_VERSION`) increment independently. The parts are counters, not decimals
  (`2.0.10` follows `2.0.9`).
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

# Android on a shared Swift core: plan

Decided 2026-10-24 · Work happens on `main` in small verified steps · Running state: [`STATUS.md`](STATUS.md)

This plan replaces the Kotlin-twin plan of 2026-10-05 (commit `ddab82a9c`, kept on the local branch
`android-restore` as an archive). It is written so that any session, on any Claude account or in Codex,
can pick up the next step without the conversation that produced it. The plan changes only when a
decision changes; progress goes into `STATUS.md`.

## 0. Picking this up

1. Read, in this order: this plan, [`STATUS.md`](STATUS.md), `CLAUDE.md`, [`../AGENT_RULES.md`](../AGENT_RULES.md),
   `docs/FORK_GUIDE.md`, the 2026-10-24 entry in [`../decisions.md`](../decisions.md).
2. Take the first open step in `STATUS.md` whose prerequisites are done. Note it under "In progress" with
   the date before starting, and update `STATUS.md` at the end of every session, also when stopping
   mid-step: done, open, next concrete action. Nothing that matters stays only in a chat.
3. Every statement in `STATUS.md` says whether it is proven (command and output, test, device) or assumed.

Rules that hold for every step:

- **iOS loses nothing.** iOS code may be restructured to make the shared core possible, but no feature
  disappears unless the owner agreed to it first. Every iOS restructuring commit records
  `Analysis migration required: no` and must leave every stored value unchanged (see B4).
- **No signing keys, passwords or tokens in the repository.** `keystore.properties` and
  `local.properties` stay git-ignored; the release key reaches CI only as a GitHub secret the owner
  creates.
- **Compiling proves nothing about Bluetooth or background behaviour.** Those stay "untested" in
  `STATUS.md` until a tester's strap log or a real device shows them.
- **No placeholder UI.** An Android screen appears only when the logic and storage behind it work.
- Big new iOS features are paused while phases A to E run; iOS bug fixes continue.
- Commit identity, attribution, privacy and git rules are those of `CLAUDE.md`, `AGENT_RULES.md` and the
  local guard hooks; this plan does not repeat or relax them.

## 1. Decisions (2026-10-24)

| ID | Decision | Why |
|---|---|---|
| D1 | Android ships for the owner and for people who come through the Forge website | The fork is used beyond one phone |
| D2 | Same core on both platforms: the same raw data gives the same numbers, and a `.noopbak` reads on both. Fork extras follow on Android by value, decided after the first testing build (D20) | Full parity would double every feature forever; no parity would leave Android with nothing of the fork |
| D3 | iPhone, Mac and Watch stay fully supported | The Mac app shares almost all code; the Watch app is small |
| D4 | No Android device for now. Testers (already available) test; the owner buys a used Pixel 8a or newer from Ko-fi money (D10) | Bluetooth can only be shown on real hardware |
| D5 | Shared Swift core through the official Swift SDK for Android, Kotlin around it. Gated by a spike (phase A); if Swift on Android fails, fall back to the Kotlin twin of the archived plan | Same numbers by construction instead of by oracle tests |
| D6 | Distribution: an APK asset in the same GitHub release as the iOS build, linked from the website, no Google developer account | Anonymity is a hard project constraint |
| D7 | Big new iOS features pause until Android has the core; fixes continue | Otherwise the core moves while Android is catching up |
| D8 | **Deep core** if SQLite through GRDB runs on Android: Swift decodes, stores, migrates, analyses and backs up; Kotlin does Bluetooth transport, Android services and UI. **Flat core** otherwise: Swift computes only, Kotlin keeps a Room database aligned to the fork schema | Deep makes schema, recipes and backups identical by construction |
| D9 | Android builds are labelled "Testing" in the app and in the release until three testers on different devices confirm pairing, live heart rate, overnight sync and reconnect, each with a strap log. Reports go through a dedicated Android issue template | Without an own device, strap logs are the only evidence |
| D10 | A device comes from Ko-fi money, bought by the owner; no shipped donations | A delivery address reveals the owner's name |
| D11 | Application id `io.github.dx23876.noop`, name "NOOP Forge". `versionName` equals `MARKETING_VERSION` in `project.yml`; `versionCode` is Android's own counter starting at 1 | No real name in a public id; installs beside ryanbr's `com.noop.whoop` |
| D12 | One release signing key, backed up twice (password manager plus an offline copy), stored as a GitHub secret by the owner; CI builds the APK like the iOS build | Android accepts updates only with the same key, forever |
| D13 | New plan on `main`; `android-restore` stays as an archive; all work lands on `main` in small verified steps with its own Android CI | A long branch drifts the way the archived one did (280 commits behind in three weeks) |
| D14 | This plan, `STATUS.md` and the decisions entry live on `main` so any account can continue | The owner may continue on another Claude account |
| D15 | First public testing build: pair, live heart rate, overnight sync, Today (Charge, Effort, Rest), sleep detail, HRV and resting heart rate trends, `.noopbak` export and import, settings, strap log export | Smallest build that shows the fork's numbers and lets testers prove Bluetooth |
| D16 | From ryanbr's Android app keep Bluetooth, pairing, permissions, the background service and the settings scaffold. Data screens are new Compose screens in the fork's design with Material 3 navigation. His features the fork solved differently (his coach, Lift Log) are dropped | His device-tested platform code is the part hardest to get right without a device |
| D17 | Keep merging `upstream/main` normally, `android/` included. Paths the fork deleted stay deleted by a fixed, scripted rule | His Bluetooth fixes arrive without hand porting |
| D18 | The iOS restructuring is checked by the full test suite on every step and, at two or three milestones, by re-analysing a copy of the owner's real database before and after: every stored value must match | Tests do not cover everything real nights contain |
| D19 | After the core move, as its own step: at most one analysis recipe per release, and a recipe bump re-scores every day that has raw strap data and rebuilds derived tables, instead of per-recipe windows | One formula for every day with raw data; the per-recipe special cases go away |
| D20 | Which extras come to Android, and in what order, is decided after the first testing build, by tester demand and by what the core already provides | Phase A shows how much the core brings for free |
| D21 | Existing testers get the first installable build; the public call (website note, pinned issue, Ko-fi for a Pixel) waits until a build installs | A call without an app sets expectations nobody controls |
| D22 | The core keeps GRDB 6.29.3 with the Android conditionals carried as a small patch (the 8 files from spike A3); the move to GRDB 7.10 or later, which ships them upstream, is its own later step | Phase B should not also carry a major-version migration of the Apple app |
| D23 | "Same numbers" (D2) means identical after display rounding; stored doubles may differ in the last bit between platforms, and a cross-platform tolerance test pins that bound | Spike A5: Bionic and Darwin libm differ by 1 to 2 ulp; a shared portable maths library would make bits identical but changes every iOS value once (a recipe bump) for no visible gain |
| D24 | An APK of about 31 MB is accepted for testing builds; a size step (ICU subset, Foundation trimming) comes before the public call (D21) | Half the size is ICU data from Foundation; testers sideload anyway |

## 2. Findings (2026-10-24)

Proven from git, the code or the toolchain unless marked as assumed.

| Topic | Finding |
|---|---|
| Removal | Commit `9c17b179b` (2026-08-14) removed 911 files. The parity contract was retired 2026-07-23. |
| Swift on Android | The first official Swift SDK for Android shipped with Swift 6.3 on 2026-03-24. It needs a swift.org toolchain whose version matches the SDK exactly; Xcode's toolchain does not qualify. SwiftUI does not run on Android; Kotlin calls Swift through swift-java (JNI with generated bindings). This Mac has Xcode's Swift 6.4 and no Swift SDK installed (`swift sdk list`). |
| Packages | About 116,000 lines in `Packages/`, almost all `Foundation` only. `WhoopProtocol`, `StrandAnalytics`, `StrandTraining`, `PolarProtocol` import no Apple framework. Apple-only spots: `Compression` in one `WhoopStore` file, `CommonCrypto` in one `OuraProtocol` file, `FoundationXML` in `StrandImport`. `StrandAnalytics` imports `WhoopStore` in 21 files, mostly for model types (3 uses of `Row`, 1 of `Database`). `StrandDesign` and `MuscleMap` are SwiftUI and stay Apple-only. |
| GRDB | Pinned to 6.29.3 in four packages. Android support is at best experimental: Swift Package Index builds of GRDB for Android failed in July 2026, and a pull request for an Android trait was open. Assumed, to verify in A3: Android's system SQLite is not part of the public NDK, so SQLite has to be bundled. A working Android build may require GRDB 7, which would be an iOS dependency upgrade of its own. |
| App-side logic | `Strand/Data` holds about 31,600 lines, `Strand/AI` about 25,500, `Strand/Screens` about 121,400. The daily analysis, `Strand/Data/IntelligenceEngine.swift` (4,791 lines), lives in the app target and imports `Combine`, which does not exist on Android. The analysis recipe is at AI-30. |
| Raw data | Strap samples (`hrSample` and peers) are not pruned; the owner's raw history starts 2026-07-13. Only the PPG waveform and v18 aux tables have a rolling retention (604,800 rows each). Days imported from Apple Health or a WHOOP export have no raw strap data and cannot be re-scored. |
| Upstream Android | `upstream/main`: `applicationId com.noop.whoop`, `versionName 12.1.0`, `versionCode 557`, compileSdk 35, minSdk 26, targetSdk 34, Room `version = 41`. Kotlin files under `com.noop` by package: ui 162, analytics 131, ble 51, protocol 36, data 30, ingest 23, widget 19, oura 19, testcentre 18, push 16, notif 12, alarm 7, ai 4, polar 3, update 2, location 2. 955 of 1,302 upstream commits since 2026-08-14 touch `android/`. ryanbr checks in `android/fork-debug.keystore` (password in `build.gradle.kts`). |
| Distribution | Google's developer verification starts 2026-09-30 in four countries and worldwide in 2027. A standard account needs a government ID; a hobbyist account needs none but reaches 20 devices; unregistered apps install through an extra advanced flow or ADB. |

## 3. Target architecture

```
Kotlin (Android)                          Swift core (shared with iOS and macOS)
----------------                          ---------------------------------------
Bluetooth transport, pairing,     frames  WhoopProtocol: CRC, frame and packet decode
permissions, foreground service  ------>  WhoopStore: SQLite, migrations, backup
Health Connect, notifications             StrandAnalytics + StrandTraining
Compose UI (Material 3, fork      <-----  daily analysis engine (moved out of Strand/Data)
Palette / Metrics tokens)         results
```

Kotlin talks to Swift through swift-java bindings. Kotlin keeps ryanbr's `ble`, `notif`, `alarm`,
`push`, `testcentre`, `update` and permission/onboarding code where the inventory (C1) shows it does not
depend on his Room database. His `data`, `analytics`, `ingest` and `protocol` packages and his data
screens are replaced by the Swift core and new screens (deep core). With a flat core, `data` stays and
is aligned to the fork schema instead.

## 4. Phases

Each step has prerequisites, an outcome and an acceptance check. A step is done when its check ran and
its evidence is in `STATUS.md`.

### Phase A: spike (one to two days, nothing lands on `main` except `STATUS.md`)

Spike code lives in a git-ignored scratch folder or a throwaway branch that is never pushed.

- **A1 Toolchain.** Install a swift.org toolchain matching a released Swift SDK for Android (6.4.x if
  available, else 6.3.x), the matching SDK (`swift sdk install`), and the Android NDK the SDK documents.
  Check: `swift sdk list` shows it; versions recorded in `STATUS.md`.
- **A2 Pure packages.** Build `WhoopProtocol` and `StrandTraining` for `aarch64-unknown-linux-android`.
  Check: build succeeds; any source change needed is listed.
- **A3 Storage.** Build `WhoopStore` with GRDB for Android with bundled SQLite. Try the pinned 6.29.3
  first, then GRDB 7 if needed. Check: on an arm64 emulator a store is created, all fork migrations run,
  a row round-trips. Pass means deep core (D8); fail means flat core, and A4 then builds `StrandAnalytics`
  with the `WhoopStore` model types split out instead.
- **A4 Analytics.** Build `StrandAnalytics` for Android.
- **A5 Call from Kotlin.** A minimal Android app calls one Charge (recovery) computation through
  swift-java with a fixed fixture input. Check: the value is bit-identical to the same call on macOS.
- **A6 Measure.** APK size with and without the Swift libraries, clean and incremental build time.
- **A7 Report.** `STATUS.md` milestone A with the four report questions (section 6). The owner decides
  on deep or flat and whether the size is acceptable before phase B starts.

### Phase B: move the core out of the iOS app (on `main`)

- **B1 Inventory.** Map `Strand/Data` and `IntelligenceEngine.swift` to what the daily pass, migrations
  and backup need, and what is UI glue. Output: a section in `STATUS.md` or `INVENTORY.md`.
- **B2 New package.** A platform-neutral package (name chosen in B1) receives the daily analysis engine
  and the repository parts it needs. `Combine` is replaced at the package boundary (for example by
  `AsyncStream` or callbacks); the app adapts on its side. Apple-only code in packages goes behind
  `#if canImport(...)`.
- **B3 Small steps.** One concern per commit. Each commit: `Tools/local-tests.sh`, macOS and iOS builds,
  `StrandTests`, `Analysis migration required: no`.
- **B4 Real-data checks** at two or three milestones: pull a copy of the owner's iPhone database (app
  closed, Bluetooth off, the known `devicectl` procedure), run the daily pass on that copy with the build
  before and after the milestone, compare every derived table. A versioned comparison tool lives under
  `Tools/`. Check: zero differing rows, output in `STATUS.md`.

### Phase C: one rule for analysis migrations (on `main`, after B)

- **C1** Replace the per-recipe windows with one rule (D19): at most one recipe bump per release; a bump
  re-scores every day with raw strap data and rebuilds derived tables (AgeLess weeks and peers);
  raw samples and user sleep and workout corrections are never touched; the run is resumable and writes
  its cursor only after success.
- **C2** Update the analysis section of `AGENT_RULES.md` and add a decisions entry. The change itself is
  a recipe bump (`Analysis migration required: yes`), described in the release notes.
- **C3** Measure the full re-score on the owner's iPhone (duration, CPU, battery) before release.

### Phase D: Android scaffolding (internal, not released)

- **D-1 Restore.** `git checkout <current merge base> -- android .github/workflows/android.yml`, then
  remove `android/fork-debug.keystore` before the commit and add it to `.gitignore`. The commit contains
  nothing else, so `git diff <merge base> HEAD -- android` shows only the keystore.
- **D-2 Identity.** Application id, app name, debug/demo/staging suffixes and version per D11. Package
  names (`com.noop.*`) stay, so upstream merges stay readable. Check: `apkanalyzer manifest application-id`.
- **D-3 Update check and links.** `UpdateCheck.kt` reads `DX23876/noop` releases and counts only those
  with an APK asset; fork links point at the fork, credits to ryanbr stay.
- **D-4 Signing.** Release signing from `keystore.properties` locally and from GitHub secrets in CI.
  The owner creates the key and the secrets; no key material enters the repository.
- **D-5 Deep-core wiring.** Remove the Kotlin packages the Swift core replaces (section 3); the Swift
  libraries are built by Gradle through the Swift SDK. Kotlin Bluetooth hands frames to the Swift
  core.
  *Sequenced on 2026-10-25:* D-5 ends with the core built into every APK, its main actor on Android's main
  thread, and a shadow session: Kotlin Bluetooth hands every frame to the core, which banks and scores them on
  its own store and logs its numbers beside Kotlin's, without sending anything to the strap. ryanbr's Kotlin
  data and analytics packages go in phase E, screen by screen, as each new screen reads from the core (E-2);
  removing them earlier would leave his screens with nothing to show.
- **D-6 Sync rule.** A versioned list of fork-deleted `android/` paths plus a resolver script under
  `Tools/`; `docs/FORK_GUIDE.md` replaces the "remove all of `android/`" sync rule with it.
- **D-7 CI and tools.** `android.yml` builds and tests on every push touching `android/**`, the core
  packages or the shared fixtures, and fails on a non-success result rather than on zero failures.
  `Tools/i18n_audit.py` and `Tools/appchangelog-gen.py` get their Android arms back, with tests.
  `Tools/local-tests.sh` and the pre-push hook learn about `android/`.
- **D-8 Emulator smoke test** of the demo flavour: launches without a crash, screenshots of the
  first screens under `artifacts/android/` (not versioned).

### Phase E: first testing build (D15)

Pairing and connection, live heart rate, overnight sync, Today (Charge, Effort, Rest), sleep detail,
HRV and resting heart rate trends, `.noopbak` export and import, settings, strap log export. Screens use
Material 3 navigation and the fork's `Palette`/`Metrics` tokens; texts in EN, DE, FR and ES at least.
Backups are proven in both directions by tests with versioned fixtures: an iOS-written `.noopbak` imports
on Android with identical rows, and the reverse.

Added 2026-10-25 after the D-8 smoke test (owner's request: the fork's design, every screen size):

- **One design source.** Colours, spacing, corner radii and the type scale live in one versioned token file
  from which both `StrandPalette`/`StrandFont` (Apple) and the Compose theme are generated, so the Android
  screens look like the iOS app (glowing rings, the Today scene, the fork's palette) and cannot drift from
  it unnoticed. iOS 26 glass becomes a blur on Android 12 and later and a plain translucent fill below.
- **Every screen size.** Layouts follow Compose window size classes: a bottom bar on compact width, a
  navigation rail and two columns from medium width (unfolded foldables, tablets), a maximum content width
  so cards do not stretch edge to edge. Text must not truncate at a font scale of 1.3, and dark mode must
  darken the whole screen, not only the cards.
- **Check.** `Tools/android-smoke.sh` on all five profiles (small phone, Pixel 8, Pixel 8 at font 1.3 in
  dark mode, unfolded Pixel 9 Pro Fold, Pixel Tablet): no crash, and the screenshots reviewed against the
  iOS screens.

Steps (added 2026-10-25), each with its own commit, test and smoke run:

- **E-1 Design tokens.** One token file under `Packages/StrandDesign` (colours light and dark, spacing,
  radii, type scale) and Kotlin constants for the Android screens, both generated; a test fails when either is
  out of date. *Done 2026-10-25, direction turned round:* the Swift design system stays the one source and
  `Tools/design_tokens.py` reads its fixed values into `tokens.json` and `ForgeTokens.kt`, because generating
  the Swift side from a new file would have touched every value the iOS app shows.
- **E-2 Core read API.** JNI calls that return what a screen needs from the core's store (today's scores, a
  night's sleep, a metric series over a window) as small JSON documents, tested on macOS through `Bridge`. *Done
  2026-10-25:* `CoreRead` in `NoopCoreJNI`, the JNI calls `readDay`, `readNights`, `readSeries` and the Kotlin
  parser `com.noop.core.CoreRead`.
- **E-3 Screens.** Today, sleep detail, HRV and resting-HR trends, settings, `.noopbak` export and import and
  strap log export as new Compose screens on the core read API and the tokens, adaptive per window size class.
  ryanbr's screens they replace, and the Kotlin data and analytics code only those screens used, go in the
  same step. In parts (added 2026-10-25): **E-3a** theme from the tokens, the Alps day-cycle scene, glass cards
  (the scene behind a card blurred on Android 12 and later), the adaptive shell (glass bar on a phone, rail from
  600 dp, content at most 720 dp wide) and the demo history in the core's store; **E-3b** Today; **E-3c** Sleep;
  **E-3d** Trends; **E-3e** More with settings, `.noopbak` export and import and strap log export; **E-3f** the
  Forge screens become the app and ryanbr's screens and the Kotlin code only they used go. Until E-3f the Forge
  screens open only when switched on (`--ez forge_ui true` on the launch intent). *E-3a to E-3e done
  2026-10-25.* Open against the iOS look: the rounded type (SF Pro Rounded is Apple's and cannot ship on
  Android), the profile and quick-action buttons in the Today header, and the hero's source label.
- **E-4 The core owns the data.** Kotlin Bluetooth stops writing Room and hands frames only to the core; the
  history ack is sent only after the core's Backfiller reports the chunk durably written (the safe-trim rule
  of the BLE safety contract), proven by a replay test and then by a tester's strap log.
- **E-5 Languages and backups.** EN, DE, FR and ES complete for the new screens; versioned `.noopbak`
  fixtures prove an iOS backup restores on Android with identical rows, and the reverse.

### Phase F: testing and release

- **F1** The release workflow attaches `NOOP-Forge-android-<version>.apk` to the same GitHub release as
  the iOS build, signed from the secret; Android builds carry the "Testing" label (D9).
- **F2** An Android issue template asks for device, Android version, strap model and firmware, and the
  strap log.
- **F3** Existing testers get the first build. Once it installs: website note, pinned issue, Ko-fi
  mention for a Pixel (D21).
- **F4** "Testing" is removed only after the D9 confirmations are recorded in `STATUS.md`.

### Phase G: extras

Decided after phase F (D20). Each extra follows the phase E pattern. Open question already known: the
coach's semantic memory uses llama.cpp (`Vendor/`), whose Android build is unverified.

## 5. Check commands

```bash
# Swift packages
cd Packages/WhoopStore && swift test
cd Packages/StrandAnalytics && swift test
# Apple app targets
xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
Tools/local-tests.sh
# Android (once phase D restored the tree), inside android/
./gradlew assembleFullDebug assembleDemoDebug testFullDebugUnitTest
```

## 6. Report per milestone

In `STATUS.md`, one section per milestone answering exactly:
1. What works, proven how (command and result, test count, screenshot path)?
2. What is missing?
3. Which checks ran?
4. What needs the owner's decision or a device?

## 7. Known risks

- **Swift on Android is young** (official since March 2026). Toolchain and SDK versions must match
  exactly; debugging crosses JNI. Phase A exists to find out early.
- **GRDB on Android** runs on 6.29.3 with an 8-file patch (spike A3, D22); every GRDB bump has to redo it
  until the GRDB 7 move.
- **Upstream syncs grow again**: every sync brings `android/` changes, and fork-deleted paths conflict
  until the D-6 resolver handles them.
- **No device**: Bluetooth and background behaviour depend on testers' strap logs until a Pixel exists.
- **Moving target**: iOS keeps changing during phases B to E; the D7 pause limits it.

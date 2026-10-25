# Android on a shared Swift core: status

Plan: [`PLAN.md`](PLAN.md) · last updated 2026-10-25

## In progress

| Step | Who | Since | Note |
|---|---|---|---|
| (free) | | | |

## Done

| Step | Date | Evidence |
|---|---|---|
| Decisions D1 to D21, plan written | 2026-10-24 | `PLAN.md` section 1, `decisions.md` entry of 2026-10-24 |
| A1 toolchain | 2026-10-24 | Swift 6.4.1 + SDK `swift-6.4.1-RELEASE_android` + NDK r30; hello world runs as arm64 ELF |
| A2 pure packages | 2026-10-24 | `WhoopProtocol`, `StrandTraining`, `OuraProtocol`, `PolarProtocol` build for Android unchanged |
| A3 storage | 2026-10-24 | `WhoopStore` suite on an arm64 emulator: 849 tests, 0 failures, 1 skip |
| A4 analytics | 2026-10-24 | `StrandAnalytics` suite on the emulator: 3,157 tests, 4 failures, all four "repo file not found" |
| A5 call from Kotlin | 2026-10-24 | Kotlin app calls Charge 20,000 times through JNI and opens a store with all 78 migrations |
| A6 measure | 2026-10-24 | APK and build-time figures in milestone A below |
| A7 report | 2026-10-24 | Milestone A below |
| Owner decisions after A | 2026-10-24 | D22 to D24 in `PLAN.md`: patched GRDB 6.29.3, display-rounding equality, 31 MB accepted |
| B1 inventory | 2026-10-24 | [`INVENTORY.md`](INVENTORY.md): dependencies of the pass, cut, package name `StrandCore`, seven-step order |
| B3 step 1: empty `StrandCore` | 2026-10-24 | Package in `project.yml` (macOS and iOS app) and the package CI matrix; its link test passes on macOS and on the arm64 emulator |
| B3 step 2: pure helpers | 2026-10-24 | `StressMath`, `AnalysisRecipe` and `DayCycleIntelligenceIntegration` in `StrandCore`; 33 package tests pass on macOS and on the emulator; `local-tests.sh` passed |
| B3 step 3: `AnalysisSettings` and `AnalysisHost` | 2026-10-24 | The pass reads one settings snapshot and reports through the host; `AppAnalysisHost` keeps every key and type; 35 package tests on macOS and the emulator; `local-tests.sh` passed |
| Real-data check 1 (B4) | 2026-10-24 | Owner's iPhone store (4.2 GB, newest day 2026-10-24) re-analysed over 21 days by `d21690770` and by `ff34ef571`: 0 of 78 tables differ (77 identical by hash, `scoreInputProvenance` identical in another row order) |
| B3 step 4, part 1: metric and steps resolvers | 2026-10-24 | `MetricResolver` in `StrandCore` with three store-backed tests; 38 package tests pass on macOS and the emulator; `local-tests.sh` passed |
| B3 step 4, part 2: `WorkoutSource` and `WorkoutCatalog` | 2026-10-24 | In `StrandCore`, translated names left in the app; 37 of 48 workout tests moved; 75 package tests pass on macOS and the emulator; `local-tests.sh` passed |
| B3 step 4, part 3: union reads and data computations | 2026-10-24 | `StoreReader` (the active-strap, registered-strap and canonical union), training session fusion and read, native projection, workout heart rate fills, cardio load pricing, VO2max session parts, weight and body metric reads, the energy model refresh; 131 package tests pass on macOS and the emulator; `local-tests.sh` passed |
| B3 step 5: the daily analysis in `StrandCore` | 2026-10-24 | `DailyAnalysis` (the former engine, 4,800 lines) with `AnalysisDataServices` and `AnalysisProfileSource`; the app keeps `IntelligenceEngine` as a typealias with SwiftUI observation, translated text and the two conformances; a whole pass runs in the package tests on macOS and on the emulator (132 tests); `local-tests.sh` passed |
| Real-data check 2 (B4) | 2026-10-24 | The same iPhone store re-analysed over 21 days by `d21690770` and by `d9da3d411` (engine in `StrandCore`): 0 of 78 tables differ with write-time columns left out (`--ignore-column '*.computedAtTs' --ignore-column '*.updatedAtTs'`). A first attempt differed in 4 cardio ledger rows, traced to the readiness pass that a dashboard refresh starts in the background finishing in one run and not the other; the snapshot test now runs it to completion |
| B3 step 6: the backup format in `StrandCore` | 2026-10-24 | `BackupArchive` writes, verifies and restores a `.noopbak` (zip layout, manifest, origin check, restore with the previous store kept beside it); the app keeps the pickers, translated failures and the journal and goals settings; three new package tests write, verify and restore a store on macOS and the emulator; `local-tests.sh` passed |
| B3 step 7: raw collection in `StrandCore` | 2026-10-24 | `Collector`, `Backfiller`, `RawHistoryArchive`, clock correlation and policies; the IMU session files and the raw data session store stay in the app behind a frame tap, the sub-lag switch arrives as a closure; the raw outbox compiles out without Compression; seven collection test files moved, 211 package tests pass on macOS and on the emulator (1 iOS-only skip); `local-tests.sh` passed |
| Real-data check 3 (B4) | 2026-10-25 | A fresh copy of the iPhone store (pulled 2026-10-24, now kept as the standing copy) re-analysed over 21 days by `d21690770` and by `b728fda01` (backup and raw collection in `StrandCore`): 0 of 78 tables differ with write-time columns left out. On the external disk a run takes about 10 minutes instead of 3, and the first run waits for macOS's removable-volume permission |
| Phase B complete | 2026-10-25 | Steps B1 to B4 above |
| C1 one rule for analysis migrations | 2026-10-25 | Recipe AI-31: every bump runs `AnalysisRecipe.RebuildStep` (all days with raw strap data, weekly scores, stress proxy, rhythm days, workout heart rate, cardio ledger, energy history, AgeLess weeks), resumable per step, recipe cursor last; package tests for the order, the resume and the stress rebuild pass on macOS and the emulator. On a copy of the owner's store (104 raw days) the rebuild took about 13 minutes on a Mac, two runs left identical tables (0 of 78 differ) and no raw table changed; edited nights kept bed and wake times, workouts only gained missing heart rate |
| C2 rules and decision | 2026-10-25 | `AGENT_RULES.md` analysis section, `decisions.md` entry of 2026-10-25, release notes section after 12.2.1 |
| C3 measured on the owner's iPhone | 2026-10-25 | iPhone 13 Pro Max, Release build of `c93bba06d`, 105 days of raw history, app in the foreground off the charger: the rebuild took 451 s with 515 s of CPU, battery 55 % to 50 %; the daily step was 400 s of that, energy 32 s, rhythm days 16 s, everything else under 3 s. The daily step reached four old duplicate sleep sessions; the dedup heal's re-pass over the same window added 428 s (493 s CPU) and ran after the rebuild had finished, which `2c07ba1a5` fixed by waiting for it inside the daily step. A 21-day pass right after re-scored every day once (102 s) because the sleep traits had moved. After that a routine post-sync pass (one day re-scored, twenty reused) cost 9 to 15 s of CPU against 68 to 140 s on the build before (day cycle 41 s to 3.7 s, edited-night heal 4 s to 0.3 s), most likely because every stored day now matches the current code; two passes so far, a full day's log still to compare. Logs and the store from before the install are on the owner's backup disk |
| D-1 restore | 2026-10-25 | `android/` and `android.yml` from merge base `7a00c26be` without `fork-debug.keystore` (`748f03f1b`); the Android entries of the lint baselines restored, the Android locale map names Polish (`70ce2a966`); unit tests run in en-US and four iOS-parity tests are excluded by name (`0cd926777`). Android CI green on Linux (6,684 tests); locally the two `RecoveryDriversTest` half-tie cases fail on Apple silicon only (last-bit `exp`/`log`, D23) |
| D-2 identity | 2026-10-25 | `io.github.dx23876.noop` (+ `.debug`, `.demo`, `.staging`), "NOOP Forge" in every locale, version name read from `project.yml`'s `MARKETING_VERSION`, versionCode 1; `apkanalyzer` shows `io.github.dx23876.noop.debug 12.2.1-debug (1)` |
| D-3 update check | 2026-10-25 | Reads `DX23876/noop` releases and offers the newest published one with an APK; Settings links to the fork; four JVM tests |
| D-4 signing key | 2026-10-25 | The owner created the release key (PKCS12, RSA 4096, alias `forge`, valid to 2126, owner `CN=NOOP Forge, O=DX23876`) and stored it as `ANDROID_KEYSTORE_BASE64` and `ANDROID_KEYSTORE_PASSWORD`; the dispatch-only `android-signing-check.yml` opened it on GitHub. Certificate SHA-256 `DA:EF:49:62:50:E9:C1:05:AC:A0:0F:4B:F1:C3:36:0E:D7:B2:DC:64:04:7B:F9:A3:E3:E3:86:36:DC:DA:0F:F4`. Release signing in a workflow comes with F1 |
| D-6 sync rule | 2026-10-25 | `Tools/android_fork_deleted_paths.txt` lists the android/ paths the fork deleted; `Tools/resolve-android-merge.py` takes those deletions after an upstream merge (conflicts and new files beneath a deleted directory) and names the android/ conflicts left by hand; five tests; `docs/FORK_GUIDE.md` and `AGENT_RULES.md` describe it |
| D-7 CI and tools | 2026-10-25 | `android.yml` builds both debug flavours on every change to what the Android build or tests read (android/, `project.yml`, the shared fixtures, `Tools/parity_cases`); 14 tests that read Swift sources or the iOS catalogue are excluded by name, so an iOS change cannot turn it red later; `Tools/local-tests.sh` runs Gradle for the same inputs and the pre-push hook wants its stamp; `appchangelog-gen.py` writes the Kotlin What's New entry again (14 ported tests). `i18n_audit.py` already had its Android arm, now with Polish |
| D-8 emulator smoke test | 2026-10-25 | `Tools/android-smoke.sh` ran the demo build through terms, onboarding, Today, Trends and Sleep on a small phone (720x1280), a Pixel 8, a Pixel 8 at font 1.3 in dark mode, an unfolded Pixel 9 Pro Fold and a Pixel Tablet: no crash on any. Density scaling works; the layout does not adapt: on the fold and the tablet everything stretches to full width with a bottom bar instead of a rail, the floating bar lets the text behind it show through, the greeting and a metric title truncate on the small phone and at font 1.3, and in dark mode the background stays light blue. These are ryanbr's screens, which phase E replaces; the requirements are in `PLAN.md` phase E. Screenshots in `artifacts/android/` (not versioned) |
| D-5, first step: the core in the APK | 2026-10-25 | `Packages/NoopCoreJNI` (libNoopCore.so: JNI entry points over plain Swift functions, three macOS tests), `android/swift-core/build-swift-core.sh` (pinned SQLite, the GRDB and ZIPFoundation patches in portable Python, a release arm64 build, 20 stripped libraries), Gradle `buildSwiftCore` behind `-Pnoop.swiftCore=true`, `com.noop.core.SwiftCore`. On the arm64 emulator the app logs "recipe AI-31, store migrations 78". `android-swift-core.yml` builds both flavours with the core on Linux (NDK variables and a zlib.pc so the host's x86_64 zlib is not linked); 65 MB debug APKs. Nothing in the app reads the core yet |
| D-5, second step: the core by default | 2026-10-25 | Gradle builds the core in every build (`-Pnoop.swiftCore=false` opts out); `android.yml` installs the toolchain, the Swift SDK for Android and NDK r30 and runs on `Packages/**` too; `Tools/local-tests.sh` runs the Android leg for package changes. NDK r30 now sits in the Android SDK's standard place on the owner's Mac. Checked on the `ci/android-swift-core` branch and locally before main |
| D-5, third step: the main actor on Android | 2026-10-25 | `noop_install_main_queue_drain` (CJNI) puts libdispatch's main queue on the main looper; `SwiftCore.start` loads the core on the main thread and installs it. On the emulator: "main actor installed=0, probe jobs run=1, on main thread=true"; loaded on a background thread first, the probe had run off the main thread. A macOS test covers the probe |
| D-5, fourth step: the shadow session | 2026-10-25 | `ShadowSession` runs the core's Collector and Backfiller on its own store; the Kotlin client hands it every frame in arrival order (offload frames to the Backfiller, the rest to the Collector, plus family, clock seed and offload begin) and nothing goes back to the strap (the ack is a no-op). After each offload the strap log carries "Core shadow: core banked … | Kotlin banked …". A macOS test replays three real 4.0 history records and an END. Not yet run against a real strap |
| D-5, fifth step: the core's daily pass | 2026-10-25 | `CoreAnalysis` runs `DailyAnalysis` on the shadow store with store-only services and the app's profile; the client asks for it with each post-offload pass and logs "Core shadow analysis: day=… charge=… effort=…" two minutes later. Phase D is complete; the Kotlin data and analytics packages go screen by screen in phase E (PLAN.md, D-5 note) |
| E-1 design tokens | 2026-10-25 | `Tools/design_tokens.py` reads the Swift design system (125 colours light and dark, 76 dimensions, the iPhone type scale) into `Packages/StrandDesign/tokens.json` and generates `ForgeTokens.kt`; a test in the unfiltered tools suite fails when either is stale (`6ac11439f`) |
| E-2 core read API | 2026-10-25 | `CoreRead` in `NoopCoreJNI` answers a day, the nights in a window and a metric series as JSON, resolved as the Apple `Repository` does (imported values win field by field, the core's computed rows fill the gaps, the active strap wins); `SwiftCore.readDay/readNights/readSeries` and the Kotlin `com.noop.core.CoreRead` parser. Four macOS tests through the store; the Swift test and the Kotlin parser test pin the same day document |
| E-3a to E-3d Forge screens | 2026-10-25 | `com.noop.ui.forge`: theme, scene and glass from `ForgeTokens` (the token script now also reads the chart-style colours in the default Signature style and the chrome pairs), the adaptive shell, Today (hero rings, key metrics with the change against the week before, day swipe), Sleep (Rest ring, times, stage lanes) and Trends (7, 30 and 90 day averages with change, HRV and resting HR charts with labelled axes), all on `CoreRead`; `CoreDemo` fills the demo build's core store with six weeks. Strings in nine languages. Checked on a Pixel-size emulator in dark mode; behind the `forge_ui` switch until E-3f |
| E-3 ring and type | 2026-10-25 | The score rings are a line-for-line port of the Swift organic ring model (`OrganicScoreModel.kt`, pinned to values the Swift model prints) drawn in the iOS layers; Nunito where iOS uses SF Pro Rounded and Inter where it uses SF Pro, both under the OFL with their licences in `assets/licenses` |
| E-3e More | 2026-10-25 | `.noopbak` export and import of the core's store through `BackupArchive` (`CoreBackup` in Swift and Kotlin, two macOS tests), strap log sharing, the way back to the classic screens. On the emulator: an export saved through the system picker, imported again with the previous store kept beside it, the app restarted onto the restored data; the Apple restore read the same Android backup with all 42 days |
| E-3f, first part | 2026-10-25 | The Forge screens are the default, shown after the terms and onboarding gates with the app's view model (strap link, foreground sync, background service); More has a strap card (state, battery, last sync, connect, pairing through the classic wizard) and switches to the classic screens, whose Settings switch back. A fresh demo install went through terms and onboarding into the Forge screens on the emulator without a crash |
| E-3f, live heart rate | 2026-10-25 | Today shows the live heart rate with a two-minute trace while the strap streams, read from the view model's rate; not yet seen with a streaming strap (the demo build does not stream) |
| E-5 languages and backups | 2026-10-25 | Every Forge string in EN, DE, FR, ES, PT, PL, IT, RU and ZH (the i18n gate checks the focus set). `Packages/NoopCoreJNI/Tests/NoopCoreTests/Fixtures`: `android-v1.noopbak`, exported by the Android demo build through More, and `apple-v1.noopbak`, written by the shared `BackupArchive` with the Apple manifest; both restore through `CoreBackup` with their 42 days and pinned values. A backup from a real iOS install still has to be restored on Android once by hand |
| E-4, first part: the ack follows the core | 2026-10-25 | Behind a switch in More (Experimental), off by default: the Kotlin client sends a history chunk's ack only after the core's Backfiller has persisted that chunk and set its cursor (`ShadowSession.awaitBanked`, up to 10 s), and holds it otherwise so the strap keeps the chunk for the next sync. A macOS replay test shows a replayed chunk reported banked and an unknown one never; three JVM tests pin the gate. Not yet run against a real strap; Kotlin still writes Room beside the core |
| F1 and F2 | 2026-10-25 | `android-release.yml`: the full release APK with the core, signed from the secrets, rejected unless `apksigner` shows the release certificate (`daef4962…`), attached as `NOOP-Forge-android-<version>-testing.apk`; `publish-ios-release.yml` calls it after creating the release. A dry run on GitHub (run 40226770984) built, signed and verified the APK without uploading. `android_bug.yml` asks for device, Android version, strap and firmware, screens, the E-4 switch and the strap log. [`TESTING.md`](TESTING.md) tells testers what to confirm (D9); More shows a Testing label |
| Today heart rate trace | 2026-10-25 | Without a live stream the heart rate card shows the day's banked five-minute trace from the core (`CoreRead.heartRate`, the Apple `hrBuckets` read) with its latest value and time; the demo build seeds three days of heart rate. Opening the core's store is synchronized, so a card reading before the screen opened it no longer gets nothing |
| E-3f pairing | 2026-10-25 | `ForgePairing`: pick WHOOP 5.0/MG or 4.0, the preparation note, the live scan with signal bars; the picked strap is registered and made active with the same registry row the classic wizard writes (pinned by three JVM tests). Other devices open the classic wizard. The strap card's Connect goes through the Bluetooth permission gate. On the emulator the screens and the scan start; pairing a real strap is untested |
| Scene ink | 2026-10-25 | Dusk, night and first light are dark scenes (`DayCycleScene.isDark`, as on iOS): text straight on the scene (titles, section headers, the wordmark, the Sleep ring's number) takes the on-dark ink in the light appearance too, the wash darkens such a scene and the status bar icons turn light. Cards keep their own ink. Checked on the emulator at 21:50 in the light appearance on Today, Sleep and Trends; one JVM test pins the hours to the Swift table |

## Next step

E-4 on a real strap: a tester turns on "Shared core confirms history" and sends a strap log with a full overnight
offload, which should show every chunk acked after the core banked it and no held ack. Then the Forge screens
stop needing Room (Kotlin stops writing it), and phase F (release workflow, issue template, first testers). Skip
was tried for shared screens and not adopted for now ([`SKIP-SPIKE.md`](SKIP-SPIKE.md)).

## How to run a real-data check (B4)

Compares the build before a restructuring with the build after it on a copy of the owner's iPhone store:

1. Use the standing copy of the owner's iPhone store (`whoop.sqlite` with its `-wal` and `-shm`, kept
   outside the repo with a `SHA256SUMS` file); pull a new one with the known `devicectl` procedure at most
   once a day and only when newer data is needed. About 4 GB; the two analysed copies are APFS clones
   (`FileManager.copyItem`), so they cost only the pages the pass rewrites.
2. In a detached worktree at the earlier commit, add `StrandTests/RealDataAnalysisSnapshotTests.swift` from
   `main` unchanged and run only that test with `TEST_RUNNER_NOOP_ANALYSIS_DB=<pulled store>` and
   `TEST_RUNNER_NOOP_ANALYSIS_OUT=<before.sqlite>`.
3. At the later commit, run the same test with `TEST_RUNNER_NOOP_ANALYSIS_OUT=<after.sqlite>`, on the same day.
4. `Tools/compare_analysis_snapshots.py <before.sqlite> <after.sqlite> --ignore-column '*.computedAtTs'
   --ignore-column '*.updatedAtTs'` must report 0 differing tables.

## Waiting on the owner

- A used Pixel 8a or newer once Ko-fi money allows (needed for own Bluetooth checks, not for phases A to D).

## Known deviations

- **Android privacy notes**: `docs/PRIVACY_SECURITY.md` describes the Apple apps only. The restored Android
  app has its own network paths (update check, ryanbr's coach, push); they need documenting before a testing
  build (phase E).

- GRDB 6.29.3 needs the 8-file Android patch (A3). So far it exists only in the spike's build checkout; per
  D22 it becomes a carried patch when the Android build lands (phase D).
- Values outside the pass still read `UserDefaults` directly: `IntelligenceEngine.requestTimestampReheal`
  (called from the BLE layer), the Repository data functions that move in step 4 (`PuffinExperiment` flags,
  `ProfileStore`), and `StrandAnalytics` helpers that default to `UserDefaults.standard` when a caller passes no
  value. The pass itself passes its snapshot everywhere it calls them. Each is resolved when its code moves.
- ZIPFoundation 0.9.20 needs a carried Android patch, like GRDB (D22), now that `StrandCore` depends on
  `StrandImport`: `import Android` for libc, the code page 437 branch widened to Android, Bionic's non-null C
  signatures (`fwrite`, the `funopen` callbacks of the in-memory archive, adapted through closures), and
  `lchmod` skipped below Android 36 (symlink permissions never occur in NOOP's archives). On a macOS host the
  build also passes the zlib module map by hand, because the package manifest decides on the host that Apple's
  Compression exists. `StrandImport`'s xlsx reader now imports FoundationXML where corelibs keeps the XML
  parser, as the GPX and TCX parsers already did.

- `DailyAnalysis` and both service protocols are `@MainActor`, as the engine always was, so the iPhone keeps its
  scheduling. Swift's main actor runs on the main dispatch queue. Solved for the APK on 2026-10-25 (D-5): a C
  bridge hooks the queue's wake-up eventfd into the main ALooper, and the core is loaded on the main thread,
  because libdispatch takes the loading thread as its main thread. Loading the libraries there costs about
  0.35 s of cold start on the emulator (2.2 s against 1.9 s); moving that later is open.

## Untested (needs a device or a tester's strap log)

Everything on Bluetooth, background sync and real hardware. Phase A ran on an emulator only.

## Milestones

### A: spike · done, decided 2026-10-24 (D22 to D24)

Setup, reproducible on macOS (arm64), all of it outside the repo in `~/NoopAndroidSpike`:

- swift.org toolchain 6.4.1 (`swift-6.4.1-RELEASE-osx.pkg`, installed with
  `installer -target CurrentUserHomeDirectory`; Xcode's own Swift 6.4 stays the default).
- `swift sdk install swift-6.4.1-RELEASE_android.artifactbundle.tar.gz` (sha256 `a356b79f…6772`), then the
  bundle's `scripts/setup-android-sdk.sh` with `ANDROID_NDK_HOME` pointing at NDK r30 (30.0.16248370).
- SQLite 3.53.4 amalgamation (same file and checksum as `docs/BUILD.md`), compiled with the NDK's
  `aarch64-linux-android28-clang` as `libsqlite3.so` with `-DSQLITE_ENABLE_SNAPSHOT=1` and 16 KB page
  alignment; passed to SwiftPM as `-Xcc -I<dir> -Xlinker -L<dir>`.
- Build line: `swift build --swift-sdk swift-6.4.1-RELEASE_android --triple aarch64-unknown-linux-android28`.
- Emulator: `system-images;android-35;google_apis;arm64-v8a`, AVD `noop-spike`.

1. **Proven:**
   - A2: `WhoopProtocol`, `StrandTraining`, `OuraProtocol` and `PolarProtocol` build for Android with no
     source change (5 to 15 s each).
   - A3: `WhoopStore` with GRDB builds for Android once GRDB 6.29.3 gets the Android conditionals: in
     `StatementAuthorizer.swift` an `#elseif os(Android) import Android` next to the Glibc import, and in
     seven `Support/Foundation/*.swift` files `#if !os(Linux)` widened to `#if !os(Linux) && !os(Android)`.
     GRDB 7.10 and later ship the same conditionals upstream (groue/GRDB.swift PR 1850). The package's own
     test runner, pushed to the emulator with the Swift runtime, `libc++_shared.so` and the SQLite build,
     ran 849 tests with 0 failures and 1 skip, including `MigrationTests`, `SchemaOracleTests`,
     `BackupSettingsTests` and `BackupProvenanceTests`. The 11 tests not run (860 in source) are the
     Darwin-only raw outbox, which compiles out off Darwin exactly as on Linux. **Deep core (D8) is
     viable.**
   - A4: `StrandAnalytics` builds for Android unchanged. Its tests need one test-only fix: five helper
     calls such as `EcgAnalysisTests()` use an initialiser only Apple's XCTest has; in a copy they were
     changed to `init(name:testClosure:)`. Then 3,157 tests ran on the emulator with 4 failures, every one
     a test that reads a file from the repo checkout (`AnalyticsEngine.swift`, two `Oracles/*.json`) which
     does not exist on the device.
   - A5: a minimal Kotlin app (AGP 8.5.2, Kotlin 1.9.24, minSdk 28) loads one Swift library built as a
     dynamic product with `--static-swift-stdlib` and calls two raw JNI exports. `Core.charge(...)` scored
     20,000 generated inputs in 105 ms; `Core.storeSmoke()` created a `WhoopStore` in the app's files
     directory and read back 78 rows from `grdb_migrations`, the fork's full migration count, in 222 ms.
   - Numbers: the same 20,000 Charge inputs plus 5,000 RMSSD, SDNN and strain cases were computed on
     macOS (Xcode Swift and swift.org Swift agree bit for bit) and on Android. All RMSSD, SDNN and strain
     values and 19,999 of 20,000 Charge values are bit-identical; one Charge value differs in the last bit
     (75.44410652512397 vs 75.44410652512396), and the JNI call gives exactly the Android command-line
     result. The cause is the platform maths library: in a sweep of 20,000 arguments Android's `exp`,
     `log`, `pow`, `sin`, `cos` and `tanh` differ from Darwin's in 0.04 % to 4.5 % of cases, always by
     1 ulp (2 ulp for `tanh`). Rounded for display every value agreed.
   - A6: `libNoopCoreJNI.so` (Foundation, GRDB, WhoopStore, StrandAnalytics, stripped) is 65 MB, of
     which 34 MB is ICU data (`icudt76_dat`) brought in by Foundation. With `libsqlite3.so` and
     `libc++_shared.so` (both stripped, 1.4 MB each) the APK is 2.3 MB without Swift, 31 MB with
     compressed native libraries (`useLegacyPackaging = true`) and 78 MB with Android's default
     uncompressed, page-aligned libraries. Build times on this Mac: Swift library from clean about
     110 s, 56 s after editing one analytics file, 4 s with no change; Gradle 40 s first, 4 s after.
2. **Missing:** swift-java was not tried; the spike used hand-written `@_cdecl` JNI exports that pass
   only primitives. Strings, arrays and callbacks (needed from phase D on) are unproven. No x86_64 or
   32-bit ABI. No size work beyond stripping (no Foundation trimming, no ICU subset). Nothing on a
   physical phone.
3. **Checks run:** `swift sdk list`; the four pure-package builds; `WhoopStore` and `StrandAnalytics`
   test runners on the emulator (logs in the spike folder); the bit comparison of macOS and Android
   probe output (`cmp`, `diff`); `am start` of the APK with the `NoopSpike` logcat line; `unzip -v` and
   `llvm-size`/`llvm-nm` for the size breakdown.
4. **Owner decisions:**
   - **GRDB route.** Either carry the 8-file patch on GRDB 6.29.3 (a vendored fork, small, has to be
     redone on every GRDB bump) or move iOS to GRDB 7.10 or later first (upstream Android support, but a
     major-version migration of the whole Apple app). Recommendation: patch 6.29.3 for phase B, plan the
     GRDB 7 move as its own step.
   - **What "same numbers" means (D2).** Bit-identical doubles across platforms are not guaranteed
     while each side uses its own maths library. Either accept "identical after display rounding, last-bit
     differences allowed in stored doubles" with a tolerance test, or ship one portable maths library in
     the core for both platforms (more work, changes iOS results by up to 1 ulp once, which would need a
     recipe bump). Recommendation: the tolerance rule.
   - **APK size.** About 31 MB to download with compressed libraries, half of it ICU data. Acceptable for
     a sideloaded testing build, or should phase B include a size step (trim ICU, Foundation Essentials
     where possible)? Recommendation: accept for now, size step before a public call.

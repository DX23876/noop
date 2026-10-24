# Android on a shared Swift core: status

Plan: [`PLAN.md`](PLAN.md) · last updated 2026-10-24

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

## Next step

B3 step 3 of `INVENTORY.md` section 8: `AnalysisSettings` and `AnalysisHost` inside the app, routing every
`UserDefaults`, flag, Test Centre, scheduler and sink access of the pass through them. Then the first real-data
check (B4), which needs the owner's iPhone on the cable once.

## Waiting on the owner

- Release signing key and its GitHub secrets (needed in D-4, not before).
- A used Pixel 8a or newer once Ko-fi money allows (needed for own Bluetooth checks, not for phases A to D).

## Known deviations

- GRDB 6.29.3 needs the 8-file Android patch (A3). So far it exists only in the spike's build checkout; per
  D22 it becomes a carried patch when the Android build lands (phase D).
- `StrandCore` does not depend on `StrandImport` yet, because ZIPFoundation 0.9.20 does not build for Android
  from a macOS host. Its manifest decides on the host whether to declare the zlib module (`canImport(Compression)`
  is true on macOS), while the sources compiled for Android take the zlib branch. Passing the module map by hand
  (`-Xcc -fmodule-map-file=…/CZLib/module.modulemap`) gets past that; then the sources need `import Android`
  for `stat` and friends, the Linux-only code page 437 branch widened to Android, and Bionic's non-null C
  signatures (`fwrite`, the `funopen` stubs of the in-memory archive). The `.noopbak` backup is a ZIP, so this
  must be solved before steps 4 (body metrics) and 6 (backup): patch ZIPFoundation like GRDB, build the
  Android side on a Linux host where the manifest declares zlib, or write the single-entry deflate ZIP the
  backup uses directly on zlib.

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

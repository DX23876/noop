# B1 inventory: what moves into the shared core

Step B1 of [`PLAN.md`](PLAN.md), written 2026-10-24 against `main` at `d7580354f`. It maps the app-side code that
the daily analysis, the store migrations, raw data collection and backup need, separates it from UI glue, and
proposes the cut and the order for B2 and B3. Counts come from `wc -l` and `grep` over `Strand/`; type
dependencies were found by matching every type declared in `Strand/`, `StrandiOS/` and `StrandiOSShared/`
against each file (comment-only mentions removed by hand).

## 1. What already is core

Store migrations are already shared: all 78 live in `Packages/WhoopStore` and ran on Android in spike A3.
`WhoopProtocol`, `StrandTraining`, `OuraProtocol`, `PolarProtocol` and `StrandAnalytics` build for Android
unchanged (A2, A4). What is not yet shared is the code that drives them, which lives in the app target.

## 2. The daily analysis today

`Strand/Data` holds 31,648 lines. The analysis sits in:

| File | Lines | Role |
|---|---|---|
| `IntelligenceEngine.swift` | 4,791 | The pass. `performAnalyzeRecent` alone is about 2,600 lines (1779 to 4383); the rest is recipe and migration decisions, repair passes, diagnostic line builders and the day helpers |
| `IntelligenceEngine+Healthspan.swift` | 348 | AgeLess pass |
| `IntelligenceEngine+RhythmAge.swift` | 80 | Daily rhythm pass |
| `MaxHRPeakSeries.swift` | 44 | HRmax by day |

`IntelligenceEngine` is a `@MainActor final class … ObservableObject`. Combine is used only for that and for
its six `@Published` properties (results, progress, phase); there is no `sink` or subject. The heavy scan
already runs detached through `runUnescalated`. It reads and writes the store directly (113 `store.` calls)
and through 18 `Repository` members.

### Dependencies of the pass on the app

| Dependency | Where it lives | How the pass uses it | Treatment |
|---|---|---|---|
| `Repository` (18 members, list in section 3) | `Data/Repository.swift` and extensions | Store handle, reads, ledger fills, `refresh()` after writing | Move the data members into the core as store-level functions; `Repository` keeps one-line wrappers so screens do not change |
| `UserDefaults` (18 reads and writes) | Foundation | Watermarks, last-run stamps, heal flags, HRV window preference, day-cycle mode, feature toggles | Reads become one `AnalysisSettings` value the app builds per pass; the pass's own bookkeeping (watermark, heal flags) moves to a small key-value protocol the app implements with `UserDefaults` and Android with `SharedPreferences` |
| `PuffinExperiment` flags | `BLE/PuffinExperiment.swift` | Effort method, SpO2 candidate display, sleep stager v2 | Into `AnalysisSettings` |
| `RhythmAgeFeature.isEnabled`, Healthspan `isEnabled` | `Data/` | Gates two passes | Into `AnalysisSettings` |
| `TestCentre.active(…)` | `System/TestCentre.swift` | Which trace lines to build | Into `AnalysisSettings` as a set of trace domains |
| `RescoreBackgroundScheduler` | `System/` (iOS background tasks) | CPU seconds, assertion expiries, owed-rescore marker, pacing when backgrounded | A host protocol (`AnalysisHost`) the app implements; Android implements it for its own scheduler |
| `diagnosticSink` | set by `AppModel` to the strap log | Diagnostic lines | Part of `AnalysisHost` |
| `ProfileStore` | `Data/Profile.swift` (imports SwiftUI) | Reads the profile, mirrors the step-length fit back for Settings | Pass takes a `UserProfile` value; the mirror becomes a result field the app applies |
| `StressMath` | **`Screens/StressView.swift`** | `stressProxyRows` | Pure maths inside a screen file; moves to the core, `StressView` imports it |
| `WeightSeries` statics | `Data/WeightSeries.swift` | Day to date, weigh-in merge | Pure parts move; the HealthKit-facing parts stay |
| `WorkoutEnergyDisplay.peakMET` | `AI/WorkoutEnergyDisplay.swift` (Foundation only since 2026-10-28) | Peak MET for workouts | The function moves; the SwiftUI display stays |
| `WorkoutSource.sourceLabel` | `Data/WorkoutSource.swift` | One diagnostic label | Moves with its pure part |
| `DayCycleIntelligenceIntegration` | `Data/` (Foundation, packages only) | Day-cycle worker | Moves whole |
| `AnalysisProgress` | `Data/` (Foundation only; uses `AppLanguage` for text) | Progress steps | Data part moves; the localised text stays |
| `RescoreBackgroundPolicy` | `Data/` (Foundation only) | Pure decision for iOS background pacing | Stays in the app behind `AnalysisHost` (decided in step 2) |

## 3. Repository members the pass calls

| Member | Defined in | Lines in file | Note |
|---|---|---|---|
| `storeHandle()` | `Repository.swift` | | The `WhoopStore`; the core receives it directly |
| `refresh(days:)` | `Repository.swift` | | UI reload after writing; becomes a host callback |
| `dailyMetrics(fromDay:toDay:)`, `days`, `series(key:source:)` | `Repository.swift` | | Union reads over the device ids; the union logic has to move so both platforms read the same days |
| `workoutRows(days:reconcileHrCap:)` | `Repository.swift` | | Workout union and reconciliation |
| `selfHealEditedStages`, `dismissedSleepWindows` | `Repository.swift` | | Sleep edits |
| `fillCardioLoadLedger` | `TrainingCardioLoad.swift` | 539 | Uses `ProfileStore`, training session fusion |
| `energyPeakMETByDay`, `refreshWhoopEnergyModel`, `noteEnergyInputsRederived`, `ensureEnergyHistoryCurrent`, `correctLegacyWorkoutEnergy` | `EnergySeries.swift` | 1,654 | Largest helper; uses `EnergyPlanStore`, `WeightSeries`, `ProfileStore` |
| `fillRecordedWorkoutHeartRate`, `fillAppleWorkoutHeartRate` | `WorkoutHeartRateFillSeries.swift` | 222 | Reads a `PuffinExperiment` flag |
| `bodyMetrics(days:)` | `BodyMetricsSeries.swift` | 213 | Uses `StrandImport` |
| `resolvedSteps(from:to:)` | `RollingStepsAverage.swift` | 116 | File imports SwiftUI and StrandDesign for its card; the resolver itself is plain |
| `agelessLongSessions(days:)` | `TrainingVO2maxEstimates.swift` | 93 | |

`Repository.swift` (4,934 lines) itself stays in the app: it is the screens' `ObservableObject` with 14
`@Published` properties and imports `StrandDesign` for chart points. Only the data functions above leave it.

## 4. Raw data collection (`Strand/Collect`, 2,444 lines)

Almost platform-neutral already. `Collector`, `Backfiller` (981 lines, the offload state machine),
`RawHistoryArchive`, `StorePaths` and the small policies use only Foundation and the packages, apart from
`PuffinExperiment` flags (into settings) and two Apple-only pieces:

- `ImuSessionFileStore` imports `Compression`.
- `RawDataSessionStore` imports Combine for UI state.

This is what the deep core (D8) needs on Android: Kotlin delivers bytes from the strap, Swift decodes, offloads
and stores. It is a later move than the analysis (phase D needs it, phase B does not), listed here so B2's
package boundary allows it.

## 5. Backup (`DataBackup.swift`, 745 lines; `BackupSync.swift`, 471 lines)

The settings whitelist is already in `WhoopStore` (`BackupSettings`). `DataBackup` mixes the file pickers
(AppKit, UIKit, `UniformTypeIdentifiers`) with the format work: `writeBackup`, `verifyWrittenBackup`,
`restore(from:toDatabaseAt:)` and `backupOrigin` use SQLite3 and ZIPFoundation, both available off Apple. The
format work moves to the core; `runExport`, `runImport` and the pickers stay. `BackupSync` is UI and stays.

## 6. Stays in the app

Everything SwiftUI, every screen and view model, `Repository` as the screens' cache, `ProfileStore` and the
other preference stores, HealthKit (`StrandiOS/Health`, which writes into the store and is therefore an
input, not a dependency), CoreBluetooth (`Strand/BLE`), Watch connectivity, CoreMotion, the AI coach
(`Strand/AI`), lab report text extraction (Vision, PDFKit), widgets, notifications and background task
registration.

## 7. Gaps on Android found here

- **Compression**: the raw outbox (already Darwin-only in `WhoopStore`, see A3) and `ImuSessionFileStore`.
  Android needs another codec or the feature stays off there.
- **UserDefaults**: exists in Foundation on Android but is not what Android's settings screens write; hence
  the settings value and key-value protocol in section 2.
- **Background pacing**: the iOS background-task budget logic has no Android counterpart yet.
- **Test-only**: five `XCTestCase()` helper calls in `StrandAnalytics` tests (A4) and tests that read repo
  files by path; they run on macOS and Linux but not on a device.

## 8. Proposed cut and order (B2, B3)

**Package name: `StrandCore`**, following the existing `Strand*` package names. Dependencies:
`WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, `StrandTraining`, `StrandImport`. No SwiftUI, no Combine,
no `StrandDesign`; Apple-only code behind `#if canImport(...)`.

Steps, one concern per commit, each with `Tools/local-tests.sh`, the macOS and iOS builds and `StrandTests`
(B3), and `Analysis migration required: no`:

1. Empty `StrandCore` package wired into `project.yml`, building on macOS, iOS and Android.
2. Pure helpers move with their tests: recipe decision and migration window functions
   (`AnalysisRecipe`), `StressMath` with the stored stress proxy, `DayCycleIntelligenceIntegration`.
   Done 2026-10-24. Re-sorted while doing it: the diagnostic line builders and the data part of
   `AnalysisProgress` move with the pass in step 5, `peakMET` and the pure `WeightSeries` statics with
   their data functions in step 4, so no file is split twice. `RescoreBackgroundPolicy` stays in the app:
   it paces iOS background tasks and belongs behind `AnalysisHost`, Android brings its own.
3. Inside the app, without moving the pass: introduce `AnalysisSettings` and `AnalysisHost` and route every
   `UserDefaults`, flag, Test Centre, scheduler and sink access of the pass through them.
   **Real-data check 1 (B4).**
4. Repository data members move one file per commit, `Repository` keeping wrappers. Done 2026-10-24 for the
   arithmetic and the reads: `MetricResolver`, `StoreReader` (the union reads, found to be the base everything
   else stands on), `WorkoutSource`, training fusion and read, cardio pricing (`CardioLoadCache` for the memo),
   heart rate fills, VO2max session parts, weight and body reads, `EnergyModelRefresh`. The orchestration
   around them (windows, caches, serialization, screen refreshes) stays in `Repository` and reaches the pass
   through a data-services protocol in step 5 rather than moving.
5. The engine moves whole rather than split: `IntelligenceEngine` becomes `DailyAnalysis` in `StrandCore`,
   reaching `Repository` through `AnalysisDataServices` and `ProfileStore` through `AnalysisProfileSource`, with
   published state signalled through `AnalysisObservation` instead of Combine. The app keeps the old name as a
   typealias, so screens and tests are unchanged. Done 2026-10-24. **Real-data check 2 (B4).**
6. Backup format work moves (section 5). A `.noopbak` written before and after must restore identically.
   Done 2026-10-24: `BackupArchive` (zip layout, manifest, verify after write, restore with the previous store
   kept beside it, origin detection) in `StrandCore`; `DataBackup` keeps the file pickers, translated failure
   text and the journal and goals settings it applies after a restore. The zip code needed the ZIPFoundation
   Android patch.
7. Collect layer moves (section 4). Done 2026-10-24: `Collector`, `Backfiller`, `RawHistoryArchive`, the clock
   correlation and the small policy types. `ImuSessionFileStore`, `RawDataSessionStore` and `StorePaths` stay
   in the app: the first two are research captures with their own screen (the collector reaches them through
   a frame tap), the third holds the app's paths. The experimental sub-lag switch reaches the decoders as a
   closure, off by default as before. **Real-data check 3 (B4).**

31 of the 496 `StrandTests` files reference `IntelligenceEngine`, mostly its static decisions and line
builders; they move with the code they test into `StrandCore` tests, which also makes them run on Android.

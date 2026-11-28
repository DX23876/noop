# NOOP — System Architecture

NOOP (this fork: NOOP Forge) is an **offline-first** companion app for WHOOP straps (4.0 and 5.0/MG). It talks directly to
the strap over Bluetooth Low Energy, stores everything on-device in GRDB/SQLite, and computes
Charge, Effort, Rest, HRV, and sleep locally. There is no NOOP cloud or account. Every optional,
user-initiated network path (for example the Coach and the Oura history import) is listed in the
[privacy and security](PRIVACY_SECURITY.md) inventory.

> **Not affiliated with WHOOP.** NOOP is an independent, interoperability project built on
> community reverse-engineering of the strap's Bluetooth protocol. It is **not a medical device**
> and produces **approximate** physiological estimates that must not be used for diagnosis or
> treatment. See [`DISCLAIMER.md`](../DISCLAIMER.md) and [`ATTRIBUTION.md`](../ATTRIBUTION.md).

---

## 1. The big picture

The system is a one-directional pipeline. Bytes arrive from the strap (or from an import file), get
decoded into typed rows, land durably in SQLite, are read back through a thin repository, are turned
into daily metrics by pure analytics functions, and finally render in SwiftUI. Nothing is ever sent
off-device.

```
                          ┌─────────────────────────────────────────────────────────┐
   WHOOP strap (4.0/5.0)  │                     NOOP (on-device)                     │
   ────────────────────   │                                                          │
        BLE GATT           │   CoreBluetooth          WhoopProtocol (pure decode)    │
   ┌──────────────┐  notify│  ┌────────────┐  bytes  ┌──────────────────────────┐    │
   │ custom svc   ├────────┼─▶│ BLEManager │────────▶│ Reassembler              │    │
   │ 6108…/fd4b…  │  write │  │ (CoreBT    │  frames │  → parseFrame            │    │
   │ HR 0x2A37    │◀───────┼──│  delegate) │         │  → extract[Historical]…  │    │
   │ batt 0x2A19  │  cmds  │  └─────┬──────┘         └────────────┬─────────────┘    │
   └──────────────┘        │        │                             │ Streams          │
                           │        │ complete frame              ▼                  │
                           │        ▼                  ┌──────────────────────┐      │
                           │  ┌───────────┐  live      │  WhoopStore (actor)  │      │
                           │  │FrameRouter│──events────▶│  GRDB / SQLite       │      │
                           │  │ LiveState │  HR/RR/UI  │  decoded streams +   │      │
                           │  └───────────┘            │  metric caches +     │      │
                           │        │                  │  raw outbox          │      │
                           │   live │ ┌─────────┐ hist └─────────┬────────────┘      │
                           │        └▶│Collector│ ┌──────────┐   │ reads             │
                           │          └─────────┘ │Backfiller│   ▼                   │
                           │   imports            └──────────┘ ┌────────────┐        │
   files ──────────────────┼─▶ StrandImport ──────────────────▶│ Repository │        │
   export.zip / *.csv      │   (CSV + Apple Health)            └─────┬──────┘        │
                           │                                         ▼               │
                           │                      StrandAnalytics ──▶ SwiftUI screens│
                           │                      (HRV/recovery/    (StrandDesign)   │
                           │                       strain/sleep)                     │
                           └─────────────────────────────────────────────────────────┘
```

The same `WhoopStore` SQLite file is the single convergence point for three independent producers:
the **live** BLE path, the **historical** BLE offload path, and the **import** path. All readers go
through `Repository`.

---

## 2. Repository layout

```
project.yml                     XcodeGen source of truth (Strand.xcodeproj is generated, never committed)
Config/                         BundleId.xcconfig (BUNDLE_ID_PREFIX), BundleIdSecrets.example.xcconfig
Vendor/Nomic/                   gitignored; llama.xcframework + embedding model, fetched by Tools/bootstrap-nomic.sh

Strand/                         macOS app target (scheme Strand); most of it is also compiled into NOOPiOS
├── App/                        Composition root, window/scene, navigation, workout sessions
│   ├── StrandApp.swift         @main App scene (macOS only); owns AppModel, wires environment objects
│   ├── AppModel.swift          @MainActor root state — owns BLE, Repository, profiles
│   ├── RootView.swift          NavigationSplitView shell + NavItem routing (macOS only)
│   └── ContentView.swift       macOS shell gates (excluded from iOS)
├── BLE/                        CoreBluetooth transport and the live/decode seam
│   ├── BLEManager.swift        CBCentral/CBPeripheral delegate, scan→bond→stream
│   ├── FrameRouter.swift       pure decode→LiveState router (no CoreBluetooth)
│   ├── LiveState.swift         @MainActor observable connection/biometric snapshot
│   ├── Commands.swift          WhoopCommand enum (command bytes + frame builders)
│   ├── StandardHeartRate.swift, BackfillPolicy.swift, StuckStrapDetector.swift, …
│   └── Oura*/Huami*/FTMS*/…    sources for the other supported device kinds
├── Collect/                    App-side persistence glue (BLE → store)
│   ├── BackfillDrain.swift     ordered offload-frame queue drained into the Backfiller
│   ├── StorePaths.swift        on-disk SQLite location (App Support/OpenWhoop)
│   └── Raw*/Imu*               raw-data session capture and donation recorders
│                               (Collector, Backfiller, ClockCorrelation, ClockPolicy, PrunePolicy and
│                               RawCaptureWindow live in Packages/StrandCore)
├── Data/                       Read model + import glue (Repository, importers, Profile, stores)
├── AI/                         Coach, goals, plan tools, Hevy proposals, memory
├── Forge/, Liquid/             Forge look (today, timeline, notes) and the Liquid Today dashboard
├── Health/, Hevy/, Oura/       Health export merge; Hevy sync coordinator; Oura cloud-import lane
├── Onboarding/, MenuBar/       onboarding wizard; macOS menu-bar extra
├── Screens/                    SwiftUI feature screens (Today, Live, Sleep, Trends, …)
├── System/                     Notifiers, schedulers, diagnostics, macOS integrations (lock screen, Shortcuts)
└── Resources/                  Info.plist, entitlements, assets, Localizable.xcstrings

StrandiOS/                      iOS-only sources for NOOPiOS (scheme NOOPiOS, iOS 17+)
├── App/                        StrandiOSApp (@main), RootTabView (tab shell), More catalog, Siri/Shortcuts settings
├── Forge/                      Forge screens: Today, Sleep, Health, Energy, Cycle, Training, Strength,
│   │                           Settings hubs, Search, weekly report, tile board, widgets on Today
│   └── Food/                   food log views
├── Health/                     HealthKit bridge, sample writer, writeback scheduler, phone workout session
├── AI/                         Nomic embedding provider, semantic-memory background task
├── Widgets/                    publishers and controllers for widgets and Live Activities
├── System/                     App Intents, background schedulers, quick actions, MetricKit log
└── Resources/                  Info.plist, NOOP.entitlements, asset catalog, alternate icons

StrandiOSShared/                snapshots and attributes shared by the app, the widgets and (partly) macOS:
                                widget snapshots, Live Activity attributes, HR/stress traces
StrandiOSWidgets/               NOOPiOSWidgets extension: Today/rings/energy/food/goal/heart-rate/stress/weight
                                widgets, Fitness widgets, Live Activities, workout controls
NOOPWatch/                      NOOPWatch app (watchOS 10): glance, live HR, workout, breathe, interval views
NOOPWatchComplications/         NOOPWatchComplications extension (watch complications)
StrandTests/, StrandiOSTests/   unit tests for the macOS and iOS app targets

Packages/                       Swift packages (section 3)

android/                        Kotlin/Compose shell over the shared Swift core (section 2.1)
Tools/                          Python and shell tooling (local-tests.sh, gen_core_dao.py, i18n_audit.py, …)
                                and Swift tools: Backfill, SleepBench, SleepPSG, EnergyBench, ActivityBench, …
docs/                           documentation; docs/fork/ holds fork-only guides, decisions and release notes
```

### 2.1 Targets from `project.yml`

| Target | Kind | Platform | Sources |
|---|---|---|---|
| `Strand` | application (product `NOOP Staging.app`, display name NOOP Forge, id `$(BUNDLE_ID_PREFIX).noop.staging`) | macOS 13 | `Strand/` |
| `StrandTests` | unit tests | macOS | `StrandTests/` |
| `NOOPiOS` | application (id `$(BUNDLE_ID_PREFIX).noopai`) | iOS 17 | `Strand/` minus the macOS-only files, `StrandiOS/`, `StrandiOSShared/`, `Vendor/Nomic/Resources` |
| `NOOPiOSTests` | unit tests | iOS | `StrandiOSTests/` |
| `NOOPiOSWidgets` | app extension (WidgetKit, Live Activities) | iOS 17 | `StrandiOSWidgets/`, `StrandiOSShared/` |
| `NOOPWatch` | application | watchOS 10 | `NOOPWatch/` |
| `NOOPWatchComplications` | app extension | watchOS 10 | `NOOPWatchComplications/` |

Schemes: `Strand`, `NOOPiOS`, `NOOPWatch`. `BUNDLE_ID_PREFIX` defaults to `com.noopapp` in
`Config/BundleId.xcconfig` and is overridden in the gitignored `Config/BundleIdSecrets.xcconfig`.
The app targets link the local packages `WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, `StrandCore`,
`StrandTraining`, `MuscleMap`, `StrandImport`, `StrandDesign`, `SemanticMemory`, `OuraProtocol` and
`PolarProtocol`, plus the exact-pinned `MarkdownUI` and `ZIPFoundation`. `NoopLocalAccess` and
`NoopCoreJNI` are not linked into any Apple app target.

The released iOS/iPadOS app is `NOOPiOS` with its widget extension and the optional Watch companion. Package
manifests declare their real platform floors individually.

### 2.2 Android

Android in this fork is a Kotlin shell around the same Swift core, not an independent reimplementation.
`android/swift-core/build-swift-core.sh` cross-compiles `Packages/NoopCoreJNI` (with `StrandCore` and
the packages below it) into `libNoopCore.so` using the Swift SDK for Android, and the app calls it
through JNI (`com.noop.core`: `SwiftCore.kt` and the `Core*` facades).

- **Storage.** Android stores only in the core's GRDB database
  (`<filesDir>/core/noop-core.sqlite`), through `com.noop.data.CoreWhoopDao`, which
  `Tools/gen_core_dao.py` generates from the annotated DAO declarations (`WhoopDao.kt`,
  `DeviceRegistryDao.kt`). The `@Entity`/`@Dao` annotations in `DaoAnnotations.kt` are the app's own and
  are read only by that script; there are no Room entities, DAOs or migrations. Room remains only as a
  transitive dependency of WorkManager. A schema change is a `WhoopStore` migration that both platforms run.
- **What stays in Kotlin.** The Bluetooth transport and its frame decoding, Android services (alarms,
  notifications, widgets, location, push), the Compose UI (`com.noop.ui`, with the Forge screens in
  `com.noop.ui.forge`) and presentation helpers. Scoring, analytics, import, backup and any other
  computation belong in the packages and reach Android through `NoopCoreJNI`.
- **Kotlin source layout** (`android/app/src/main/java/com/noop/`): `ble`, `core` (the JNI facades),
  `data`, `ingest`, `analytics`, `protocol`, `ui`, `widget`, `alarm`, `notif`, `location`, `oura`, `polar`,
  `push`, `ai`, `testcentre`, `update`. The directory names say where code sits, not which of it still
  computes in Kotlin; [`fork/android/STATUS.md`](fork/android/STATUS.md) records what moved into the core.

See [`fork/android/STATUS.md`](fork/android/STATUS.md) and
[`fork/android/CORE-ONLY-PLAN.md`](fork/android/CORE-ONLY-PLAN.md).

---

## 3. Package responsibilities and boundaries

Each package has a narrow contract. The dependency graph is acyclic and the leaf packages are
**platform-pure** (no CoreBluetooth, no UIKit/AppKit) so they run in CLI tools and tests. The arrows below
are the `path:` dependencies in each `Package.swift`:

```
StrandDesign        (no deps; SwiftUI)        MuscleMap   (no deps; SwiftUI)
OuraProtocol        (no deps)                 PolarProtocol (no deps)
StrandTraining      (no deps)                 WhoopProtocol (no deps)
SemanticMemory      ──▶ GRDB.swift            NoopLocalAccess ──▶ GRDB.swift (standalone, macOS only)

WhoopStore ─────────▶ WhoopProtocol + OuraProtocol + StrandTraining + GRDB.swift
   ▲
StrandAnalytics ────▶ WhoopProtocol + WhoopStore
StrandImport ───────▶ WhoopProtocol + WhoopStore + ZIPFoundation + GRDB.swift
   ▲
StrandCore ─────────▶ WhoopProtocol + WhoopStore + StrandAnalytics + StrandTraining + StrandImport
   ▲                  (+ GRDB.swift, ZIPFoundation, swift-crypto)
   │
NoopCoreJNI ────────▶ StrandCore + SemanticMemory (+ the packages above); dynamic library `NoopCore`
```

| Package | Responsibility | Key types / functions | Notable boundary |
|---|---|---|---|
| **WhoopProtocol** | The reverse-engineering core: turn raw BLE bytes into typed rows. Framing, CRC, fragment reassembly, schema-driven field decode, stream extraction, historical-chunk classification. Also builds the `whoop-decode`, `whoop-optical-experiment` and `whoop-re` CLIs. | `Reassembler`, `verifyFrame`, `parseFrame` → `ParsedFrame`, `extractStreams`, `extractHistoricalStreams`, `classifyHistoricalMeta`, `Streams`, `DeviceFamily`, `crc8`/`crc16Modbus`/`crc32` | **No CoreBluetooth.** Exposes GATT UUIDs as `String`; the app wraps them in `CBUUID`. |
| **OuraProtocol** | Clean-room Oura ring BLE protocol and decode (experimental support), with the `oura-decode` CLI. | `OuraProtocol` library, `oura-decode` | No CoreBluetooth; `WhoopStore` depends on it for the Oura raw-dump mappings. |
| **PolarProtocol** | Clean-room Polar model identification and Measurement Data (PMD) decoder and control-point builder. | `PmdDecoder`, `PmdControl`, `PolarModel` | Decode and identification only; no BLE wiring. |
| **WhoopStore** | Durable on-device persistence built on GRDB/SQLite. Migrations, decoded streams, metric caches, generic metric series, raw outbox, cursors, device registry, and the stores for food, training, lift log, Hevy, ECG and energy. | `actor WhoopStore`, `makeMigrator()`, `insert(_:deviceId:)`, `dailyMetrics`, `sleepSessions`, `metricSeries`, `pruneRaw`, `ClockRef`, `RawBatchMeta` | An **`actor`** — all writes/reads run off the main thread on its serial executor. |
| **StrandAnalytics** | All physiological math, as pure functions over inputs. HRV, recovery, strain, sleep staging, workout detection, baselines, HR zones, correlation/comparison, energy models. | `AnalyticsEngine.analyzeDay(...)` → `DayResult`, `HRVAnalyzer`, `RecoveryScorer`, `StrainScorer`, `SleepStager`, `WorkoutDetector`, `Baselines`, `CorrelationEngine`, `WhoopEnergyModel` | **Pure** — never touches the database. Produces `DailyMetric`/`CachedSleepSession` shapes for the store. |
| **StrandImport** | Parse data the user already owns: WHOOP CSV, Apple Health, Oura, Fitbit, Garmin, Xiaomi exports; FIT/GPX/TCX activity files; lab, nutrition and lifting sheets; the Hevy API payloads. | `ImportCoordinator.detectAndImport`, `WhoopExportImporter`, `AppleHealthImporter`, `AppleHealthAggregator`, `ActivityFileImporter` | **Parsing only** — returns normalized model arrays; the app (or `StrandCore`) maps them into the store. |
| **StrandDesign** | The SwiftUI design system: palette, typography, motion, charts, components. Also builds for watchOS. | `StrandPalette`, `StrandCard`, `RecoveryRing`, `StrainGauge`, `Hypnogram`, `TrendChart`, `Sparkline`, `YearHeatStrip` | No data or protocol deps — pure presentation. |
| **StrandTraining** | Training catalogue and workout engine: bundled exercise catalogue and anatomy, plans, programs and blocks, routines and routine import, progression, plate calculator, warm-up planner, set flow and timers. | `WorkoutEngine`, `ProgressionEngine`, `PlanBuilder`, `TrainingCatalog`, `BundledExerciseCatalog`, `TrainingProgram` | Pure; no dependencies. `WhoopStore` depends on it for the native-training tables. |
| **MuscleMap** | SwiftUI muscle-map rendering for training views (third-party, MIT). | `MuscleMap` library | Presentation only; linked by the Apple app targets, not by the core. |
| **SemanticMemory** | The local Coach memory index: stored embeddings, ranking and the index store. | `SemanticIndexStore`, `SemanticRanking` | Depends on GRDB only. The embedding provider (Nomic) lives in the iOS app target. |
| **NoopLocalAccess** | `noop-local-access`: bounded, read-only access to NOOP health data over MCP (stdio) or one-shot JSON queries. | `NoopLocalAccessCore`, `noop-local-access` | macOS only; GRDB only; no network or write path; no NOOP package dependencies. |
| **StrandCore** (fork) | The platform-neutral app core shared by the Apple apps and Android: the daily analysis pass and its host, `AnalysisRecipe` (the rebuild lineage), raw collection and backfill, backup archive, metric resolver, energy, Hevy sync, exercise media, score provenance. | `AnalysisHost`, `DailyAnalysis`, `AnalysisRecipe`, `Collector`, `Backfiller`, `BackupArchive`, `MetricResolver` | No SwiftUI, Combine or StrandDesign: everything must also build for Android. |
| **NoopCoreJNI** (fork) | Android's door into the core: a dynamic `NoopCore` library whose JNI entry points call plain Swift functions in `Bridge.swift`; `Sources/NoopCore/Shared` links app sources Android needs unchanged. | `Bridge.swift`, `JNIExports.swift`, `CoreCall`, `Core*` facades | `CJNI` (jni.h) is used only on Android; the bridge functions are tested on macOS. |

### Multi-generation protocol support

`WhoopProtocol` supports both strap generations through `DeviceFamily`:

- **`.whoop4`** — the original reverse-engineered protocol: `0xAA` SOF, `u16 LE` length, **CRC8**
  (poly `0x07`) header check, `CRC32` (zlib) payload trailer.
- **`.whoop5`** — the newer "puffin" transport: a format byte, **CRC16-Modbus** header check, and a
  set of packet types (e.g. `PUFFIN_COMMAND_RESPONSE` = 38, `PUFFIN_METADATA` = 56) that
  `canonicalTypeName(_:schema:)` aliases onto the 4.0 base names so they decode with the same logic.

`verifyFrame(_:family:)` and the `DeviceFamily` UUID/CLIENT_HELLO accessors are the single switch
points between generations; everything downstream of `parseFrame` is generation-agnostic.

---

## 4. The actor / concurrency model

Concurrency separates UI publication from database reads and CPU-heavy presentation/analysis work:

| Component | Isolation | Why |
|---|---|---|
| `WhoopStore` | **`actor`** | GRDB's `DatabaseQueue` calls block; the actor moves that blocking off the main thread onto its own serial executor. `DatabaseQueue` (not `DatabasePool`) is kept on purpose — the actor provides serialization. |
| `AppModel`, `LiveState`, `Repository`, `BLEManager`, `FrameRouter`, `Collector`, `Backfiller` | **`@MainActor`** | These observe/mutate published UI state. CoreBluetooth's central is created on `queue: .main`, so delegate callbacks already arrive on the main actor — no hopping needed to update `LiveState`. |
| `DayCycleIntelligenceIntegration` | **worker actor with FIFO admission** | Owns the day-cycle cache and folds HR/step pages outside the main actor. Admission remains held across database awaits; cancellation is checked between windows/pages. The engine applies the returned value and buffered diagnostics on the main actor. |
| `SleepPresentationStore` | **scene-local `@MainActor` cache; detached value preparation** | Coalesces history, selected-night motion and HR reads across Sleep and hosted cards. Immutable inputs and prepared `Sendable` values cross the worker boundary; only completed, current revisions reach the UI. |
| Historical frame drain | **serial Task queue** | `BLEManager.routeBackfillFrame` appends frames synchronously (delegate order) and a single drain `Task` awaits `Backfiller.ingest` one frame at a time, so `HISTORY_START → data → HISTORY_END` chunk assembly can never be reordered. |

Dashboard roots avoid observing the high-frequency `AppModel`; live body-clock and cycle readouts
observe it in leaf views. Sleep and Trends expose cards directly to the scaffold's lazy column.
Classic keeps its existing lazy layout; Liquid, Trends Dashboard and Overview build long lists lazily.
Dashboard loaders capture their identity before awaiting, collect a snapshot, then validate cancellation,
data revision, source, day and relevant settings before publication. Hydration has an independent read.
Explicit sleep edits also advance `Repository.sleepPresentationRevision`, including edits older than
the normal recent-row refresh window. A cancelled consumer does not cancel a shared presentation read;
invalidating its revision rejects late results for every waiter. Liquid decorative timelines pause when
their card is not visible, their tab is inactive, or the scene is inactive.

Sleep scores shown by dashboards resolve from the latest corrected daily record before falling back to a
cached metric series. Energy window replacement advances a separate presentation revision so every Today
dashboard reloads only its calorie value and sparkline after a detail rebuild. Large on-device databases
use two concurrent GRDB readers: this preserves WAL overlap while preventing several full-history scans
from saturating CPU and storage at the expense of scrolling. Repository keeps the observable registry's
WHOOP source IDs in memory, so visible charts do not perform synchronous registry reads on the main actor
while analysis occupies the database pool.
Long analysis and step-calibration scans run at background priority through a continuation bridge, so an
awaiting main-actor task cannot raise them back to interactive priority and compete with scrolling.

The key invariant: **frames are buffered synchronously in delegate-callback order**, and only the
slow work (decode + `await store.insert`) crosses into the store actor. `Collector.flush()` and
`Backfiller.finishChunk()` both *snapshot-and-clear* their buffer before the first `await`, so
concurrent ingests accumulate cleanly into the next batch.

Two SQLite handles are open simultaneously — one inside `BLEManager`'s `Collector`/`Backfiller`, one
inside `Repository`. This is safe because `WhoopStore` enables **WAL journal mode** and a **5-second
busy timeout** (`PRAGMA journal_mode = WAL`, `config.busyMode = .timeout(5)`), so the writer and the
reader never deadlock on contention.

---

## 5. Live path vs. historical path

The two BLE data paths diverge at one branch in `BLEManager.peripheral(_:didUpdateValueFor:)`. After
the `Reassembler` yields a complete frame, `FrameRouter.handle(frame:)` always runs (it drives the
live UI state), and then:

```swift
if backfilling {
    if BLEManager.isOffloadFrame(frame) {   // types 47/48/49/50 only
        armBackfillTimeout()
        routeBackfillFrame(frame)           // serial drain → Backfiller
    }                                       // live type-40/43 flood is dropped during offload
} else {
    collector?.ingest(frame)                // live → Collector
}
```

### Live path (real-time)

1. **CoreBluetooth notify** on the data/cmd/event characteristics, or on standard HR `0x2A37`.
2. **`Reassembler.feed`** accumulates BLE fragments into complete `0xAA…CRC32` frames.
3. **`FrameRouter.handle`** runs `parseFrame`, rejects bad-CRC frames, and updates `LiveState`
   (`heartRate`, `rr`, `lastEvent`, `worn`, …). `EVENT` packets fire physical-input hooks
   (double-tap, wrist on/off) and a rate-limited catch-up sync trigger.
4. **`Collector.ingest`** buffers the frame. Once a `ClockRef` exists (from `GET_CLOCK`
   correlation), it flushes on cadence (`maxFrames: 64` or `maxInterval: 30s`):
   `parseFrame → extractStreams(clockRef) → store.insert` (**decoded first, durable**) →
   optionally `enqueueRawBatch` (raw, transient).
5. Standard `0x2A37` HR/RR is recorded **continuously and independently** via
   `Collector.ingestStandardHR` — it carries a wall-clock timestamp so it needs no clock
   correlation and keeps recording regardless of which screen is open.

Live `REALTIME_DATA` (type 40) timestamps are a **device monotonic epoch**; `extractStreams` maps
them to wall time with the linear `(device, wall)` offset captured at connect by
`ClockCorrelation`/`GET_CLOCK`.

### Historical path (offload / backfill)

The strap holds a ~14-day on-device biometric store. NOOP re-offloads it the way the official client
syncs — once per connect and then every `backfillIntervalSeconds` (900s) while connected+bonded — so
the periodic **type-47 historical offload is the primary metric source**, not the live stream.

1. `requestSync(_:)` gates every kick on connection state **and** `BackfillPolicy` (the rate
   limiter, persisted across relaunch). On a go it calls `beginBackfill()`, which sends
   `SEND_HISTORICAL_DATA` and arms an idle watchdog.
2. The strap streams `HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE`.
3. `Backfiller.ingest` is a state machine driven by `classifyHistoricalMeta`. On each `HISTORY_END`
   it commits one chunk with a strict **local safe-trim invariant**:

   ```
   decode chunk  →  await store.insert (decoded durable)
                 →  await store.enqueueRawBatch (only if research toggle on)
                 →  await store.setCursor("strap_trim", …)
                 →  ackTrim (.withResponse confirmed ack to strap)
   ```

   A chunk is forgotten by the strap **only after** decoded data is locally durable and the ack is
   link-layer confirmed. If the watchdog fires (strap went silent), nothing is acked and the durable
   `strap_trim` cursor lets the next session resume exactly where it left off.

Type-47 records carry their **own real-unix timestamps**, so the historical path does *not* depend on
`GET_CLOCK`; if the clock correlation hasn't landed yet, `Backfiller` falls back to an identity
`ClockRef` and the offset math becomes a no-op.

### Why they differ

| Aspect | Live path | Historical path |
|---|---|---|
| Producer | `Collector` | `Backfiller` |
| Trigger | Continuous notify | `SEND_HISTORICAL_DATA`, rate-limited |
| Frame types | 40/43 (REALTIME) + 0x2A37 | 47/48/49/50 (HISTORICAL/EVENT/META/LOGS) |
| Timestamp source | Device epoch → wall via `ClockRef` | Real unix in the record |
| Durability unit | Cadence flush (64 frames / 30s) | One `HISTORY_END` chunk, trim-acked |
| Decode fn | `extractStreams` | `extractHistoricalStreams` |
| Role | Live HR/UI + opt-in detail | **Primary** metric source |

---

## 6. The BLE connection lifecycle

`BLEManager` is the only CoreBluetooth surface. The connection handshake runs **exactly once per
connection** (guarded by `connectHandshakeDone`, because `didWriteValueFor` re-fires on every
confirmed write):

```
scan(customService) ─▶ didDiscover ─▶ connect ─▶ didDiscoverServices
   ─▶ discover characteristics ─▶ BOND (one confirmed GET_BATTERY_LEVEL write to …0002)
   ─▶ subscribe notify on cmd/event/data + 0x2A37 + 0x2A19
   ─▶ didWriteValueFor (bond ack) ─┬─ HELLO → SET_CLOCK → GET_CLOCK
                                   ├─ stop type-43 realtime flood, GET_DATA_RANGE
                                   ├─ requestSync(.connect)  (deferred ~1.5s)
                                   ├─ startBackfillTimer()   (re-offload every 900s)
                                   └─ startKeepAlive()       (re-arm realtime, poll battery, watchdog)
```

Supporting machinery, all on the main run loop:

- **Keep-alive (30s):** re-arms the realtime stream if wanted, polls battery, and — if **no
  notification has arrived for >120s** — bounces the link; the auto-rescan on disconnect re-bonds and
  resumes streaming.
- **Stuck-strap watchdog:** after each offload, `StuckStrapDetector` compares the strap's newest
  record (`GET_DATA_RANGE`) against NOOP's data frontier (`latestHRSampleTs`). Strap-ahead **and**
  frontier-frozen ⇒ a reboot hint banner; off-wrist / caught-up is *not* flagged.
- **Auto-reconnect:** an unintentional disconnect flushes the `Collector` and rescans after 3s.

`LiveState` is the published bridge: `BLEManager` and `FrameRouter` write it; SwiftUI observes it.
`RootView` isolates the ~1 Hz HR/frame churn into a small `SidebarStatus` view so the rest of the
shell doesn't re-render on every beat.

---

## 7. Storage model (WhoopStore / SQLite)

GRDB drives a migrator (`makeMigrator()` in `Packages/WhoopStore/Sources/WhoopStore/Database.swift`) that
currently runs through `v94-weight-water-mark`. Migrations are keyed by identifier string. The separate
`WhoopStoreInfo.schemaVersion` constant (currently `26`) is only the marker written into the backup manifest
and is not the migrator's version; [`DATA_MODEL.md`](DATA_MODEL.md) lists every table and migration. The
schema groups into these concerns:

**Device registry** — `device`, `pairedDevice` (one active device), `dayOwnership` (which device's scores a
day shows).

**Durable decoded streams** — natural key `(deviceId, ts)`, one row per sample:
`hrSample`, `rrInterval`, `event`, `battery`, plus the type-47 biometrics `spo2Sample`,
`skinTempSample`, `respSample`, `gravitySample`, and the further per-second streams `stepSample`,
`ppgHrSample`, `sleepStateSample`, `v18AuxSample`, `ppgWaveformSample` and `ecgWaveformSample`.

**Metric caches** — the rolled-up shapes the screens read:
- `dailyMetric` — one row per `(deviceId, day)`: `recovery`, `strain`, sleep stage minutes,
  `restingHr`, `avgHrv`, `spo2Pct`, `skinTempDevC`, `respRateBpm`, `exerciseCount`, and later columns.
- `sleepSession` — one row per `(deviceId, startTs)` with `efficiency`, `restingHr`, `avgHrv`, and
  a JSON `stagesJSON` hypnogram.
- `journal`, `workout`, `appleDaily`, `appleStepHour`, `bodyWeightEntry`, `labMarker`, `liveSession`,
  `scoreInputProvenance` — imported journal answers, workouts (WHOOP, Apple Health and others),
  Apple-Health daily aggregates, the wearer's weigh-ins and lab markers, live coaching sessions, and the
  provenance of computed headline scores.

**Generic metric series** — `metricSeries(deviceId, day, key, value REAL)`: a tall, long-format
table so *any* scalar metric from *any* source can be queried/compared uniformly (the substrate for
the Metric Explorer and correlations), indexed by `(deviceId, key, day)`.

**Raw outbox** — `rawBatch`: the compressed, **transient, prunable** record of original frames,
captured only when the research toggle is on. Decoded data is always committed *before* raw is queued,
so pruning raw (`PrunePolicy`: 24h window / 50MB cap) can never lose a metric. `cursors` holds durable
watermarks such as `strap_trim` and the analysis recipe cursors (below). The analysis caches
(`analysisInputRevision`, `analysisDeviceRevision`, `dayScanFingerprint`) record which inputs changed so an
unchanged day is not scored again.

**Energy model** (v45–v50, v71, v93) — `healthEnergyBucket` (a bounded five-minute Apple Health reference
stream, Apple Watch buckets only eligible), `whoopDailyEnergy` (the derived WHOOP-first daily total
and its evidence/context mix), `whoopEnergyHourly` (the hourly active-energy shape), `whoopEnergyBucket`
(the auditable five-minute output) and `energyCalibrationModel` (the opt-in, bounded Apple-Watch-reference
calibration fit). Kept deliberately separate from `dailyMetric`/`appleDaily` so no import or refit
can silently change another table's number — see `docs/DATA_MODEL.md` §Energy model tables and
`docs/ANALYTICS.md` §Daily energy.

**Training, strength and food** — the native training tables (`trainingWorkoutNative`, routines, programs,
schedules, session load and ratings), the Hevy tables (`hevy*`), the lift log (`lift*`), workout side tables
(`workoutSourceMetadata`, `workoutHeartRateFill`, `workoutElevation`, …), and the food log (`food*`). These
are the wearer's own inputs plus fusion and load tables derived from them.

**Other** — `ouraRaw` (verbatim Oura API pages), `ecgReading` and `ecgReadingPacket` (saved MG ECG readings),
the Health-export change tracking tables, and the fork's `goalPreferenceState`, `hostInputOwnership`,
`dismissedWorkout`, `dismissedSleep` and `coachMessage` (the last three are used by Android and stay empty on
Apple).

**Analysis recipe.** Derived values carry a lineage: `AnalysisRecipe.currentVersion` (in
`Packages/StrandCore`, currently `39`, numbered AI-n) names the meaning of the stored derived values. The
recipe cursor (`noopai:analysisRecipeVersion` in `cursors`) records which recipe the stored rows were
computed under. When the code's recipe is newer, one rebuild (`AnalysisRecipe.RebuildStep`: legacy input
repairs, AgeLess reset, workout peaks, daily history, weekly scores, stress proxy, rhythm days, workout
heart rate, cardio load, energy history, publish) scores every day with raw strap data again and rebuilds the
derived tables from the stored inputs, resuming at the step it was in and writing the recipe cursor only
after the last one. Raw samples and values an import or the wearer supplied are never replaced. The rules for
when to bump it are in [`fork/AGENT_RULES.md`](fork/AGENT_RULES.md).

`deviceId` is the per-source partition key. The app uses `"my-whoop"` for the strap and
`"apple-health"` for imported Apple Health, so per-source pages and cross-source "consensus" views
read the same tables filtered by source.

---

## 8. Imports (StrandImport)

Imports converge on the *same* store as the BLE paths, so history lights up instantly. The diagram shows
the two oldest lanes; `StrandImport` also parses Oura, Fitbit, Garmin and Xiaomi exports, FIT/GPX/TCX
activity files, lab and nutrition files and lifting sheets:

```
URL (export.zip / *.csv / export.xml / folder)
  └─▶ ImportCoordinator.detectKind  → .whoopExport | .appleHealth
        ├─ WhoopExportImporter   → cycles/sleeps/workouts/journal  → WhoopImporter      → store rows
        └─ AppleHealthImporter   → streamed export.xml (aggregated) → AppleHealthImport  → store rows
```

`StrandImport` is **parse-only**; the app's `WhoopImporter`/`AppleHealthImport` glue maps the
normalized results into `dailyMetric`, `sleepSession`, `workout`, `appleDaily`, and `metricSeries`
rows, then calls `Repository.refresh()`. Apple Health's `export.xml` is parsed with a streaming
reader so multi-hundred-MB files don't blow up memory.

---

## 9. Analytics (StrandAnalytics)

`AnalyticsEngine.analyzeDay(...)` is a pure function: given a day's raw streams (`hr`, `rr`, `resp`,
`gravity`), a `UserProfile`, and personal `ProfileBaselines`, it runs the analyzers and returns a
`DayResult`:

- **`SleepStager`** detects in-bed sessions and stages them (deep/REM/light), producing per-session
  efficiency, resting HR, average HRV, and a hypnogram.
- **`RecoveryScorer`** normalizes nightly HRV/RHR (and a sleep-performance proxy) against baselines
  into a `0–100` score.
- **`StrainScorer`** integrates the day's HR window into a `0–21` cardiovascular load (Tanaka HRmax
  from age unless overridden).
- **`WorkoutDetector`** segments exercise bouts from HR + motion.
- **`Baselines`**, **`HRZones`**, **`CorrelationEngine`**, **`ComparisonEngine`**, and
  **`BehaviorInsights`** supply rolling baselines, zone math, and cross-metric/behaviour insights.
- **`EnergyEngine`**, **`WhoopEnergyModel`**, **`EnergyCalibrationEngine`**, and
  **`AdaptiveExpenditureEngine`** compute the day's energy expenditure: a single non-summed source
  per day, a WHOOP-first five-minute bucket model with an explicit evidence mix, an opt-in bounded
  Apple Watch reference calibration, and a separate retrospective TDEE from imported intake + weight
  trend. Detail: `docs/ANALYTICS.md` §Daily energy.

Because the engine never touches the database, the same code runs over live-collected streams,
backfilled streams, or imported data interchangeably. **All derived values are approximate.**

The analyzers are driven by the daily analysis pass in `StrandCore` (`AnalysisHost`, `DailyAnalysis`), which
reads the stored inputs, scores each day, writes the derived rows back and publishes the screens' snapshot.
That pass runs identically on the Apple apps and, through `NoopCoreJNI`, on Android. When a change makes
existing derived values stale it bumps `AnalysisRecipe.currentVersion`, and the next launch rebuilds them
from the stored inputs (section 7).

---

## 10. Presentation (Strand app + StrandDesign)

On macOS, `StrandApp` (`@main`) builds a single `AppModel`, injects it plus `LiveState`, `Repository`,
`ProfileStore`, and `BehaviorStore` into the environment, and presents a `WindowGroup` (dark, hidden
title bar) alongside a glanceable `MenuBarExtra`. `RootView` is a `NavigationSplitView` whose sidebar
is the `NavItem` enum (`Strand/App/RootView.swift`), organized into five collapsible `NavGroup`s
rather than one flat list:

| Group | Items |
| --- | --- |
| **Today** | Today, Goal & Journey |
| **Sleep** | Sleep |
| **Body** | Training, Workouts, Strength, Cardio, Training Load, Body, Energy (`energyPlan`), Live, Health, Stress, Intervals, Breathe |
| **Insights** | Momentum, Intelligence, What Moves You (`insightsHub`), Coach, Explore, Compare, Insights (the journal), Lab Book, Rhythm, Saved ECGs, Trends |
| **Data & App** | Devices, NOOP Limitations, Data Sources, Apple Health, Mi Band, Backup & Sync, Your Data, Fused (`fusedRecord`), Notifications, Automations, Smart Alarm, Power saving, Project (`roadmap`), Settings, Test Centre |

The macOS shell above is `RootView`. On iOS the shell is `RootTabView` (`StrandiOS/App/`), whose tabs host
the Forge screens (`StrandiOS/Forge/`); the destinations are the same features reached through a tab bar and
a More catalogue (`MoreCatalog.swift`).

`NavGroup.group(containing:)` auto-expands the group that owns the current destination on launch/
routing. See `docs/FEATURES.md` for what each destination does; several (Coach, Goal & Journey) are
fork-only and documented in full in `docs/fork/COACH.md` rather than duplicated there.

Screens bind to `Repository`'s published `days`/`sleeps` caches (refreshed on data change, not on the
~1 Hz stream) and render with `StrandDesign` components — `RecoveryRing`, `StrainGauge`, `Hypnogram`,
`TrendChart`, `Sparkline`, `YearHeatStrip` — over the `StrandPalette` tokens. `AppModel` also hosts
the opt-in, on-device behaviours (HR smoothing, illness/strain early-warning, stress nudges, HR-zone
haptic coaching, double-tap actions, wrist-wear automation, smart alarm) — all default-off and all
computed locally.

---

## 11. Design principles, restated

1. **Offline collection and analytics.** The strap → SQLite → scoring pipeline needs no network
   connection. App HTTP clients and platform services are documented in the canonical
   [privacy inventory](PRIVACY_SECURITY.md#11-network-paths-canonical-inventory).
2. **Decoded-first durability.** Metrics are committed before raw is queued; the raw outbox is a
   prunable convenience, never the source of truth.
3. **Resumable safe-trim.** The strap forgets historical data only after NOOP has it durably and has
   confirmed the ack; a durable cursor makes every offload resumable.
4. **Pure cores, thin shell.** `WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, and `StrandImport`
   are platform-pure and testable in isolation; the app target is the only CoreBluetooth/SwiftUI
   surface.
5. **Interoperability, not impersonation.** NOOP reads your strap and your exports for your own use.
   It is independent of WHOOP and is not a medical device.

---

## Attribution

NOOP's BLE protocol work builds on community reverse-engineering of the WHOOP straps:

- **johnmiddleton12/my-whoop** — WHOOP 4.0 protocol.
- **b-nnett/goose** — WHOOP 5.0 protocol.

See [`ATTRIBUTION.md`](../ATTRIBUTION.md) for full credits and [`DISCLAIMER.md`](../DISCLAIMER.md) for
the non-affiliation and not-a-medical-device notice.

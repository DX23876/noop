# NOOP — On-Device Data Model

NOOP is an offline-first companion app for WHOOP straps (4.0 and 5.0/MG). Its biometric pipeline talks to
the user's own strap directly over Bluetooth Low Energy — no WHOOP cloud or account
is involved, and stores everything it decodes locally in a single SQLite database.
This document describes that on-device database: every table, its columns, natural keys, indexes,
and the migration history that produced the current schema.

> **Scope note.** Interacting with the strap here means interoperating with the user's *own*
> device and the data it has already recorded. NOOP is **not affiliated with, endorsed by, or
> connected to WHOOP**, and it is **not a medical device** — none of the stored values are
> intended for diagnosis or treatment.

---

## Where the database lives

The persistence layer is the `WhoopStore` Swift package
(`Packages/WhoopStore`), built on [GRDB](https://github.com/groue/GRDB.swift) over SQLite. It
declares both platforms — `.iOS(.v16)` and `.macOS(.v13)`
(`Packages/WhoopStore/Package.swift`) — and is UI-framework agnostic, so the same schema and
storage code back both the released macOS app and iOS app (see
`docs/IOS.md`).

The macOS app target opens the database at a fixed, per-user location
(`Strand/Collect/StorePaths.swift`):

```
<Application Support>/OpenWhoop/whoop.sqlite
```

```swift
// Strand/Collect/StorePaths.swift
static func defaultDatabasePath() throws -> String {
    let fm = FileManager.default
    let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                          appropriateFor: nil, create: true)
        .appendingPathComponent("OpenWhoop", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent("whoop.sqlite").path
}
```

On a typical macOS install that resolves to
`~/Library/Application Support/OpenWhoop/whoop.sqlite`. Tests use an in-memory database via
`WhoopStore.inMemory()`.

### Connection configuration

`WhoopStore.init(path:)` (`Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`) opens a
single `DatabaseQueue` and applies these PRAGMAs before any query runs:

| PRAGMA | Value | Why |
| --- | --- | --- |
| `journal_mode` | `WAL` | Two handles to the same file (the BLE collector and the metrics repository) can read/write without deadlocking. |
| `synchronous` | `NORMAL` | Durable pairing with WAL — only an OS crash or power loss can lose the last transaction. |
| `cache_size` | `-16000` | ~16 MB page cache for multi-thousand-row import/backfill writes. |
| `mmap_size` | `268435456` | 256 MB memory-mapped I/O. |
| `temp_store` | `MEMORY` | In-memory temp tables. |
| `busyMode` | `.timeout(5)` | 5-second busy timeout under write contention. |

`WhoopStore` is an `actor`: all GRDB calls run on the actor's serial executor (off the main
thread) through the `syncRead` / `syncWrite` helpers. `WhoopStore.schemaVersion` is a
separate, manually-maintained constant (currently `21`) that has lagged the real migration
history and must not be read as the schema's true version. The migrator itself (`makeMigrator()`,
below) is the source of truth for what tables/columns exist and currently runs through
**`v49-whoop-energy-context`**.

---

## Schema at a glance

The schema falls into the groups below. The migration table is intentionally a selected history;
`Database.swift` remains authoritative for every intermediate migration.

| Group | Tables | Origin |
| --- | --- | --- |
| **Device registry** | `device` | BLE pairing |
| **Decoded streams** (durable) | `hrSample`, `rrInterval`, `event`, `battery`, `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`, `ppgWaveformSample` (v27, unconsumed instrumentation) | Decoded from strap frames on-device |
| **Raw outbox** (transient) | `rawBatch` | Compressed raw BLE frames, prunable |
| **Bookkeeping** | `cursors`, `analysisInputRevision`, `analysisDeviceRevision`, `dayScanFingerprint` | Highwater marks and exact analysis-cache invalidation |
| **Metric caches** | `sleepSession`, `dailyMetric`, `journal`, `workout`, `appleDaily`, `appleStepHour` (v41), `bodyWeightEntry` (v43), `metricSeries`, `scoreInputProvenance` | Derived metrics + their input-provider provenance + CSV / Apple-Health imports |
| **Energy model** (v45–v49) | `healthEnergyBucket`, `whoopDailyEnergy`, `whoopEnergyHourly`, `energyCalibrationModel` | WHOOP-first daily energy, its evidence/context mix, the hourly profile behind the personal day curve, and an opt-in Apple Watch reference calibration — see below |
| **Oura raw archive** (durable, v25) | `ouraRaw` | Verbatim Oura API payloads behind the opt-in cloud import — see below |

All timestamp columns named `ts`, `startTs`, `endTs`, `capturedAt`, etc. are **unix seconds**
(integers). Day-keyed cache tables use a `day` text column in `YYYY-MM-DD` form and compare it
lexicographically.

---

## Migration history

Migrations are registered in `Packages/WhoopStore/Sources/WhoopStore/Database.swift`
(`makeMigrator()`) and run in order on every open.

| Version | What it adds |
| --- | --- |
| **v1** | Core tables: `device`, the four original decoded streams (`hrSample`, `rrInterval`, `event`, `battery`), and the raw outbox `rawBatch`. |
| **v2** | `cursors` key/value table for highwater bookkeeping. |
| **v3** | Type-47 biometric streams: `spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`. |
| **v4** | Local metric caches: `sleepSession` (one row per session) and `dailyMetric` (one row per calendar day). |
| **v5** | Adds a `synced` integer column (default `0`) to all eight decoded-stream tables. **Vestigial** — see below. |
| **v6** | Adds nullable `charging` boolean to `battery` for the dense BATTERY_LEVEL series. |
| **v7** | Adds in-sleep signal aggregates to `dailyMetric`: `spo2Pct`, `skinTempDevC`, `respRateBpm` (all nullable). |
| **v8** | Adds `journal`, `workout`, and `appleDaily` (Apple-Health daily aggregates). |
| **v9** | Adds the generic long-format `metricSeries` table and its `(deviceId, key, day)` index. |
| **v24-rr-seq** | Rebuilds the `rrInterval` primary key as `(deviceId, ts, rrMs, seq)`, so an identical interval recurring within one second is no longer dropped. |
| **v29-score-input-provenance** | Adds metric-level `scoreInputProvenance` for NOOP-computed headline scores. It does not change `dayOwnership` or score precedence. |
| **v30-rr-ord** | Adds the nullable `rrInterval.ord` column — emission order within a `ts` — and makes it lead the read sort (#823/#830). Additive; pre-existing rows keep `ord` NULL. |
| **v38-day-scan-fingerprint** | Adds per-local-day analysis fingerprints so unchanged raw windows can reuse their persisted computed rows. |
| **v39-day-scan-traits** | Adds nullable learned-trait carry values to the fingerprint. Missing values deliberately make a legacy fingerprint stale. |
| **v40-analysis-input-revision** | Adds UTC-day input revisions, per-device revisions, and nullable scoring/semantic fingerprint fields. All additions are backward-compatible; derived output writes do not advance the input revision. |
| **v41-apple-step-hour** | Adds `appleStepHour` — hour-bucketed imported step counts, the movement-coverage signal behind the Energy card's "hours with movement" figure. Renumbered from upstream's `v38-apple-step-hour`; created `ifNotExists` so a fork database that already has the table under either identifier converges cleanly. |
| **v42-ppg-burst-index** | Adds nullable `ppgWaveformSample.burstIndex`, the per-burst counter beside the raw PPG waveform (#979). Existing rows keep it `NULL` — the counter predates this column and can't be reconstructed. |
| **v43-body-weight** | Adds `bodyWeightEntry` — dated, sourced (`manual` / `appleHealth` / `imported`) weight measurements, editable/deletable by a client-generated `id`. Feeds `CausalWeightResolver` (per-day body weight for the energy model), trend weight, and goal tracking. Apple Health weights are read live, not copied in — `Repository.weightSeries()` unions the two per day. A prototype-marker check (`v42-body-weight`) lets a pre-merge internal build converge without a duplicate-table failure. |
| **v44-energy-coverage** | Adds nullable `dailyMetric.energyCoverageSeconds` — the number of distinct HR seconds behind the strap's whole-day calorie estimate, so `EnergyEngine` can tell a fully-covered day from a short intense one instead of guessing from the kcal figure alone. Nullable so imported/pre-v44 rows stay honestly "unknown." Same prototype-marker leniency as v43 (`v43-energy-coverage`). |
| **v45-health-energy-buckets** | Adds `healthEnergyBucket` — a separate, five-minute Apple Health **reference** stream used only to calibrate the WHOOP energy model (see below). Never folded into `dailyMetric`; importing it cannot by itself change the daily total. |
| **v46-whoop-daily-energy** | Adds `whoopDailyEnergy` — the derived WHOOP-first daily estimate with its evidence mix (observed/inferred/modeled seconds) and model version, kept separate from the imported `dailyMetric` contract. |
| **v47-energy-calibration-model** | Adds `energyCalibrationModel` — the opt-in, per-device Apple Watch calibration fit (bounded factor, sample size, fit quality). Row absence means disabled; an explicit `enabled` flag lets a user pause without discarding a hard-won fit. |
| **v48-whoop-energy-hourly** | Adds `whoopEnergyHourly` — one day's ACTIVE energy at hourly resolution, written by the same bucket pass as `whoopDailyEnergy`. The substrate for the personal time-of-day activity curve that replaced the linear day forecast. Additive, no existing row touched. |
| **v49-whoop-energy-context** | Adds `representedSeconds`, `physiologicalSeconds`, and `contextJSON` to `whoopDailyEnergy`. v4 can keep HR evidence distinct from quiet-HR physiology while giving `EnergyEngine` the exact wall-time denominator whose basal share is already inside the total. Defaults preserve old rows, which version filtering ignores until the atomic 120-day recompute replaces them. |

> This table is a selection, not the full list — it covers the migrations the tables above refer to.
> The registered set is the authority. Migrations are keyed by their **identifier string**, not by
> the number in it, so renaming one re-runs it against an already-migrated database. Cite the
> identifier in full — `v30-rr-ord`, not "v30".

### The vestigial `synced` column

Migration v5 added a per-row `synced` integer (`NOT NULL DEFAULT 0`) to each of the eight
decoded-stream tables. It dates from a since-removed server-upload feature. **NOOP is fully
offline: nothing writes or reads `synced`.** The insert path explicitly never sets it
(`StreamStore.swift`), and no read query references it. The column is left in place only to avoid
a `DROP COLUMN` migration over potentially millions of existing rows. Treat it as dead schema.

---

## Device registry

### `device` *(v1)*

One row per strap the app has seen. Natural key is the device `id`.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | TEXT | **Primary key.** Stable device identifier. |
| `mac` | TEXT | BLE MAC address (nullable). |
| `name` | TEXT | Advertised/device name (nullable). |
| `firstSeen` | INTEGER | Unix seconds, set on first insert. |
| `lastSeen` | INTEGER | Unix seconds, bumped on every upsert. |

`upsertDevice(id:mac:name:)` (`StreamStore.swift`) inserts or, on `id` conflict, updates `mac`,
`name`, and `lastSeen` (it does not touch `firstSeen`). Every other table references the strap via
a `deviceId` text column, scoping all data per device.

---

## Decoded streams (durable record)

These eight tables are the **durable, compact local record** of what the strap measured. They are
decoded on-device from BLE frames by the `WhoopProtocol` package and written by
`WhoopStore.insert(_ streams:deviceId:)` (`StreamStore.swift`). The in-memory shapes are the
`WhoopProtocol` stream structs (`Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift`):
`HRSample`, `RRInterval`, `WhoopEvent`, `BatterySample`, `SpO2Sample`, `SkinTempSample`,
`RespSample`, `GravitySample`, aggregated into `Streams`.

All inserts are **idempotent by natural key** — they use `ON CONFLICT(...) DO NOTHING`, so
re-decoding overlapping frames (the common case during BLE backfill) never duplicates rows.
`insert(...)` returns the count of rows *actually* inserted per stream. Range reads live in
`Reads.swift` and follow a uniform shape: `WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts
ASC LIMIT ?`.

> The biometric stream structs carry a constant `unit` field (`"raw_adc"` / `"g"`) for JSON
> parity with golden fixtures, but `unit` is **not** a database column — only the numeric fields
> below are persisted.

### `hrSample` *(v1)* — heart rate

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Wall-clock unix seconds. Part of PK. |
| `bpm` | INTEGER NOT NULL | Beats per minute. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`. HR is taken only from `REALTIME_DATA` (type 40) frames.
`latestHRSampleTs(deviceId:)` returns `MAX(ts)` here — the biometric "data frontier" used by the
stuck-strap watchdog.

### `rrInterval` *(v1)* — R-R intervals (HRV source)

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Wall-clock unix seconds. Part of PK. |
| `rrMs` | INTEGER NOT NULL | Beat-to-beat interval, milliseconds. Part of PK. |
| `seq` | INTEGER NOT NULL DEFAULT 0 | *(v24)* Repeat counter for an **identical** beat. Part of PK. |
| `ord` | INTEGER | *(v30)* Emission order within `ts`. Nullable; **not** in the PK. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts, rrMs, seq)` — `rrMs` is in the key because multiple R-R intervals can
share a single `REALTIME_DATA` timestamp, and `seq` because the same interval value can legitimately
recur within that second. `seq` keys on `(ts, rrMs)`, **not** `ts` alone: every *distinct* interval in
a second therefore carries `seq = 0` and keeps its own key, so a distinct beat is never dropped when a
second arrives across separate insert batches or via the live/historical merge. A `ts`-only counter
would restart per batch and collide distinct beats — a data-loss regression.

**Read order:** `ts ASC, ord ASC, rrMs ASC, seq ASC`
(`Reads.swift` `rrIntervals`).

`ord` leads the sort because ordering by `rrMs` returned a second's beats sorted by **value**, which
makes successive beats similar by construction and biases RMSSD — built entirely from successive
differences — downward (#823, fixed in #830). `ord` is the beat's position among all beats sharing its
`ts`, stamped at decode time. It is deliberately **not** in the key, for the reason above.

Two properties of `ord` a consumer has to know:

- **Pre-v30 rows have `ord` NULL.** The order was never recorded and cannot be backfilled. SQLite
  sorts NULL first in ASC, so an all-legacy second ties on `ord` and falls through to the old
  `(rrMs, seq)` order — i.e. existing data reads back exactly as before, with the #823 bias intact.
  No `COALESCE`, no sentinel.
- **`ord` is batch-local.** A second split across two live flushes restarts `ord` at 0, and
  `ON CONFLICT DO NOTHING` keeps whichever row landed first, so that second also falls back to
  magnitude order. The historical offload path delivers a second atomically and is unaffected.

`ord` is a storage/read-order key only. The public Swift read returns `ts, rrMs`; no current consumer
receives or interprets `ord` directly.

### `event` *(v1)* — strap events

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Real RTC unix seconds (never offset). Part of PK. |
| `kind` | TEXT NOT NULL | Event name (e.g. `BATTERY_LEVEL(3)`). Part of PK. |
| `payloadJSON` | TEXT NOT NULL | Decoded payload as JSON. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts, kind)`. `payloadJSON` is serialized with `JSONEncoder`'s
`.sortedKeys` so the same payload is byte-identical every time — important for the natural-key
dedupe. Reads decode it back into `[String: ParsedValue]` with a shared, reused decoder.

### `battery` *(v1, +charging in v6)*

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Event RTC for BATTERY_LEVEL events, else `wallClockRef`. Part of PK. |
| `soc` | DOUBLE | State of charge (%), nullable. |
| `mv` | INTEGER | Millivolts, nullable. |
| `charging` | BOOLEAN | *(v6)* Nullable — only the dense BATTERY_LEVEL event series reports it; the command-response path leaves it `NULL`. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`. (Note: `batterySamples(...)` reads back only `ts, soc, mv`.)

### Type-47 biometric streams *(v3)*

These four mirror the original streams (per-row natural key `(deviceId, ts)`, `DO NOTHING`
inserts, identical range-read shape).

#### `spo2Sample` — pulse oximetry raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `red` | INTEGER NOT NULL | Red LED raw ADC. |
| `ir` | INTEGER NOT NULL | IR LED raw ADC. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

#### `skinTempSample` — skin temperature raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `raw` | INTEGER NOT NULL | Raw ADC reading. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

#### `respSample` — respiration raw ADC

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `raw` | INTEGER NOT NULL | Raw ADC reading. |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

#### `gravitySample` — accelerometer / gravity vector

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `x` | DOUBLE NOT NULL | Gravity vector X (g). |
| `y` | DOUBLE NOT NULL | Gravity vector Y (g). |
| `z` | DOUBLE NOT NULL | Gravity vector Z (g). |
| `synced` | INTEGER NOT NULL DEFAULT 0 | *(v5, vestigial)* |

**Primary key:** `(deviceId, ts)`.

### `ppgWaveformSample` *(v27, +`burstIndex` v42)* — raw PPG waveform, deliberately unconsumed

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `ts` | INTEGER NOT NULL | Unix seconds. Part of PK. |
| `samples` | BLOB NOT NULL | The raw optical waveform for this second. |
| `burstIndex` | INTEGER | *(v42)* Per-burst counter beside the waveform it segments (#979). Nullable — pre-v42 rows can't be reconstructed. |

**Primary key:** `(deviceId, ts)`. **Deliberately has zero production readers** — the writer is
live (offload + archive replay + the Android capture importer), but nothing derives a score, UI
value, or export from it. This is intentional, not dead code: `CLAUDE.md`'s rule is that unvalidated
sensor work lands as *instrumentation* (decode + store the original samples, never a score) so a
later, properly-validated estimator or waveform viewer has real data to run over — see the withdrawn
PPG→HR estimate (#194) for why. The derived, actually-consumed value is the separate `ppgHrSample`
(v12) per-second HR estimate, computed in memory and never read back from this table.

---

## Raw outbox (transient, prunable)

### `rawBatch` *(v1)*

The raw outbox stores the strap's original BLE frames — compressed and batched — so the exact
bytes survive even for frames NOOP can't yet fully decode. Whereas the decoded streams are durable,
raw batches are **transient and prunable**. Implementation in `RawOutbox.swift`.

| Column | Type | Notes |
| --- | --- | --- |
| `batchId` | TEXT | **Primary key.** |
| `deviceId` | TEXT NOT NULL | Owning strap. |
| `capturedAt` | INTEGER NOT NULL | Unix seconds the batch was captured; pending reads order by this. |
| `deviceClockRef` | INTEGER NOT NULL | Strap-clock reference for the wall-clock offset. |
| `wallClockRef` | INTEGER NOT NULL | Wall-clock reference, unix seconds. |
| `startTs` | INTEGER NOT NULL | First frame timestamp in the batch. |
| `endTs` | INTEGER NOT NULL | Last frame timestamp in the batch. |
| `frameCount` | INTEGER NOT NULL | Number of frames packed. |
| `byteSize` | INTEGER NOT NULL | Size used for `storageStats()` totals. |
| `framesBlob` | BLOB NOT NULL | zlib-compressed packed frames (length-prefixed). |
| `syncedAt` | INTEGER | Unix seconds; `NULL` until marked. |

**Primary key:** `batchId`. Frames are packed as `[count u32 LE]{[len u32 LE][bytes]}×count`,
then zlib-compressed with a 4-byte uncompressed-length prefix.

**Pruning policy** (`pruneRaw(now:keepWindowSeconds:maxUnsyncedBytes:)`): only batches with a
non-null `syncedAt` older than `now - keepWindowSeconds` are deleted — safe because the decoded
streams persist separately. Unsynced raw is **never** dropped (it is the sole copy of the strap's
not-yet-decoded bytes after a chunk is trimmed). `maxUnsyncedBytes` is accepted for call-site
compatibility but intentionally unused.

---

## Bookkeeping

### `cursors` *(v2)*

A simple key/value table for incremental-processing highwater marks (`Cursors.swift`).

| Column | Type | Notes |
| --- | --- | --- |
| `name` | TEXT | **Primary key.** |
| `value` | INTEGER | Stored cursor value (typically a timestamp). |

Helpers namespace the `name`: `highwater:<stream>` (upload/forward-only highwater) and
`read:<stream>` (pull cursor). The distinct prefixes keep the two cursor families from colliding
for the same stream.

### Analysis input revisions *(v40)*

`analysisInputRevision(deviceId, utcDay, revision)` stores the monotonic revision assigned to each
UTC-day bucket that actually changed. `analysisDeviceRevision(deviceId, revision)` invalidates a
whole device after repointing or a broad delete. Both revisions are updated in the same transaction
as the scoring-relevant insert, update or delete.

The per-local-day `dayScanFingerprint` combines the maximum revision across its exact analysis
window with the device revision, owner, scoring version, semantic/profile signature and baseline
carry values. A missing v40 field means “legacy/stale”; it is never accepted as proof that a day is
unchanged. Engine-produced daily metrics, metric series, detected workouts and computed sleep rows
do not move these revisions, preventing analysis from invalidating itself.

---

## Metric caches

These tables hold **derived metrics and imported aggregates** rather than raw measurements.
Recovery / strain / HRV / sleep math is computed locally by the `StrandAnalytics` package, and
CSV / Apple-Health data arrives through `StrandImport`. Every cache table follows the same
contract: a `Codable` struct, an idempotent `ON CONFLICT(...) DO UPDATE` upsert keyed by its
natural key (latest value wins), and range-read accessors that run off-main.

### `sleepSession` *(v4)*

One row per sleep session (`MetricsCache.swift`, `struct CachedSleepSession`).

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `startTs` | INTEGER NOT NULL | Session start, unix seconds. Part of PK. |
| `endTs` | INTEGER NOT NULL | Session end, unix seconds. |
| `efficiency` | DOUBLE | Sleep efficiency, nullable. |
| `restingHr` | INTEGER | Resting HR, nullable. |
| `avgHrv` | DOUBLE | Average HRV, nullable. |
| `stagesJSON` | TEXT | Verbatim JSON array of stage segments (`[{start,end,stage}]`), nullable — stored as a string so the cache stays schema-agnostic about staging shape. |

**Primary key:** `(deviceId, startTs)`. Read by `startTs` range, oldest first.

### `dailyMetric` *(v4, +v7 columns)*

One row per calendar day (`MetricsCache.swift`, `struct DailyMetric`). This is the central
per-day rollup behind the dashboard. **Natural key `(deviceId, day)`** where `day` is
`YYYY-MM-DD`. All metric columns are nullable.

| Column | Type | Migration | Notes |
| --- | --- | --- | --- |
| `deviceId` | TEXT NOT NULL | v4 | Part of PK. |
| `day` | TEXT NOT NULL | v4 | `YYYY-MM-DD`. Part of PK. |
| `totalSleepMin` | DOUBLE | v4 | Total sleep, minutes. |
| `efficiency` | DOUBLE | v4 | Sleep efficiency. |
| `deepMin` | DOUBLE | v4 | Deep sleep, minutes. |
| `remMin` | DOUBLE | v4 | REM sleep, minutes. |
| `lightMin` | DOUBLE | v4 | Light sleep, minutes. |
| `disturbances` | INTEGER | v4 | Disturbance count. |
| `restingHr` | INTEGER | v4 | Resting heart rate. |
| `avgHrv` | DOUBLE | v4 | Average HRV. |
| `recovery` | DOUBLE | v4 | Recovery score. |
| `strain` | DOUBLE | v4 | Day strain. |
| `exerciseCount` | INTEGER | v4 | Number of exercises. |
| `spo2Pct` | DOUBLE | v7 | Mean SpO2 (%) during sleep. |
| `skinTempDevC` | DOUBLE | v7 | Skin-temperature deviation (°C) from baseline. |
| `respRateBpm` | DOUBLE | v7 | Mean respiration rate (breaths/min) during sleep. |
| `energyCoverageSeconds` | INTEGER | v44 | Distinct HR seconds behind `activeKcalEst` — lets `EnergyEngine` tell a fully-covered day from a short intense one. |

**Primary key:** `(deviceId, day)`. Read by lexicographic `day` range, oldest first. The
`DailyMetric` struct's `init` defaults the three v7 fields to `nil` so older callers stay
source-compatible.

### `journal` *(v8)*

One user-answered daily prompt (`JournalWorkoutAppleCache.swift`, `struct JournalEntry`).

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `question` | TEXT NOT NULL | Prompt text. Part of PK. |
| `answeredYes` | INTEGER NOT NULL | `0`/`1`, mapped to/from `Bool`. |
| `notes` | TEXT | Free-text note, nullable. |

**Primary key:** `(deviceId, day, question)`. Read by `day` range, ordered `day ASC, question
ASC`.

### `workout` *(v8)*

One workout (`JournalWorkoutAppleCache.swift`, `struct WorkoutRow`). All metric columns nullable.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `startTs` | INTEGER NOT NULL | Start, unix seconds. Part of PK. |
| `endTs` | INTEGER NOT NULL | End, unix seconds. |
| `sport` | TEXT NOT NULL | Sport/activity name. Part of PK. |
| `source` | TEXT NOT NULL | Origin of the row (e.g. import source). |
| `durationS` | DOUBLE | Duration, seconds. |
| `energyKcal` | DOUBLE | Energy, kcal. |
| `avgHr` | INTEGER | Average HR. |
| `maxHr` | INTEGER | Max HR. |
| `strain` | DOUBLE | Workout strain. |
| `distanceM` | DOUBLE | Distance, meters. |
| `zonesJSON` | TEXT | Verbatim JSON of HR-zone percentages — stored as a string so the cache stays schema-agnostic about zone shape. |
| `notes` | TEXT | Free-text note. |

**Primary key:** `(deviceId, startTs, sport)`. Read by `startTs` range, oldest first.

### `appleDaily` *(v8)*

Apple-Health-specific daily aggregates (`JournalWorkoutAppleCache.swift`, `struct AppleDaily`),
imported from an Apple Health `export.xml`. All metric columns nullable.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `steps` | INTEGER | Step count. |
| `activeKcal` | DOUBLE | Active energy, kcal. |
| `basalKcal` | DOUBLE | Basal energy, kcal. |
| `vo2max` | DOUBLE | VO₂max estimate. |
| `avgHr` | INTEGER | Average HR. |
| `maxHr` | INTEGER | Max HR. |
| `walkingHr` | INTEGER | Walking HR average. |
| `weightKg` | DOUBLE | Body weight, kilograms. |

**Primary key:** `(deviceId, day)`. Read by lexicographic `day` range, oldest first.

`activeKcal`/`basalKcal` are arbitrated **per source, never summed**: an iPhone and an Apple Watch
both writing "active energy" for the same day are measuring the same overlapping activity, so
`AppleHealthAggregator.preferredEnergyTotal` sums *within* a source and then takes the Watch's
total when present, else the single largest source — the same de-overlap Apple's own Health app
applies, and the rule steps import uses for `steps` on this table.

### `appleStepHour` *(v41)*

Hour-bucketed imported step counts — the movement-coverage signal behind the Energy card's "hours
with movement" figure (`docs/ANALYTICS.md` §Daily energy) and finer-grained than `appleDaily.steps`.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. `"apple-health"` in practice. |
| `ts` | INTEGER NOT NULL | Hour-start, unix seconds, local-hour aligned by HealthKit. Part of PK. |
| `steps` | INTEGER NOT NULL | Steps in that hour. |

**Primary key:** `(deviceId, ts)`. Created `ifNotExists`, renumbered from upstream's
`v38-apple-step-hour` since this fork's v38–v40 already occupy those identifiers — a fork database
that already carries the table under either identifier converges cleanly.

### `bodyWeightEntry` *(v43)*

Body weight as a real **measurement series**, not a single profile field — dated, sourced,
editable/deletable readings (`struct BodyWeightEntry`), modelled on `labMarker` (v17). Feeds trend
weight, weekly rate, goal tracking (`docs/fork/COACH.md` §4), and `CausalWeightResolver` (the
per-day body weight the WHOOP energy model resolves — `docs/ANALYTICS.md` §Daily energy). Apple
Health weights are deliberately **not** copied in here — HealthKit samples are mutable/deletable
after the fact, so `Repository.weightSeries()` unions this table with Apple Health per day instead,
the same "one source wins a day, never a sum" rule `sourceCandidates` uses for every other metric.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | TEXT | **Primary key.** Client-generated stable id, so one reading can be edited/deleted by id and a backup round-trips. |
| `deviceId` | TEXT NOT NULL | |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`, the pre-derived projection key (`metricSeries` key `"weight"` under the `noop-weight` source id). |
| `takenAt` | INTEGER NOT NULL | Precise instant, unix seconds. |
| `weightKg` | DOUBLE NOT NULL | |
| `source` | TEXT NOT NULL | `manual` / `appleHealth` / `imported`. |
| `note` | TEXT | Nullable free-text note. |

**Indexes:** `idx_bodyWeightEntry_natural` **unique** on `(deviceId, takenAt, source)` — one
measurement per instant-per-source, so re-importing/re-logging the same reading updates rather than
duplicates; `idx_bodyWeightEntry_device_takenAt` on `(deviceId, takenAt)` for ordered history reads.
Additive only — a new table, no existing row touched.

### `metricSeries` *(v9)*

A generic **long-format / EAV** metric store (`MetricSeriesStore.swift`, `struct MetricPoint`).
Where the tables above use a wide column-per-metric layout, this is the tall counterpart: one row
per `(deviceId, day, key)` with a single REAL `value`. Any scalar metric — server-derived,
Apple-Health, journal-encoded, etc. — can be projected into this one table and read back uniformly
by key, which is the substrate for a metric explorer that lists and compares metrics without
knowing each source's schema.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `key` | TEXT NOT NULL | Metric identifier (e.g. `"restingHr"`, `"steps"`, `"recovery"`). Part of PK. |
| `value` | DOUBLE NOT NULL | The scalar value. |

**Primary key:** `(deviceId, day, key)`.

**Index** — `idx_metricSeries_device_key_day` on `(deviceId, key, day)`. The primary key orders by
`day` before `key`, so it can't efficiently serve per-metric range reads (`metricSeries(key:from:
to:)`) or `metricDays(key:)`, which scan `(deviceId, key)` and then walk days. This index makes
those reads index-only. Accessors: `upsertMetricSeries(...)`, `metricSeries(...)`,
`metricKeys(...)` (distinct keys for a device), and `metricDays(...)` (`MIN`/`MAX` day per key).

### `scoreInputProvenance` *(v29)*

Records which sensor/import source supplied the inputs for each persisted NOOP-computed score.
This is deliberately separate from `dayOwnership`, which remains a scoring resolver override.
Rows are replaced atomically with the corresponding `dailyMetric` / `metricSeries` score writes;
legacy scores without a row have unknown provenance and the UI omits their provider badge.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Computed `-noop` namespace. Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `key` | TEXT NOT NULL | `recovery`, `strain`, or `sleep_performance`. Part of PK. |
| `sourceId` | TEXT NOT NULL | Physical device or import source that supplied the inputs. |

**Primary key:** `(deviceId, day, key)`. **Index:** `idx_scoreInputProvenance_source` on
`sourceId`, used when a provider's data is deleted.

---

## Energy model tables

The Energy card (`Strand/Screens/EnergyCard.swift`) and `EnergyEngine` (`docs/ANALYTICS.md` §Daily
energy) read `dailyMetric`/`appleDaily` above plus these four tables. All four are additive and
keep WHOOP-derived and Apple-Health-derived energy data in separate rows — none of them is ever
folded into `dailyMetric`, so importing or recomputing one cannot silently change another.

### `healthEnergyBucket` *(v45)*

A bounded, five-minute **Apple Health reference stream**, used only to calibrate the WHOOP energy
model (`EnergyCalibrationModelStore.swift`/`EnergyCalibrationStore.swift`, `struct
HealthEnergyBucketRow`). Deliberately contains no raw HealthKit identifiers or per-second samples —
just per-source, per-bucket aggregates. `sourceKind` is coarse provenance (`appleWatch`, `iPhone`,
`noop`, `thirdParty`, `unknown`); only `appleWatch` rows are eligible to teach a calibration fit.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. `"apple-health"` in practice. |
| `sourceId` | TEXT NOT NULL | Normalized per-app/device source id (bundle + product + name). Part of PK. |
| `sourceKind` | TEXT NOT NULL | `appleWatch` / `iPhone` / `noop` / `thirdParty` / `unknown`. |
| `bucketStart` | INTEGER NOT NULL | Unix seconds, floored to the 300 s bucket. Part of PK. |
| `activeKcal` | DOUBLE | Nullable. Sanitized to `0...2,000`. |
| `basalKcal` | DOUBLE | Nullable. Sanitized to `0...1,000`. |
| `averageHr` | DOUBLE | Nullable. Sanitized to `20...260`. |
| `steps` | INTEGER | Nullable. Sanitized to `0...5,000`. |
| `distanceM` | DOUBLE | Nullable. Sanitized to `0...10,000`. |
| `strideM` | DOUBLE | Nullable. Sanitized to `0.2...3.0`. |
| `workout` | BOOLEAN NOT NULL | Default `false`. |
| `coverageSeconds` | INTEGER NOT NULL | Default `0`, clamped `0...300` — how much of the bucket the source's samples actually covered. |
| `sampleCount` | INTEGER NOT NULL | Default `0`. |
| `quality` | DOUBLE | Nullable, clamped `0...1`. |

**Primary key:** `(deviceId, sourceId, bucketStart)`. **Index:**
`idx_healthEnergyBucket_device_time` on `(deviceId, bucketStart)`. Upserts (`ON CONFLICT DO
UPDATE`) are idempotent per source/bucket; `deleteHealthEnergyBuckets(deviceId:from:to:)` replaces
a bounded window wholesale so a Health edit/deletion converges instead of leaving stale buckets.

### `whoopDailyEnergy` *(v46)*

The derived WHOOP-first daily estimate (`WhoopDailyEnergyStore.swift`, `struct
WhoopDailyEnergyRow`) — `WhoopEnergyModel`'s output with its evidence mix, kept out of the imported
`dailyMetric` contract so a model-version bump can invalidate old rows explicitly.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`. Part of PK. |
| `rawTotalKcal` | DOUBLE NOT NULL | Model output **before** Watch calibration/basal top-up. |
| `modelVersion` | TEXT NOT NULL | Currently `"whoop-bucket-v5"` (`WhoopDailyEnergyEstimate.modelVersion`). Reads filter on it, so a superseded row is ignored rather than mixed into a trend. |
| `observedSeconds` | INTEGER NOT NULL | Seconds backed by a valid HR sample. |
| `inferredSeconds` | INTEGER NOT NULL | Seconds backed by movement without HR. |
| `modeledSeconds` | INTEGER NOT NULL | Seconds that are pure basal fill (off-wrist/sleep/no signal). |
| `uncertaintyFraction` | DOUBLE NOT NULL | `0...1`, weighted by the evidence mix. |
| `weightKg` | DOUBLE NOT NULL | Body weight used for this day's estimate. |
| `weightSource` | TEXT NOT NULL | `history` (resolved via `CausalWeightResolver`) or `profile` (fallback). |
| `representedSeconds` | INTEGER NOT NULL | Added v49, default `0`. Wall-clock seconds whose basal share is already inside `rawTotalKcal`; this, not HR coverage, is the denominator for the unrepresented-day basal top-up. |
| `physiologicalSeconds` | INTEGER NOT NULL | Added v49, default `0`. HR-backed seconds whose above-basal energy was bounded because no independent activity context existed. |
| `contextJSON` | TEXT NOT NULL | Added v49, default `{}`. Stable object keyed by `EnergyContext` raw values with per-context seconds; keeps WhoopStore independent of StrandAnalytics enums. |

**Primary key:** `(deviceId, day)`. **Index:** `idx_whoopDailyEnergy_device_day` on
`(deviceId, day)`. Upserts are conditional (`WHERE ... IS NOT excluded....`) so a re-run that
produces identical numbers doesn't spuriously bump `changesCount`. `replaceWhoopEnergyWindow`
publishes all recomputed daily and hourly rows in one transaction; one write failure rolls back the
whole model window.

### `whoopEnergyHourly` *(v48)*

One day's **active** energy at hourly resolution — the substrate for the personal time-of-day
activity profile (`ActivityShapeEngine`, see `docs/ANALYTICS.md`). Written by the same bucket pass
that produces `whoopDailyEnergy`, so it costs no extra stream reads.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. |
| `day` | TEXT NOT NULL | `YYYY-MM-DD`, **local** day. Part of PK. |
| `hour` | INTEGER NOT NULL | `0…23`, local hour. Part of PK. |
| `activeKcal` | DOUBLE NOT NULL | Active energy only — basal is excluded because it is flat by construction and would flatten the shape this table exists to measure. |

**Primary key:** `(deviceId, day, hour)`. **Index:** `idx_whoopEnergyHourly_device_day` on
`(deviceId, day)`, which is how the 42-day fit window is read.

A separate table rather than a packed column on `whoopDailyEnergy`: the fit reads a 42-day window
hour by hour, and a JSON/BLOB column would have to be decoded 42 times to answer it. Writes go
through `replaceWhoopEnergyWindow` (or the lower-level `replaceWhoopEnergyHours`), which **replaces a whole day** rather than upserting per hour — a
recomputed day must not leave a stale hour behind, which is exactly what a merge would do when the
new pass produces fewer hours than the previous one. Hours with no activity are simply absent; the
reader fills a 24-slot vector so a quiet hour reads as a real zero.

### `whoopEnergyBucket` *(v50)*

Auditable five-minute output for the current-day cumulative energy chart. Each row stores its basal
and active components, context, evidence and uncertainty. The primary key is
`(deviceId, bucketStart)` and `idx_whoopEnergyBucket_device_day` supports one-day reads. Rows are
replaced in the same `replaceWhoopEnergyWindow` transaction as the daily and hourly views, so a
recompute cannot leave stale timeline points behind.

### `energyCalibrationModel` *(v47)*

Opt-in, per-device Apple Watch calibration state (`EnergyCalibrationModelStore.swift`, `struct
EnergyCalibrationModelRow`). Row **absence** means disabled — the store never writes a
default-factor-of-1 row, which would misleadingly look calibrated.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | **Primary key.** The WHOOP being calibrated. |
| `referenceDeviceId` | TEXT NOT NULL | The single Apple Watch source id the fit was learned from. |
| `enabled` | BOOLEAN NOT NULL | Default `false`. Lets a user pause without discarding a hard-won fit. |
| `factor` | DOUBLE NOT NULL | The bounded multiplier, `0.80...1.20`. |
| `sampleDays` | INTEGER NOT NULL | Distinct days behind the fit (`≥7`). |
| `sampleBuckets` | INTEGER NOT NULL | Buckets behind the fit after trimming (`≥84`). |
| `coefficientOfVariation` | DOUBLE NOT NULL | Trimmed-sample CV, `0...0.20`. |
| `fittedAt` | INTEGER NOT NULL | Unix seconds. |
| `modelVersion` | TEXT NOT NULL | Currently `"watch-reference-v3"` (`EnergyCalibrationFit.modelVersion`). |

**Primary key:** `deviceId`. `saveEnergyCalibrationModel` rejects an out-of-bounds row before it
ever reaches SQL (`validEnergyCalibration`); `resetEnergyCalibration` deletes the row outright
(a user-facing reset), while `setEnergyCalibrationEnabled` only flips `enabled` on an existing fit.

---

## Oura raw-payload archive

This section documents the lossless backstop behind the opt-in Oura history import
(off by default; user-initiated OAuth backfill — `docs/PRIVACY_SECURITY.md` §1.1b). It is
**not** a metric cache like the tables above — it stores verbatim API responses, not decoded
values, so any field Oura returns can be re-derived later without re-fetching.

### `ouraRaw` *(v25)*

One row per fetched PAGE of an Oura API endpoint response — not one row per Oura document; a
single page's `data` array can carry many documents (`OuraRawStore.swift`, `struct OuraRawRow`).
Written by `OuraSyncCoordinator.fetchRaw(_:dateParam:)` in the app target (`Strand/Oura/`).
Natural key `(deviceId, endpoint, documentId)`. Migration `v25-oura-raw`
(`Packages/WhoopStore/Sources/WhoopStore/Database.swift`) — additive only, a new table, no
existing row touched.

| Column | Type | Notes |
| --- | --- | --- |
| `deviceId` | TEXT NOT NULL | Part of PK. `"oura-api"` for the live cloud-import lane. |
| `endpoint` | TEXT NOT NULL | Part of PK. Oura endpoint name, e.g. `"sleep"`, `"daily_readiness"`, `"heartrate"`. |
| `documentId` | TEXT NOT NULL | Part of PK. A SYNTHESIZED page key, `"<endpoint>-<startDate>-<pageIndex>"` (`startDate` is the backfill window's start date, `pageIndex` the fetched page's 0-based position) — never Oura's own document `id`, for any endpoint. |
| `day` | TEXT | `YYYY-MM-DD`, nullable. Currently always NULL — the coordinator never sets it. Reserved for a future per-document (rather than per-page) keying scheme. |
| `payloadJSON` | TEXT NOT NULL | Verbatim JSON body of the fetched page (the raw HTTP response, including its `data` array of documents) — losslessness holds at the page level, not the individual-document level. |
| `fetchedAt` | INTEGER NOT NULL | Unix seconds. |

**Primary key:** `(deviceId, endpoint, documentId)`. `upsertOuraRaw(...)` is idempotent on this
key via `ON CONFLICT(...) DO UPDATE` — re-pulling the SAME window (same `startDate`, so the same
`pageIndex` synthesizes the same `documentId`) overwrites that page's `day`/`payloadJSON`/
`fetchedAt` in place rather than duplicating.

**Index** — `idx_ouraRaw_device_endpoint_day` on `(deviceId, endpoint, day)`, so per-endpoint
reads (`ouraRaw(deviceId:endpoint:)`) scan `(deviceId, endpoint)` and walk `day` in order
without a table scan.

**Not covered by `deleteAllData(deviceId:)`.** Unlike the metric-cache tables above, `ouraRaw`
is not in `DeviceRegistryStore.deviceScopedTables`, so the general per-device wipe skips it by
construction. Disconnecting Oura calls the dedicated `deleteOuraRaw(deviceId:)` alongside
`deleteAllData(deviceId:)` (`Strand/Oura/OuraConnectModel.swift`) so the raw archive is purged
too, not left behind.

---

## Index summary

| Index | Table | Columns | Purpose |
| --- | --- | --- | --- |
| *(implicit PK)* | every table above | (its natural key) | Dedupe + primary lookup. |
| `idx_metricSeries_device_key_day` | `metricSeries` | `deviceId, key, day` | Index-only per-metric range reads. |
| `idx_ouraRaw_device_endpoint_day` | `ouraRaw` | `deviceId, endpoint, day` | Index-only per-endpoint range reads. |

Every other table relies on its primary-key index; the decoded-stream and date-range reads are all
served by the `(deviceId, ts)` / `(deviceId, day)` / `(deviceId, startTs)` primary keys.

---

## Provenance

NOOP's strap interoperability is built on community reverse-engineering work, which it credits and
builds upon:

- **WHOOP 4.0 protocol** — [`johnmiddleton12/my-whoop`](https://github.com/johnmiddleton12/my-whoop)
- **WHOOP 5.0 protocol** — [`b-nnett/goose`](https://github.com/b-nnett/goose)

The frame parsing, CRC, and command/event/packet decode that feed the decoded-stream tables above
live in the `WhoopProtocol` package; persistence is `WhoopStore`; the local recovery / strain /
HRV / sleep math is `StrandAnalytics`; and the CSV / Apple-Health importers are `StrandImport`.

> **Reminder.** NOOP is not affiliated with WHOOP and is not a medical device. All stored data is
> the user's own, kept entirely on the user's device.

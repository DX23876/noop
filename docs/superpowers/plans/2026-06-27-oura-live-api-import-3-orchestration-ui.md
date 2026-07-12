# Oura Live API Import — Plan 3: Orchestration + Writer + Connect UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Plan 1's parsers + Plan 2's client/auth into a working, tappable feature — a one-time backfill that fetches every Oura v2 endpoint, writes the normalized subset + lossless raw into `WhoopStore` under `deviceId = "oura-api"`, and a "Connect Oura & Import Everything" card on Data Sources.

**Architecture:** `OuraSyncCoordinator` (fetch all endpoints via `OuraAPIClient.fetchAllRaw`, parse via Plan 1's `OuraApiParser`, merge per-day rows, hand an assembled `OuraSyncResult` to the writer) → `OuraSyncWriter` (register the `PairedDevice`, then map the result to the existing `WhoopStore` upserts, archiving every raw page). All in the app target `Strand/Oura/`, beside Plan 2. The writer mirrors `Strand/Data/WearableImporter.swift`; the UI mirrors `DataSourcesView`'s existing import cards. Honest-data + no-day-ownership-seizure are structural (see constraints).

**Tech stack:** Swift 5.0 mode (app target), `Foundation` + `AuthenticationServices` + SwiftUI. XCTest in `StrandTests`, run via `xcodebuild -scheme Strand test` (the `TEST_HOST` fix from Plan 2 makes this work). Store-writing tests use `WhoopStore.inMemory()`.

## Global Constraints

- **App-target only.** Files live in `Strand/Oura/` (+ one `WhoopStore` addition in Task 3, + edits in Task 5). No package gains networking.
- **Provenance = `deviceId "oura-api"`, `sourceKind .cloudImport`.** `.cloudImport` is structurally priority-2 in `DayOwnerResolver` (`IntelligenceEngine.swift:1369`: `isImport = .cloudImport || .fileImport` → priority 2, lowest), so the cloud source **can never seize a day from the active WHOOP or any live BLE device** — this is automatic from the `sourceKind` alone. **Never call `setDayOwner`.**
- **Honest data.** Oura's own scores go ONLY to `ref_*` / `oura_*` `metricSeries` keys (from the `[OuraDailyExtra]` array), never to `DailyMetric.recovery`/`.strain` (always `nil`). Mirror `WearableImporter`.
- **Coalesce, prefer readiness RHR.** A single day gets a `WearableDailyRow` from `parseSleep` AND from each `parseDaily(_, endpoint:)`. Merge them into ONE `[String: WearableDailyRow]` with first-non-nil-wins (`??`), merging the **daily endpoints (readiness) BEFORE `sleep`**, so `daily_readiness`'s true `resting_heart_rate` wins over `parseSleep`'s `lowestHr` fallback (Plan-1 final-review advisory).
- **Lossless raw.** Every fetched page → `upsertOuraRaw` regardless of whether a parser exists for that endpoint (8 of 18 endpoints are raw-only).
- **Reuse, don't reinvent.** `DailyMetric`/`CachedSleepSession`/`MetricPoint`/`WorkoutRow`/`HRSample`/`Streams` inits are exact (see each task); `WhoopStore.inMemory()`, `store.registryWriter` (public nonisolated), `repo.refresh()`, `repo.storeHandle()` all exist.
- **Build/test:** `xcodegen generate` (after new files) then `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/<Class> CODE_SIGNING_ALLOWED=NO`.

---

### Task 1: `OuraSyncResult` + `OuraSyncWriter`

The assembled-result model + the persistence mapper. Mirrors `WearableImporter`, adds device registration + `persistSessionMotion` + hrSample + raw archive.

**Files:**
- Create: `Strand/Oura/OuraSyncResult.swift`
- Create: `Strand/Oura/OuraSyncWriter.swift`
- Test: `StrandTests/OuraSyncWriterTests.swift`

**Interfaces:**
- Consumes (Plan 1, StrandImport): `WearableDailyRow`, `OuraSleepPeriod`, `OuraHRPoint`, `OuraDailyExtra`, `OuraWorkout`, `WearableSleepStageInterval`, `OuraRawRow`. (WhoopStore/WhoopProtocol) `DailyMetric`, `CachedSleepSession`, `MetricPoint`, `WorkoutRow`, `HRSample`, `Streams`, `PairedDevice`, `SourceKind`, `DeviceRegistryStore`, `WhoopStore`.
- Produces:
  - `struct OuraSyncResult { var days: [WearableDailyRow]; var sleepPeriods: [OuraSleepPeriod]; var extras: [OuraDailyExtra]; var workouts: [OuraWorkout]; var heartRate: [OuraHRPoint]; var rawPages: [OuraRawRow]; var ringModel: String? }`
  - `struct OuraSyncSummary: Equatable { var days: Int; var sleeps: Int; var workouts: Int; var hrSamples: Int; var metricPoints: Int; var rawPages: Int }`
  - `enum OuraSyncWriter { static func persist(_ result: OuraSyncResult, into store: WhoopStore, deviceId: String = "oura-api") async throws -> OuraSyncSummary }`

- [ ] **Step 1: Write the failing test**

Create `StrandTests/OuraSyncWriterTests.swift`:

```swift
import XCTest
import WhoopStore
import WhoopProtocol
@testable import StrandImport
@testable import Strand

final class OuraSyncWriterTests: XCTestCase {
    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    func testPersistWritesAllStoresAndRegistersCloudSource() async throws {
        let store = try await WhoopStore.inMemory()

        var day = WearableDailyRow(day: "2026-01-02")
        day.restingHr = 50; day.steps = 9000; day.totalSleepMin = 400

        let session = WearableSleepSession(
            start: iso("2026-01-01T23:00:00Z"), end: iso("2026-01-02T06:00:00Z"),
            deepMin: 100, lightMin: 200, remMin: 100, awakeMin: 20, totalSleepMin: 400,
            efficiencyPct: 92, avgHr: 55, lowestHr: 48, avgHrvMs: 65, respRateBpm: 14,
            sleepScore: nil, stages: [WearableSleepStageInterval(stage: "deep",
                start: iso("2026-01-01T23:00:00Z"), end: iso("2026-01-01T23:05:00Z"))])
        let period = OuraSleepPeriod(session: session, movement30s: [1, 2, 1],
                                     hr: [OuraHRPoint(ts: Int(iso("2026-01-01T23:00:00Z").timeIntervalSince1970), bpm: 60)])

        let result = OuraSyncResult(
            days: [day], sleepPeriods: [period],
            extras: [OuraDailyExtra(day: "2026-01-02", key: "ref_readiness_score", value: 80),
                     OuraDailyExtra(day: "2026-01-02", key: "vo2max", value: 44)],
            workouts: [OuraWorkout(start: iso("2026-01-02T07:00:00Z"), end: iso("2026-01-02T07:40:00Z"),
                                   activity: "running", source: "autodetected", energyKcal: 410, distanceM: 6200)],
            heartRate: [OuraHRPoint(ts: Int(iso("2026-01-02T07:00:00Z").timeIntervalSince1970), bpm: 120)],
            rawPages: [OuraRawRow(endpoint: "sleep", documentId: "s1", day: "2026-01-02",
                                  payloadJSON: "{}", fetchedAt: 100)],
            ringModel: "Oura Ring Gen3")

        let summary = try await OuraSyncWriter.persist(result, into: store)

        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.sleeps, 1)
        XCTAssertEqual(summary.workouts, 1)
        XCTAssertGreaterThan(summary.hrSamples, 0)     // in-sleep + whole-day HR
        XCTAssertGreaterThan(summary.metricPoints, 0)
        XCTAssertEqual(summary.rawPages, 1)

        // Cloud source registered as .cloudImport (so it never seizes a WHOOP day).
        let devices = try DeviceRegistryStore(dbQueue: store.registryWriter).all()
        let oura = devices.first { $0.id == "oura-api" }
        XCTAssertEqual(oura?.sourceKind, .cloudImport)
        XCTAssertEqual(oura?.model, "Oura Ring Gen3")

        // Honest data: the reference score is a metricSeries key, never a DailyMetric score column.
        let refs = try await store.metricSeries(deviceId: "oura-api", key: "ref_readiness_score",
                                                 from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(refs.first?.value, 80)
        let vo2 = try await store.metricSeries(deviceId: "oura-api", key: "vo2max",
                                               from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(vo2.first?.value, 44)          // vo2max parity via extras
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraSyncWriterTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `OuraSyncResult`/`OuraSyncWriter` undefined.

- [ ] **Step 3: Implement `OuraSyncResult`**

Create `Strand/Oura/OuraSyncResult.swift`:

```swift
import Foundation
import StrandImport

/// The fully-assembled, parsed output of one Oura backfill, ready to persist. The coordinator (Task 2)
/// builds this (merging per-day rows across endpoints); the writer (below) maps it to WhoopStore.
struct OuraSyncResult {
    var days: [WearableDailyRow]        // already coalesced per calendar day
    var sleepPeriods: [OuraSleepPeriod]
    var extras: [OuraDailyExtra]        // every ref_*/oura_*/vo2max scalar → metricSeries
    var workouts: [OuraWorkout]
    var heartRate: [OuraHRPoint]        // from the /heartrate endpoint (whole-day)
    var rawPages: [OuraRawRow]          // every fetched page, verbatim
    var ringModel: String?             // from ring_configuration, for the PairedDevice model

    init(days: [WearableDailyRow] = [], sleepPeriods: [OuraSleepPeriod] = [], extras: [OuraDailyExtra] = [],
         workouts: [OuraWorkout] = [], heartRate: [OuraHRPoint] = [], rawPages: [OuraRawRow] = [],
         ringModel: String? = nil) {
        self.days = days; self.sleepPeriods = sleepPeriods; self.extras = extras
        self.workouts = workouts; self.heartRate = heartRate; self.rawPages = rawPages; self.ringModel = ringModel
    }
}

/// Counts written, for the honest import summary.
struct OuraSyncSummary: Equatable {
    var days = 0, sleeps = 0, workouts = 0, hrSamples = 0, metricPoints = 0, rawPages = 0
}
```

- [ ] **Step 4: Implement `OuraSyncWriter`**

Create `Strand/Oura/OuraSyncWriter.swift`:

```swift
import Foundation
import WhoopStore
import WhoopProtocol
import StrandImport

/// Maps an assembled `OuraSyncResult` into the on-device WhoopStore under `deviceId = "oura-api"` — the
/// cloud sibling of `Strand/Data/WearableImporter.swift`. HONEST DATA: Oura's own scores go only to
/// ref_*/oura_* metricSeries keys; `DailyMetric.recovery`/`.strain` stay nil. The source registers as
/// `.cloudImport`, which is structurally priority-2 in DayOwnerResolver, so it never seizes a WHOOP day.
enum OuraSyncWriter {

    @discardableResult
    static func persist(_ result: OuraSyncResult, into store: WhoopStore,
                        deviceId: String = "oura-api") async throws -> OuraSyncSummary {
        var summary = OuraSyncSummary()

        // 0. Register the cloud source (the one thing WearableImporter skips). Idempotent by id.
        let now = Int(Date().timeIntervalSince1970)
        let device = PairedDevice(
            id: deviceId, brand: "Oura", model: result.ringModel ?? "Oura (cloud)",
            sourceKind: .cloudImport, capabilities: [], status: .active,
            addedAt: now, lastSeenAt: now)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(device)

        // 1. Raw archive — verbatim, every page, lossless.
        if !result.rawPages.isEmpty {
            summary.rawPages = try await store.upsertOuraRaw(result.rawPages, deviceId: deviceId)
        }

        // 2. Days → DailyMetric. recovery/strain ALWAYS nil (never Oura's readiness). Mirrors WearableImporter.
        let metrics = result.days.map { d in
            DailyMetric(day: d.day, totalSleepMin: d.totalSleepMin, efficiency: d.efficiencyPct,
                        deepMin: d.deepMin, remMin: d.remMin, lightMin: d.lightMin, disturbances: nil,
                        restingHr: d.restingHr, avgHrv: d.avgHrvMs, recovery: nil, strain: nil,
                        exerciseCount: nil, spo2Pct: d.spo2Pct, skinTempDevC: d.skinTempDevC,
                        respRateBpm: d.respRateBpm, steps: d.steps, activeKcalEst: d.activeKcal)
        }
        summary.days = try await store.upsertDailyMetrics(metrics, deviceId: deviceId)

        // 3. Sleep sessions → CachedSleepSession (+ stagesJSON), then per-session motion via the dedicated setter.
        var sessions: [CachedSleepSession] = []
        for p in result.sleepPeriods {
            let startTs = Int(p.session.start.timeIntervalSince1970)
            let endTs = Int(p.session.end.timeIntervalSince1970)
            sessions.append(CachedSleepSession(
                startTs: startTs, endTs: endTs, efficiency: p.session.efficiencyPct,
                restingHr: p.session.lowestHr ?? p.session.avgHr, avgHrv: p.session.avgHrvMs,
                stagesJSON: stagesJSON(p.session.stages)))
        }
        summary.sleeps = try await store.upsertSleepSessions(sessions, deviceId: deviceId)
        for p in result.sleepPeriods where !p.movement30s.isEmpty {   // motionJSON is NOT on the sleep upsert
            _ = try await store.persistSessionMotion(
                deviceId: deviceId, sessionStart: Int(p.session.start.timeIntervalSince1970),
                motionEpochs: p.movement30s.map(Double.init))
        }

        // 4. HR → hrSample via the Streams insert path (in-sleep HR + the whole-day /heartrate series).
        var hr: [HRSample] = result.heartRate.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        for p in result.sleepPeriods { hr.append(contentsOf: p.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) }) }
        if !hr.isEmpty {
            let counts = try await store.insert(Streams(hr: hr), deviceId: deviceId)
            summary.hrSamples = counts.hr
        }

        // 5. Workouts → WorkoutRow.
        let workouts = result.workouts.map { w in
            WorkoutRow(startTs: Int(w.start.timeIntervalSince1970), endTs: Int(w.end.timeIntervalSince1970),
                       sport: w.activity, source: w.source, durationS: w.end.timeIntervalSince(w.start),
                       energyKcal: w.energyKcal, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: w.distanceM, zonesJSON: nil, notes: nil)
        }
        summary.workouts = try await store.upsertWorkouts(workouts, deviceId: deviceId)

        // 6. Extras → metricSeries (ref_*/oura_*/vo2max — parity with the file-import lane, sourced from
        //    the extras array so vo2max/ref_sleep_score are never lost even though DailyMetric lacks them).
        let points = result.extras.map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }
        summary.metricPoints = try await store.upsertMetricSeries(points, deviceId: deviceId)

        return summary
    }

    /// Serialize decoded stages to the `[{start,end,stage}]` JSON the cache stores (same shape as WearableImporter).
    private static func stagesJSON(_ stages: [WearableSleepStageInterval]) -> String? {
        guard !stages.isEmpty else { return nil }
        let segs = stages.map { ["start": Int($0.start.timeIntervalSince1970),
                                 "end": Int($0.end.timeIntervalSince1970), "stage": $0.stage] as [String: Any] }
        return (try? JSONSerialization.data(withJSONObject: segs)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraSyncWriterTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS. (If `PairedDevice`'s `status`/`capabilities` types differ — e.g. `DeviceStatus` has no `.active`, or `capabilities` isn't `Set<Metric>` — read `Packages/WhoopStore/Sources/WhoopStore/PairedDevice.swift` and adjust the enum case / empty-set literal to match; keep behavior identical. Report any such adjustment.)

- [ ] **Step 6: Commit**

```bash
git add Strand/Oura/OuraSyncResult.swift Strand/Oura/OuraSyncWriter.swift StrandTests/OuraSyncWriterTests.swift
git commit -m "feat(oura): OuraSyncWriter — persist backfill to WhoopStore as .cloudImport source"
```

---

### Task 2: `OuraSyncCoordinator`

Fetch every endpoint, parse, merge per-day rows (readiness before sleep), assemble the `OuraSyncResult`, persist, report progress.

**Files:**
- Create: `Strand/Oura/OuraSyncCoordinator.swift`
- Test: `StrandTests/OuraSyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `OuraAPIClient` (Plan 2), `OuraApiParser` (Plan 1), `OuraSyncWriter`/`OuraSyncResult` (Task 1), `WhoopStore`, `OuraError`.
- Produces:
  - `protocol OuraPageFetching { func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data] }` (+ `extension OuraAPIClient: OuraPageFetching {}`)
  - `struct OuraSyncProgress: Equatable { let endpoint: String; let pages: Int }`
  - `final class OuraSyncCoordinator` with `init(fetcher: OuraPageFetching, store: WhoopStore)` and `func runFullImport(startDate: String = "2013-01-01", today: String, onProgress: @escaping (OuraSyncProgress) -> Void = { _ in }) async throws -> OuraSyncSummary`.

- [ ] **Step 1: Write the failing test**

Create `StrandTests/OuraSyncCoordinatorTests.swift`:

```swift
import XCTest
import WhoopStore
@testable import StrandImport
@testable import Strand

/// A fetcher that serves canned page bodies per endpoint.
private final class StubFetcher: OuraPageFetching {
    var pages: [String: [Data]] = [:]
    func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data] {
        pages[endpoint] ?? []
    }
}

final class OuraSyncCoordinatorTests: XCTestCase {
    func testBackfillFetchesParsesAndWrites() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubFetcher()
        fetcher.pages["daily_readiness"] = [#"{"data":[{"day":"2026-01-02","score":80,"contributors":{"resting_heart_rate":50}}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.pages["daily_activity"] = [#"{"data":[{"day":"2026-01-02","steps":9000}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.pages["sleep"] = [#"{"data":[{"id":"s1","day":"2026-01-02","bedtime_start":"2026-01-01T23:00:00+00:00","bedtime_end":"2026-01-02T06:00:00+00:00","total_sleep_duration":24000,"lowest_heart_rate":48,"sleep_phase_5_min":"1234"}],"next_token":null}"#.data(using: .utf8)!]

        var progress: [String] = []
        let coord = OuraSyncCoordinator(fetcher: fetcher, store: store)
        let summary = try await coord.runFullImport(today: "2026-02-01") { progress.append($0.endpoint) }

        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.sleeps, 1)
        XCTAssertTrue(summary.rawPages >= 3)
        XCTAssertTrue(progress.contains("sleep"))

        // Coalesce + RHR precedence: daily_readiness's true RHR (50) wins over sleep's lowestHr (48).
        let days = try await store.dailyMetrics(deviceId: "oura-api", from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(days.first?.restingHr, 50)
        XCTAssertEqual(days.first?.steps, 9000)
        XCTAssertEqual(days.first?.totalSleepMin, 400)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraSyncCoordinatorTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: FAIL — `OuraSyncCoordinator`/`OuraPageFetching` undefined. (Note: confirm `WhoopStore.dailyMetrics(deviceId:from:to:)` is the read accessor name — if it differs, read `MetricsCache.swift` and use the actual reader.)

- [ ] **Step 3: Implement `OuraSyncCoordinator`**

Create `Strand/Oura/OuraSyncCoordinator.swift`:

```swift
import Foundation
import WhoopStore
import StrandImport

/// Abstracts the page fetch so the coordinator is testable without a live network (OuraAPIClient conforms).
protocol OuraPageFetching {
    func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data]
}
extension OuraAPIClient: OuraPageFetching {}

struct OuraSyncProgress: Equatable { let endpoint: String; let pages: Int }

/// One-time backfill across every Oura v2 endpoint → an assembled OuraSyncResult → OuraSyncWriter. Merges
/// the per-day WearableDailyRows across endpoints (daily endpoints BEFORE sleep, so readiness RHR wins).
final class OuraSyncCoordinator {
    private let fetcher: OuraPageFetching
    private let store: WhoopStore
    init(fetcher: OuraPageFetching, store: WhoopStore) { self.fetcher = fetcher; self.store = store }

    /// Daily-summary endpoints handed to `parseDaily(_, endpoint:)`. Ordered so `daily_readiness` merges
    /// before `sleep` (RHR precedence). `daily_sleep` etc. contribute extras only.
    private static let dailyEndpoints = ["daily_readiness", "daily_activity", "daily_spo2", "daily_sleep",
                                         "daily_stress", "daily_resilience", "daily_cardiovascular_age", "vO2_max"]
    /// Endpoints with no Plan-1 parser — archived raw only.
    private static let rawOnlyEndpoints = ["personal_info", "ring_configuration", "sleep_time", "session",
                                           "tag", "enhanced_tag", "rest_mode_period", "ring_battery_level"]

    func runFullImport(startDate: String = "2013-01-01", today: String,
                       onProgress: @escaping (OuraSyncProgress) -> Void = { _ in }) async throws -> OuraSyncSummary {
        var result = OuraSyncResult()
        var byDay: [String: WearableDailyRow] = [:]

        func fetchRaw(_ endpoint: String, dateParam: String?) async throws -> [Data] {
            var q: [String: String] = [:]
            if let dateParam { q[dateParam] = startDate; q[dateParam == "start_datetime" ? "end_datetime" : "end_date"] = today }
            let pages = try await fetcher.fetchAllRaw(endpoint: endpoint, query: q)
            var idx = 0
            for body in pages {
                result.rawPages.append(OuraRawRow(endpoint: endpoint, documentId: "\(endpoint)-\(startDate)-\(idx)",
                                                  day: nil, payloadJSON: String(data: body, encoding: .utf8) ?? "",
                                                  fetchedAt: Int(Date().timeIntervalSince1970)))
                idx += 1
            }
            onProgress(OuraSyncProgress(endpoint: endpoint, pages: pages.count))
            return pages
        }

        func docs(_ pages: [Data]) -> [[String: Any]] {
            pages.flatMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["data"] as? [[String: Any]] ?? [] }
        }
        func merge(_ rows: [WearableDailyRow]) {
            for r in rows {
                var m = byDay[r.day] ?? WearableDailyRow(day: r.day)
                m.restingHr = m.restingHr ?? r.restingHr; m.avgHrvMs = m.avgHrvMs ?? r.avgHrvMs
                m.skinTempDevC = m.skinTempDevC ?? r.skinTempDevC; m.spo2Pct = m.spo2Pct ?? r.spo2Pct
                m.steps = m.steps ?? r.steps; m.activeKcal = m.activeKcal ?? r.activeKcal
                m.totalKcal = m.totalKcal ?? r.totalKcal; m.respRateBpm = m.respRateBpm ?? r.respRateBpm
                m.totalSleepMin = m.totalSleepMin ?? r.totalSleepMin; m.deepMin = m.deepMin ?? r.deepMin
                m.lightMin = m.lightMin ?? r.lightMin; m.remMin = m.remMin ?? r.remMin
                m.awakeMin = m.awakeMin ?? r.awakeMin; m.efficiencyPct = m.efficiencyPct ?? r.efficiencyPct
                byDay[r.day] = m
            }
        }

        // Daily endpoints first (readiness RHR precedence), extras accumulate.
        for endpoint in Self.dailyEndpoints {
            let pages = try await fetchRaw(endpoint, dateParam: "start_date")
            let (days, extras) = OuraApiParser.parseDaily(docs(pages), endpoint: endpoint)
            merge(days); result.extras.append(contentsOf: extras)
        }
        // Sleep last (its lowestHr fallback only fills days readiness didn't cover).
        let sleepPages = try await fetchRaw("sleep", dateParam: "start_date")
        let (periods, sleepDays) = OuraApiParser.parseSleep(docs(sleepPages))
        result.sleepPeriods = periods; merge(sleepDays)
        // Workouts + heart-rate.
        let workoutPages = try await fetchRaw("workout", dateParam: "start_date")
        result.workouts = OuraApiParser.parseWorkouts(docs(workoutPages))
        let hrPages = try await fetchRaw("heartrate", dateParam: "start_datetime")
        result.heartRate = OuraApiParser.parseHeartRate(docs(hrPages))
        // Raw-only endpoints (no parser).
        for endpoint in Self.rawOnlyEndpoints {
            _ = try await fetchRaw(endpoint, dateParam: Self.rawOnlyEndpoints.contains(endpoint) &&
                                   ["personal_info", "ring_configuration"].contains(endpoint) ? nil : "start_date")
        }

        result.days = Array(byDay.values)
        return try await OuraSyncWriter.persist(result, into: store)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test -only-testing:StrandTests/OuraSyncCoordinatorTests CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Strand/Oura/OuraSyncCoordinator.swift StrandTests/OuraSyncCoordinatorTests.swift
git commit -m "feat(oura): OuraSyncCoordinator — one-time backfill across all endpoints, coalesced days"
```

---

### Task 3: `deleteOuraRaw` for clean disconnect

`store.deleteAllData(deviceId:)` does NOT clear `ouraRaw` (it's not in `deviceScopedTables`). Add a targeted delete so Disconnect leaves nothing behind.

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/OuraRawStore.swift`
- Test: `Packages/WhoopStore/Tests/WhoopStoreTests/OuraRawStoreTests.swift` (extend)

**Interfaces:**
- Produces: `WhoopStore.deleteOuraRaw(deviceId: String) async throws -> Int`

- [ ] **Step 1: Write the failing test** (append to `OuraRawStoreTests.swift`)

```swift
    func testDeleteOuraRawRemovesAllForDevice() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertOuraRaw([
            OuraRawRow(endpoint: "sleep", documentId: "a", day: "2026-01-01", payloadJSON: "{}", fetchedAt: 1),
            OuraRawRow(endpoint: "workout", documentId: "b", day: "2026-01-01", payloadJSON: "{}", fetchedAt: 1),
        ], deviceId: "oura-api")
        let deleted = try await store.deleteOuraRaw(deviceId: "oura-api")
        XCTAssertEqual(deleted, 2)
        XCTAssertEqual(try await store.ouraRawCount(deviceId: "oura-api", endpoint: "sleep"), 0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/WhoopStore --filter OuraRawStoreTests`
Expected: FAIL — `deleteOuraRaw` undefined.

- [ ] **Step 3: Implement** (add to the `extension WhoopStore` in `OuraRawStore.swift`)

```swift
    /// Remove every archived Oura payload for a device (used by Disconnect — `deleteAllData` does not
    /// cover `ouraRaw`). Returns rows deleted.
    @discardableResult
    public func deleteOuraRaw(deviceId: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM ouraRaw WHERE deviceId = ?", arguments: [deviceId])
            return db.changesCount
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/WhoopStore --filter OuraRawStoreTests`
Expected: PASS (this is a package test — fast `swift test`, no xcodebuild).

- [ ] **Step 5: Commit**

```bash
git add Packages/WhoopStore/Sources/WhoopStore/OuraRawStore.swift Packages/WhoopStore/Tests/WhoopStoreTests/OuraRawStoreTests.swift
git commit -m "feat(store): deleteOuraRaw(deviceId:) for full Oura cloud-source disconnect"
```

---

### Task 4: `ASPresentationAnchor` helper + Connect UI

The cross-platform key-window accessor + the "Connect Oura & Import Everything" card. The card is compile-verified + manually tested (SwiftUI + interactive OAuth aren't headless-unit-testable); the anchor helper's logic is the only new unit-testable piece and is trivial, so this task's gate is a clean build.

**Files:**
- Create: `Strand/Oura/OuraPresentationAnchor.swift`
- Create: `Strand/Oura/OuraConnectModel.swift` (the `@MainActor` view-model driving connect → backfill → summary)
- Modify: `Strand/Screens/DataSourcesView.swift` (add the Oura card + wire the model)

**Interfaces:**
- Consumes: `OuraOAuthProvider`, `OuraCredentials`, `OuraAPIClient`, `OuraSyncCoordinator`, `OuraTokenStore`, `Repository`.
- Produces: `func ouraPresentationAnchor() -> ASPresentationAnchor`; `@MainActor final class OuraConnectModel: ObservableObject`.

- [ ] **Step 1: Implement the anchor helper**

Create `Strand/Oura/OuraPresentationAnchor.swift` (no unit test — platform window lookup, modeled on `Strand/System/DisplayScreenshot.swift`):

```swift
import AuthenticationServices
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The app's key window as an ASPresentationAnchor for ASWebAuthenticationSession. Modeled on
/// DisplayScreenshot's window lookup. Falls back to a bare anchor (OuraOAuthProvider tolerates it).
@MainActor func ouraPresentationAnchor() -> ASPresentationAnchor {
    #if os(iOS)
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
    #elseif os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    #else
    return ASPresentationAnchor()
    #endif
}
```

- [ ] **Step 2: Implement the connect view-model**

Create `Strand/Oura/OuraConnectModel.swift`:

```swift
import Foundation
import Combine
import AuthenticationServices

/// Drives the Data Sources "Connect Oura" card: connect (OAuth) → one-time backfill → honest summary →
/// disconnect. @MainActor so all @Published mutations are main-thread; the network/backfill hops off-main.
@MainActor
final class OuraConnectModel: ObservableObject {
    @Published var busy = false
    @Published var statusText: String?
    @Published var isConnected = OuraTokenStore.isConnected

    private let repo: Repository
    init(repo: Repository) { self.repo = repo }

    /// True when the BYO-app credentials are present (else the lane is disabled with guidance).
    var isConfigured: Bool { OuraCredentials.fromBundle != nil }

    func connectAndImport() {
        guard let creds = OuraCredentials.fromBundle else {
            statusText = "Add your Oura app's client_id/secret to OuraSecrets.xcconfig first."; return
        }
        busy = true; statusText = "Connecting to Oura…"
        Task {
            do {
                let provider = OuraOAuthProvider(credentials: creds)
                try await provider.authorize(presentationAnchor: ouraPresentationAnchor())
                isConnected = true
                guard let store = await repo.storeHandle() else { fail("No local store."); return }
                let client = OuraAPIClient(auth: provider, environment: .production)
                let coord = OuraSyncCoordinator(fetcher: client, store: store)
                let today = Self.dayFormatter.string(from: Date())
                statusText = "Importing your Oura history…"
                let s = try await coord.runFullImport(today: today) { [weak self] p in
                    Task { @MainActor in self?.statusText = "Importing \(p.endpoint)…" }
                }
                await repo.refresh()
                statusText = "Imported \(s.days) days · \(s.sleeps) sleeps · \(s.workouts) workouts · \(s.hrSamples) HR samples"
            } catch { fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            busy = false
        }
    }

    func disconnect() {
        busy = true
        Task {
            OuraOAuthProvider(credentials: OuraCredentials.fromBundle ?? .init(clientId: "", clientSecret: "", redirectURI: "")).signOut()
            if let store = await repo.storeHandle() {
                try? await store.deleteAllData(deviceId: "oura-api")
                try? await store.deleteOuraRaw(deviceId: "oura-api")
                await repo.refresh()
            }
            isConnected = false; statusText = "Disconnected."; busy = false
        }
    }

    private func fail(_ m: String) { statusText = m; busy = false }
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
```

- [ ] **Step 3: Add the Oura card to `DataSourcesView`**

Read `Strand/Screens/DataSourcesView.swift` around the `wearableCard` (~:265) and the shared `card(...)` builder (~:811). Add a `@StateObject private var oura = OuraConnectModel(repo: repo)` (or wire via the existing model), and a card mirroring `wearableCard`, placed next to it:

```swift
private var ouraCloudCard: some View {
    card(title: "Oura (cloud)", icon: "circle.circle", tint: StrandPalette.metricPurple,
         subtitle: "Connect your Oura account and import your full history over the API.") {
        VStack(alignment: .leading, spacing: 8) {
            if oura.isConnected {
                HStack {
                    Button { oura.connectAndImport() } label: { Label("Sync again", systemImage: "arrow.clockwise") }
                    Button(role: .destructive) { oura.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                }.disabled(oura.busy)
            } else {
                Button { oura.connectAndImport() } label: {
                    Label(oura.busy ? "Working…" : "Connect Oura & Import Everything", systemImage: "link")
                }.disabled(oura.busy || !oura.isConfigured)
                if !oura.isConfigured {
                    Text("Add your Oura app credentials to OuraSecrets.xcconfig to enable this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let s = oura.statusText { Text(s).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
```
Then render `ouraCloudCard` in the same list/section as `wearableCard`.

- [ ] **Step 4: Verify the build (compile-gate; no headless test for SwiftUI/interactive OAuth)**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' build-for-testing CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15`
Expected: `** TEST BUILD SUCCEEDED **`. Manually note in the report: the interactive OAuth + backfill flow is live-tested by the user with real credentials, not in CI.

- [ ] **Step 5: Commit**

```bash
git add Strand/Oura/OuraPresentationAnchor.swift Strand/Oura/OuraConnectModel.swift Strand/Screens/DataSourcesView.swift
git commit -m "feat(oura): Connect Oura & Import Everything card + presentation-anchor helper"
```

---

### Task 5: Scoring source + documentation

Add `"oura-api"` to the import-source list so cloud-only days can be scored, and update the honest-data docs.

**Files:**
- Modify: `Strand/Data/Repository.swift` (`wearableImportSources`)
- Modify: `docs/PRIVACY_SECURITY.md`, `docs/DEVICE_SUPPORT_ROADMAP.md`, `docs/DATA_MODEL.md`

**Interfaces:** none.

- [ ] **Step 1: Add the scoring source**

In `Strand/Data/Repository.swift` (~:452):
```swift
static let wearableImportSources = ["oura-import", "fitbit-import", "garmin-import", "oura-api", healthConnectSource]
```

- [ ] **Step 2: Docs**

- `docs/PRIVACY_SECURITY.md` §1: amend "exactly one opt-in exception (the AI Coach)" → "two opt-in exceptions: the AI Coach and the Oura cloud import." Add a short §1.1b describing the Oura lane: off-by-default, user-initiated, inbound (the user's own Oura data under their own OAuth app), tokens in Keychain, no NOOP server, raw data never exfiltrated.
- `docs/DEVICE_SUPPORT_ROADMAP.md`: change the Oura row from "📋 Researched, not built | Cloud API v2 — off-by-default OAuth import lane only" to "🔬 Built (cloud import) | Cloud API v2 — off-by-default OAuth, one-time backfill; local BLE ring also supported."
- `docs/DATA_MODEL.md`: note the current migrator version (v24) and add the `ouraRaw` table (deviceId, endpoint, documentId, day, payloadJSON, fetchedAt) to the metric-caches / new-tables section.

- [ ] **Step 3: Verify + commit**

Run: `xcodegen generate && xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' build-for-testing CODE_SIGNING_ALLOWED=NO 2>&1 | tail -8`
Expected: `** TEST BUILD SUCCEEDED **`.

```bash
git add Strand/Data/Repository.swift docs/PRIVACY_SECURITY.md docs/DEVICE_SUPPORT_ROADMAP.md docs/DATA_MODEL.md
git commit -m "chore(oura): score cloud-import days + document the second opt-in network lane"
```

---

## Plan 3 self-review

- **Spec coverage:** §7 orchestration → Task 2; §8 writer/mapping (raw + normalized + registry + coalesce + motion + hrSample) → Task 1; §8.4 disconnect (deleteOuraRaw) → Task 3; §9 Connect UI → Task 4; §8.4 scoring + §10 docs → Task 5. The Plan-1 final-review advisories (coalesce, readiness-RHR precedence, sleep-score/vo2max parity via extras) are baked into Tasks 1–2 and the constraints.
- **Honest data / ownership are structural:** `recovery`/`strain` hardcoded nil; scores only via extras → `ref_*` keys; `.cloudImport` = priority-2 → never seizes a WHOOP day; `setDayOwner` never called.
- **Testability:** writer + coordinator use `WhoopStore.inMemory()` + a stub fetcher (no network); `deleteOuraRaw` is a fast package test; the UI/OAuth (inherently interactive) is compile-gated + user-live-tested, called out honestly.
- **Type consistency:** every `WhoopStore` init/method is the exact signature from the v8.5.2 study; `OuraSyncResult`/`OuraSyncSummary` defined Task 1, consumed Task 2; `OuraPageFetching` defined Task 2, `OuraAPIClient` conformance added there.
- **Risk notes for the implementer (verify against code, adjust minimally, report):** `PairedDevice.status`/`capabilities` enum types; the `dailyMetrics(deviceId:from:to:)` read-accessor name; `StrandPalette`/`card(...)` exact signatures in `DataSourcesView`.

## After Plan 3

The feature is complete and tappable. To use it live, the user registers a free Oura OAuth app (redirect `noop://oura/callback`), drops `client_id`/`secret` into `Strand/Oura/OuraSecrets.xcconfig`, builds, and taps **Connect Oura & Import Everything**. Remaining deferred Minors (from the Plan-1/2 final reviews) — exponential backoff/jitter/pacer in the coordinator, `maxPages` logging, `spo2Daily` scope verification via the sandbox, richer normalization of the 8 raw-only endpoints — are follow-ups, not blockers.

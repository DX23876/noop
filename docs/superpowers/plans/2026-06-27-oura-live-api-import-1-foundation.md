# Oura Live API Import — Plan 1: Foundation (pure parsers + raw storage)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **⚠️ v8.5.2 reconciliation (2026-06-30).** Written against v7.2.3; this branch (`oura-cloud-import`) is rebased onto upstream **v8.5.2** (`ryanbr/noop`). Deltas verified against current code:
> 1. **Migration is `v24`, not `v19`.** The migrator is at **v23** (`v19-step-activity-class` … `v23-daily-spo2-raw`); append `v24-oura-raw` after the v23 block. (Fixed inline in Task 1.)
> 2. **Provenance (Plan 3):** register the source with `PairedDevice.sourceKind = .cloudImport` — it already exists (`PairedDevice.swift:42`) and is treated as non-day-owning (`IntelligenceEngine.swift:1369`). Do **not** invent a new SourceKind; keep `deviceId = "oura-api"`.
> 3. **`motionJSON` (Plan 3)** is written via the dedicated `persistSessionMotion(deviceId:sessionStart:motionEpochs:[Double])` (`MetricsCache.swift:234`) after the sleep upsert (not through it); map `movement30s` `[Int]→[Double]`.
> 4. Also add `"oura-api"` to `Repository.wearableImportSources` (`Repository.swift:452`); disconnect via the actor `store.deleteAllData(deviceId:)` (`DataSourcesView.swift:598`).
> 5. Citations shifted: `WhoopTime.parseISOWithOffset` → `CSVParsing.swift:509`; `WearableJSON` is in `WearableExportImporter.swift:329`. **Tasks 2–5 compile against v8.5.2 unchanged** — only Task 1's migration number moves.

**Goal:** Build the network-free core of the Oura live-API lane — the lossless raw payload store and the pure JSON→model parsers (incl. the sleep hypnogram) — fully unit-tested, touching only new files plus one additive migration.

**Architecture:** Two packages, additive only. `WhoopStore` gains a `ouraRaw` table (migration **v24**) and an `OuraRawStore` extension mirroring `MetricSeriesStore`. `StrandImport` gains pure decoders (`OuraHypnogram`, `OuraApiParser`) and small neutral model structs that reuse the existing `OuraExportParser` field semantics, `WhoopTime`, and `WearableJSON`. No networking, no edits to existing exhaustive switches, no app-target changes — so this plan can't break any existing build path. The fetch layer, auth, writer, and UI come in Plans 2–3.

**Tech Stack:** Swift 5.9, GRDB 6.29.3 (pinned), XCTest, `Foundation`. iOS 16 / macOS 13 (both package platforms; the lane ships iOS-only but the packages stay multi-platform).

## Global Constraints

Every task implicitly includes these (verbatim from the spec):
- **Packages stay network-free.** No `URLSession`/`URLRequest`/`NWConnection` in `StrandImport` or `WhoopStore`. (`StrandImport` banner: "STAY OFFLINE: nothing here touches the network.")
- **Honest data.** Oura's own scores (readiness/sleep/activity/resilience) are written ONLY under reference keys (`ref_*`) or namespaced (`oura_*`) — never as a NOOP score column (`recovery`/`strain`). NOOP recomputes downstream.
- **Untrusted input is hostile.** Parse via the existing `WearableJSON` finite/range-checked coercion (`dbl`/`int`/`posInt`/`posDbl`/`str`); never trap on attacker NaN/inf/huge values.
- **Additive migrations only.** New tables/indexes; never alter or drop existing rows. The live migrator is at **v23** (`Packages/WhoopStore/Sources/WhoopStore/Database.swift`); this adds **v24** (`v19`–`v23` already exist).
- **Pinned deps.** Add no new dependency. Versions across `Packages/*/Package.swift` must stay identical (`GRDB.swift exact 6.29.3`, `ZIPFoundation exact 0.9.20`).
- **Provenance string.** The live-API partition is `deviceId = "oura-api"` (distinct from the file lane's `"oura-import"`).

---

### Task 1: `ouraRaw` table (migration v24) + `OuraRawStore`

Lossless archive of every raw Oura payload, keyed by `(deviceId, endpoint, documentId)`, idempotent on re-pull.

**Files:**
- Modify: `Packages/WhoopStore/Sources/WhoopStore/Database.swift` (add migration after the `v23-daily-spo2-raw` block, before `return migrator`)
- Create: `Packages/WhoopStore/Sources/WhoopStore/OuraRawStore.swift`
- Test: `Packages/WhoopStore/Tests/WhoopStoreTests/OuraRawStoreTests.swift`

**Interfaces:**
- Consumes: `WhoopStore.inMemory()`, the actor's `syncWrite`/`syncRead` helpers, `db.changesCount` (all existing).
- Produces:
  - `struct OuraRawRow { let endpoint: String; let documentId: String; let day: String?; let payloadJSON: String; let fetchedAt: Int }`
  - `WhoopStore.upsertOuraRaw(_ rows: [OuraRawRow], deviceId: String) async throws -> Int`
  - `WhoopStore.ouraRaw(deviceId: String, endpoint: String) async throws -> [OuraRawRow]`
  - `WhoopStore.ouraRawCount(deviceId: String, endpoint: String) async throws -> Int`

- [ ] **Step 1: Write the failing test**

Create `Packages/WhoopStore/Tests/WhoopStoreTests/OuraRawStoreTests.swift`:

```swift
import XCTest
import GRDB
@testable import WhoopStore

final class OuraRawStoreTests: XCTestCase {
    func testUpsertIsIdempotentByNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        let first = OuraRawRow(endpoint: "sleep", documentId: "abc", day: "2026-01-01",
                               payloadJSON: #"{"id":"abc","v":1}"#, fetchedAt: 100)
        let n1 = try await store.upsertOuraRaw([first], deviceId: "oura-api")
        XCTAssertEqual(n1, 1)

        // Re-pull the same document id with a newer payload → overwrite in place, still one row.
        let second = OuraRawRow(endpoint: "sleep", documentId: "abc", day: "2026-01-01",
                                payloadJSON: #"{"id":"abc","v":2}"#, fetchedAt: 200)
        _ = try await store.upsertOuraRaw([second], deviceId: "oura-api")

        let rows = try await store.ouraRaw(deviceId: "oura-api", endpoint: "sleep")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.payloadJSON, #"{"id":"abc","v":2}"#)
        XCTAssertEqual(rows.first?.fetchedAt, 200)
        XCTAssertEqual(try await store.ouraRawCount(deviceId: "oura-api", endpoint: "sleep"), 1)
        // A different endpoint is a different partition.
        XCTAssertEqual(try await store.ouraRawCount(deviceId: "oura-api", endpoint: "daily_sleep"), 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/WhoopStore --filter OuraRawStoreTests`
Expected: FAIL — compile error, `OuraRawRow` / `upsertOuraRaw` undefined.

- [ ] **Step 3: Add migration v24**

In `Packages/WhoopStore/Sources/WhoopStore/Database.swift`, insert immediately **after the `v23-daily-spo2-raw` block** and before `return migrator` (`v19`–`v23` already exist, so v24 is the next free slot — do NOT reuse v19):

```swift
        // v24: Oura live-API raw payload archive (lossless). One row per (deviceId, endpoint, documentId);
        // payloadJSON holds the verbatim Oura object so any field can be re-derived later without re-fetching
        // from the API. Additive only — a NEW table, no existing row touched, old readers unaffected.
        migrator.registerMigration("v24-oura-raw") { db in
            try db.create(table: "ouraRaw") { t in
                t.column("deviceId", .text).notNull()
                t.column("endpoint", .text).notNull()       // "sleep" | "daily_readiness" | "heartrate" | …
                t.column("documentId", .text).notNull()     // Oura `id`; heartrate pages use a window key
                t.column("day", .text)                       // YYYY-MM-DD when day-keyed (nullable)
                t.column("payloadJSON", .text).notNull()     // verbatim object
                t.column("fetchedAt", .integer).notNull()    // unix seconds
                t.primaryKey(["deviceId", "endpoint", "documentId"])
            }
            // Per-endpoint reads scan (deviceId, endpoint) then walk day in order.
            try db.create(index: "idx_ouraRaw_device_endpoint_day",
                          on: "ouraRaw", columns: ["deviceId", "endpoint", "day"])
        }
```

- [ ] **Step 4: Implement `OuraRawStore`**

Create `Packages/WhoopStore/Sources/WhoopStore/OuraRawStore.swift`:

```swift
import Foundation
import GRDB

// MARK: - v19 store: lossless Oura live-API payload archive
// Mirrors MetricSeriesStore exactly: a Codable row struct, an idempotent ON CONFLICT upsert keyed by the
// natural key (deviceId, endpoint, documentId), and range reads — all GRDB work via syncWrite/syncRead.
// This is the "as much as we can get" backstop: the verbatim payload is kept so a future metric can be
// derived without re-hitting the Oura API.

/// One archived Oura API payload. Natural key (deviceId, endpoint, documentId).
public struct OuraRawRow: Equatable, Codable, Sendable {
    public let endpoint: String     // "sleep" | "daily_readiness" | "heartrate" | …
    public let documentId: String   // Oura `id`; for heartrate pages, a synthesized window key
    public let day: String?         // YYYY-MM-DD when the document is day-keyed
    public let payloadJSON: String  // verbatim object
    public let fetchedAt: Int       // unix seconds
    public init(endpoint: String, documentId: String, day: String?, payloadJSON: String, fetchedAt: Int) {
        self.endpoint = endpoint; self.documentId = documentId
        self.day = day; self.payloadJSON = payloadJSON; self.fetchedAt = fetchedAt
    }
}

extension WhoopStore {

    /// Upsert raw Oura payloads. Idempotent by (deviceId, endpoint, documentId): re-pulling the same
    /// document overwrites its payload/day/fetchedAt rather than duplicating. Returns rows changed.
    @discardableResult
    public func upsertOuraRaw(_ rows: [OuraRawRow], deviceId: String) async throws -> Int {
        try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO ouraRaw (deviceId, endpoint, documentId, day, payloadJSON, fetchedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, endpoint, documentId) DO UPDATE SET
                        day = excluded.day,
                        payloadJSON = excluded.payloadJSON,
                        fetchedAt = excluded.fetchedAt
                    """, arguments: [deviceId, r.endpoint, r.documentId, r.day, r.payloadJSON, r.fetchedAt])
                n += db.changesCount
            }
            return n
        }
    }

    /// Archived payloads for a device + endpoint, oldest day first (null days sort first in SQLite).
    public func ouraRaw(deviceId: String, endpoint: String) async throws -> [OuraRawRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT endpoint, documentId, day, payloadJSON, fetchedAt FROM ouraRaw
                WHERE deviceId = ? AND endpoint = ?
                ORDER BY day ASC
                """, arguments: [deviceId, endpoint])
                .map { OuraRawRow(endpoint: $0["endpoint"], documentId: $0["documentId"],
                                  day: $0["day"], payloadJSON: $0["payloadJSON"], fetchedAt: $0["fetchedAt"]) }
        }
    }

    /// Count archived payloads for a device + endpoint (diagnostics / import summary).
    public func ouraRawCount(deviceId: String, endpoint: String) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM ouraRaw WHERE deviceId = ? AND endpoint = ?",
                arguments: [deviceId, endpoint]) ?? 0
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Packages/WhoopStore --filter OuraRawStoreTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/WhoopStore/Sources/WhoopStore/Database.swift \
        Packages/WhoopStore/Sources/WhoopStore/OuraRawStore.swift \
        Packages/WhoopStore/Tests/WhoopStoreTests/OuraRawStoreTests.swift
git commit -m "feat(store): ouraRaw lossless payload archive (migration v24) + OuraRawStore"
```

---

### Task 2: `OuraHypnogram` decoder

Pure decode of Oura's two compact per-epoch sleep strings. The legends DIFFER — one decoder must never serve both.

**Files:**
- Create: `Packages/StrandImport/Sources/StrandImport/OuraHypnogram.swift`
- Test: `Packages/StrandImport/Tests/StrandImportTests/OuraHypnogramTests.swift`

**Interfaces:**
- Consumes: `WearableSleepStageInterval` (existing, `ImportModels.swift`: `var stage: String; var start, end: Date`).
- Produces:
  - `OuraHypnogram.stageName(_ ch: Character) -> String?`
  - `OuraHypnogram.decode(_ phases: String, start: Date, epochSeconds: Int) -> [WearableSleepStageInterval]`
  - `OuraHypnogram.movement(_ s: String) -> [Int]`

- [ ] **Step 1: Write the failing test**

Create `Packages/StrandImport/Tests/StrandImportTests/OuraHypnogramTests.swift`:

```swift
import XCTest
@testable import StrandImport

final class OuraHypnogramTests: XCTestCase {
    private func d(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testStageLegendMapsOuraDigits() {
        XCTAssertEqual(OuraHypnogram.stageName("1"), "deep")
        XCTAssertEqual(OuraHypnogram.stageName("2"), "light")
        XCTAssertEqual(OuraHypnogram.stageName("3"), "rem")
        XCTAssertEqual(OuraHypnogram.stageName("4"), "wake")
        XCTAssertNil(OuraHypnogram.stageName("0"))
    }

    func testDecodeMergesAdjacentEqualStagesAndAligns() {
        let start = d("2026-01-01T23:00:00Z")
        // "1123" → deep(2 epochs merged), light(1), rem(1); 5-min epochs.
        let segs = OuraHypnogram.decode("1123", start: start, epochSeconds: 300)
        XCTAssertEqual(segs.map(\.stage), ["deep", "light", "rem"])
        XCTAssertEqual(segs[0].start, start)
        XCTAssertEqual(segs[0].end, start.addingTimeInterval(600))   // two 5-min epochs merged
        XCTAssertEqual(segs[2].end, start.addingTimeInterval(1200))  // total 4 epochs = 20 min
    }

    func testMovementLegendIsDistinctFromStages() {
        // movement uses 1=no motion … 4=active; unknown → 0.
        XCTAssertEqual(OuraHypnogram.movement("1234x"), [1, 2, 3, 4, 0])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/StrandImport --filter OuraHypnogramTests`
Expected: FAIL — `OuraHypnogram` undefined.

- [ ] **Step 3: Implement the decoder**

Create `Packages/StrandImport/Sources/StrandImport/OuraHypnogram.swift`:

```swift
import Foundation

// MARK: - Oura compact per-epoch sleep strings (DOCUMENTED Oura API v2 encodings; NOOP's own decoder)
//
// The Oura `sleep` object carries two compact strings. Their digit legends are DIFFERENT — never share a
// decoder between them:
//   • sleep_phase_5_min / sleep_phase_30_sec — the hypnogram: '1'=deep, '2'=light, '3'=REM, '4'=awake.
//   • movement_30_sec                         — motion:      '1'=no motion, '2'=restless, '3'=tossing, '4'=active.

public enum OuraHypnogram {

    /// `sleep_phase_*` digit → NOOP stage string ("deep"/"light"/"rem"/"wake", matching
    /// `WearableSleepStageInterval`). Unknown digits → nil (skipped, the epoch clock still advances).
    public static func stageName(_ ch: Character) -> String? {
        switch ch {
        case "1": return "deep"
        case "2": return "light"
        case "3": return "rem"
        case "4": return "wake"
        default:  return nil
        }
    }

    /// Decode a `sleep_phase_5_min` (epochSeconds 300) or `sleep_phase_30_sec` (epochSeconds 30) string into
    /// contiguous [{stage,start,end}] segments, epoch-aligned from `start`. Adjacent equal stages are merged.
    public static func decode(_ phases: String, start: Date, epochSeconds: Int) -> [WearableSleepStageInterval] {
        var out: [WearableSleepStageInterval] = []
        for (i, ch) in phases.enumerated() {
            guard let stage = stageName(ch) else { continue }
            let segStart = start.addingTimeInterval(Double(i * epochSeconds))
            let segEnd = segStart.addingTimeInterval(Double(epochSeconds))
            if var last = out.last, last.stage == stage, last.end == segStart {
                last.end = segEnd
                out[out.count - 1] = last
            } else {
                out.append(WearableSleepStageInterval(stage: stage, start: segStart, end: segEnd))
            }
        }
        return out
    }

    /// Decode `movement_30_sec` into per-epoch motion magnitudes 1…4 (unknown digit → 0). 30-sec epochs.
    public static func movement(_ s: String) -> [Int] {
        s.map { ch in
            switch ch { case "1": return 1; case "2": return 2; case "3": return 3; case "4": return 4
                        default: return 0 }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/StrandImport --filter OuraHypnogramTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/StrandImport/Sources/StrandImport/OuraHypnogram.swift \
        Packages/StrandImport/Tests/StrandImportTests/OuraHypnogramTests.swift
git commit -m "feat(import): OuraHypnogram decoder (sleep_phase + movement, distinct legends)"
```

---

### Task 3: `OuraApiParser.parseSleep` + sleep models

Parse detailed `sleep` periods into the shared `WearableSleepSession` (now WITH stages — the headline win) plus the rich extras (movement, in-sleep HR) the shared model can't hold, and fold the per-day sleep rollup.

**Files:**
- Create: `Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift`
- Create: `Packages/StrandImport/Sources/StrandImport/OuraApiParser.swift`
- Test: `Packages/StrandImport/Tests/StrandImportTests/OuraApiParserSleepTests.swift`

**Interfaces:**
- Consumes: `OuraHypnogram` (Task 2); existing `WearableSleepSession`, `WearableDailyRow`, `WearableJSON` (`str`/`dbl`/`posDbl`/`posInt`, in `WearableExportImporter.swift:329`), `WhoopTime.parseISOWithOffset(_:)` (`CSVParsing.swift:509`), `WearableExportImporter.dayString(_:)`.
- Produces:
  - `struct OuraHRPoint { let ts: Int; let bpm: Int }`
  - `struct OuraSleepPeriod { var session: WearableSleepSession; var movement30s: [Int]; var hr: [OuraHRPoint] }`
  - `enum OuraApiParser` with `static func parseSleep(_ docs: [[String: Any]]) -> (periods: [OuraSleepPeriod], days: [WearableDailyRow])` and `static func sampleSeries(_ any: Any?) -> [OuraHRPoint]`.

- [ ] **Step 1: Write the failing test**

Create `Packages/StrandImport/Tests/StrandImportTests/OuraApiParserSleepTests.swift`:

```swift
import XCTest
@testable import StrandImport

final class OuraApiParserSleepTests: XCTestCase {
    func testParsesPeriodWithHypnogramAndFoldsDay() throws {
        let docs: [[String: Any]] = [[
            "id": "s1", "day": "2026-01-02",
            "bedtime_start": "2026-01-01T23:00:00+00:00",
            "bedtime_end": "2026-01-02T06:00:00+00:00",
            "total_sleep_duration": 24000, "deep_sleep_duration": 6000,
            "light_sleep_duration": 12000, "rem_sleep_duration": 6000, "awake_time": 1200,
            "efficiency": 92, "average_heart_rate": 55, "lowest_heart_rate": 48,
            "average_hrv": 65, "average_breath": 14.2,
            "sleep_phase_5_min": "1234",
            "movement_30_sec": "1212",
            "heart_rate": ["interval": 300, "timestamp": "2026-01-01T23:00:00+00:00",
                           "items": [60, 58, NSNull(), 57]]
        ]]
        let (periods, days) = OuraApiParser.parseSleep(docs)
        XCTAssertEqual(periods.count, 1)
        let p = try XCTUnwrap(periods.first)
        XCTAssertEqual(p.session.totalSleepMin, 400)              // 24000s ÷ 60
        XCTAssertEqual(p.session.lowestHr, 48)
        XCTAssertEqual(p.session.avgHrvMs, 65)
        XCTAssertEqual(p.session.stages.map(\.stage), ["deep", "light", "rem", "wake"])
        XCTAssertEqual(p.movement30s, [1, 2, 1, 2])
        XCTAssertEqual(p.hr.map(\.bpm), [60, 58, 57])            // null sample dropped
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.day, "2026-01-02")
        XCTAssertEqual(days.first?.totalSleepMin, 400)
        XCTAssertEqual(days.first?.restingHr, 48)                // lowestHr ≈ resting fallback
    }

    func testSkipsPeriodWithInvalidSpan() {
        let (periods, _) = OuraApiParser.parseSleep([["bedtime_start": "nope", "bedtime_end": "nope"]])
        XCTAssertTrue(periods.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/StrandImport --filter OuraApiParserSleepTests`
Expected: FAIL — `OuraApiParser` / `OuraSleepPeriod` undefined.

- [ ] **Step 3: Add the sleep models**

Create `Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift`:

```swift
import Foundation

// MARK: - Neutral models emitted by OuraApiParser (network-free; the app-target writer maps them to WhoopStore).

/// One heart-rate sample (→ hrSample on write). `ts` is unix seconds, `bpm` is positive.
public struct OuraHRPoint: Sendable, Equatable {
    public let ts: Int
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

/// One Oura detailed sleep period: the shared `session` (incl. decoded stages) plus the rich extras the
/// shared model can't hold. `movement30s` → sleepSession.motionJSON; `hr` → hrSample. (HRV samples stay
/// in the raw archive only — there is no rMSSD-per-sample table; the per-night average is on `session`.)
public struct OuraSleepPeriod: Sendable, Equatable {
    public var session: WearableSleepSession
    public var movement30s: [Int]
    public var hr: [OuraHRPoint]
    public init(session: WearableSleepSession, movement30s: [Int], hr: [OuraHRPoint]) {
        self.session = session; self.movement30s = movement30s; self.hr = hr
    }
}
```

- [ ] **Step 4: Implement `parseSleep`**

Create `Packages/StrandImport/Sources/StrandImport/OuraApiParser.swift`:

```swift
import Foundation

// MARK: - Oura API v2 document parser (PURE / network-free)
//
// Takes already-fetched JSON `data[]` arrays (the OuraAPIClient does the I/O in the app target) and maps
// them to NOOP's normalized models. Reuses the SAME field semantics as OuraExportParser — the account export
// and the API share field names (bedtime_start, total_sleep_duration, …) — and adds the hypnogram +
// time-series the file export never carried. Crafted-input safe via WearableJSON.

public enum OuraApiParser {

    /// Parse `sleep` documents (detailed periods; multiple per day are possible). Returns one
    /// `OuraSleepPeriod` per usable period plus a per-day sleep rollup folded onto `WearableDailyRow`.
    public static func parseSleep(_ docs: [[String: Any]]) -> (periods: [OuraSleepPeriod], days: [WearableDailyRow]) {
        var periods: [OuraSleepPeriod] = []
        var byDay: [String: WearableDailyRow] = [:]

        for s in docs {
            guard let start = WhoopTime.parseISOWithOffset(WearableJSON.str(s, "bedtime_start")),
                  let end = WhoopTime.parseISOWithOffset(WearableJSON.str(s, "bedtime_end")),
                  end > start else { continue }

            // Durations are SECONDS in the API → minutes.
            func minutes(_ k: String) -> Double? { WearableJSON.posDbl(s, k).map { $0 / 60.0 } }

            // Stages: prefer the finer 30-sec hypnogram, else the 5-min; never synthesize one.
            let stages: [WearableSleepStageInterval]
            if let p30 = WearableJSON.str(s, "sleep_phase_30_sec"), !p30.isEmpty {
                stages = OuraHypnogram.decode(p30, start: start, epochSeconds: 30)
            } else if let p5 = WearableJSON.str(s, "sleep_phase_5_min"), !p5.isEmpty {
                stages = OuraHypnogram.decode(p5, start: start, epochSeconds: 300)
            } else {
                stages = []
            }

            let session = WearableSleepSession(
                start: start, end: end,
                deepMin: minutes("deep_sleep_duration"),
                lightMin: minutes("light_sleep_duration"),
                remMin: minutes("rem_sleep_duration"),
                awakeMin: minutes("awake_time"),
                totalSleepMin: minutes("total_sleep_duration"),
                efficiencyPct: WearableJSON.posDbl(s, "efficiency"),
                avgHr: WearableJSON.posInt(s, "average_heart_rate"),
                lowestHr: WearableJSON.posInt(s, "lowest_heart_rate"),
                avgHrvMs: WearableJSON.posDbl(s, "average_hrv"),
                respRateBpm: WearableJSON.posDbl(s, "average_breath"),
                sleepScore: nil,                                // the night's reference score comes from daily_sleep
                stages: stages)

            let movement = WearableJSON.str(s, "movement_30_sec").map(OuraHypnogram.movement) ?? []
            let hr = sampleSeries(s["heart_rate"])
            periods.append(OuraSleepPeriod(session: session, movement30s: movement, hr: hr))

            // Fold the night onto its calendar day (Oura's "day" = the wake day).
            let key = WearableJSON.str(s, "day") ?? WearableExportImporter.dayString(end)
            var row = byDay[key] ?? WearableDailyRow(day: key)
            row.totalSleepMin = row.totalSleepMin ?? session.totalSleepMin
            row.deepMin = row.deepMin ?? session.deepMin
            row.lightMin = row.lightMin ?? session.lightMin
            row.remMin = row.remMin ?? session.remMin
            row.awakeMin = row.awakeMin ?? session.awakeMin
            row.efficiencyPct = row.efficiencyPct ?? session.efficiencyPct
            row.avgHrvMs = row.avgHrvMs ?? session.avgHrvMs
            if row.restingHr == nil { row.restingHr = session.lowestHr }
            byDay[key] = row
        }
        return (periods, Array(byDay.values))
    }

    /// Decode an Oura `PublicSample` object ({interval, items:[Double?], timestamp}) into HR points.
    /// Non-finite / non-positive items are dropped (Oura uses null/0 for gaps).
    static func sampleSeries(_ any: Any?) -> [OuraHRPoint] {
        guard let obj = any as? [String: Any],
              let interval = WearableJSON.dbl(obj, "interval"), interval > 0,
              let items = obj["items"] as? [Any],
              let t0 = WhoopTime.parseISOWithOffset(WearableJSON.str(obj, "timestamp")) else { return [] }
        var out: [OuraHRPoint] = []
        for (i, item) in items.enumerated() {
            guard let v = (item as? Double) ?? (item as? NSNumber)?.doubleValue, v.isFinite, v > 0 else { continue }
            out.append(OuraHRPoint(ts: Int(t0.timeIntervalSince1970 + Double(i) * interval), bpm: Int(v)))
        }
        return out
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Packages/StrandImport --filter OuraApiParserSleepTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift \
        Packages/StrandImport/Sources/StrandImport/OuraApiParser.swift \
        Packages/StrandImport/Tests/StrandImportTests/OuraApiParserSleepTests.swift
git commit -m "feat(import): OuraApiParser.parseSleep — sessions with hypnogram, movement, in-sleep HR"
```

---

### Task 4: `OuraApiParser.parseDaily` (summary endpoints) + extras

One dispatching parser for the day-keyed summary endpoints. Maps onto `WearableDailyRow` columns where a home exists; everything else becomes `OuraDailyExtra` points (→ `metricSeries`). Oura's own scores land ONLY under `ref_*`/`oura_*` keys (honest data).

**Files:**
- Modify: `Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift` (add `OuraDailyExtra`)
- Create: `Packages/StrandImport/Sources/StrandImport/OuraApiParser+Daily.swift`
- Test: `Packages/StrandImport/Tests/StrandImportTests/OuraApiParserDailyTests.swift`

**Interfaces:**
- Consumes: existing `WearableDailyRow`, `WearableJSON`.
- Produces:
  - `struct OuraDailyExtra { let day: String; let key: String; let value: Double }`
  - `OuraApiParser.parseDaily(_ docs: [[String: Any]], endpoint: String) -> (days: [WearableDailyRow], extras: [OuraDailyExtra])`
  - `OuraApiParser.resilienceLevel(_ s: String?) -> Double?`

- [ ] **Step 1: Write the failing test**

Create `Packages/StrandImport/Tests/StrandImportTests/OuraApiParserDailyTests.swift`:

```swift
import XCTest
@testable import StrandImport

final class OuraApiParserDailyTests: XCTestCase {
    func testReadinessMapsRhrSkinTempAndRefScore() {
        let (days, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "score": 80, "temperature_deviation": -0.2,
            "contributors": ["resting_heart_rate": 50, "hrv_balance": 70]
        ]], endpoint: "daily_readiness")
        XCTAssertEqual(days.first?.restingHr, 50)
        XCTAssertEqual(days.first?.skinTempDevC, -0.2)
        XCTAssertEqual(days.first?.readinessScore, 80)
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "ref_readiness_score", value: 80)))
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "oura_readiness_hrv_balance", value: 70)))
    }

    func testActivityMapsStepsAndScoreIsReferenceOnly() {
        let (days, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "score": 88, "steps": 9000,
            "active_calories": 500, "total_calories": 2400
        ]], endpoint: "daily_activity")
        XCTAssertEqual(days.first?.steps, 9000)
        XCTAssertEqual(days.first?.activeKcal, 500)
        // The activity SCORE is reference-only — never a dailyMetric score column.
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "ref_activity_score", value: 88)))
    }

    func testResilienceLevelEncodedReferenceOnly() {
        let (_, extras) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "level": "solid", "contributors": ["sleep_recovery": 60.0]
        ]], endpoint: "daily_resilience")
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "ref_resilience_level", value: 3)))
        XCTAssertTrue(extras.contains(OuraDailyExtra(day: "2026-01-02", key: "oura_resilience_sleep_recovery", value: 60)))
    }

    func testSpo2MapsAverage() {
        let (days, _) = OuraApiParser.parseDaily([[
            "day": "2026-01-02", "spo2_percentage": ["average": 96.5]
        ]], endpoint: "daily_spo2")
        XCTAssertEqual(days.first?.spo2Pct, 96.5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/StrandImport --filter OuraApiParserDailyTests`
Expected: FAIL — `parseDaily` / `OuraDailyExtra` undefined.

- [ ] **Step 3: Add the `OuraDailyExtra` model**

Append to `Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift`:

```swift
/// One extra daily scalar Oura returns that the wide `dailyMetric` columns don't hold (→ metricSeries on
/// write). `key` is the metricSeries key; the brand's OWN scores use a `ref_` prefix and its contributor
/// breakdowns an `oura_` prefix, so they are browseable but never mistaken for a NOOP score.
public struct OuraDailyExtra: Sendable, Equatable {
    public let day: String
    public let key: String
    public let value: Double
    public init(day: String, key: String, value: Double) { self.day = day; self.key = key; self.value = value }
}
```

- [ ] **Step 4: Implement `parseDaily`**

Create `Packages/StrandImport/Sources/StrandImport/OuraApiParser+Daily.swift`:

```swift
import Foundation

public extension OuraApiParser {

    /// Parse a day-keyed summary endpoint's documents. `endpoint` selects the field mapping. Writes to
    /// `WearableDailyRow` columns only where the on-device schema already has a home (RHR, skin-temp dev,
    /// steps, calories, SpO2); everything else — and ALL of Oura's own scores — becomes `OuraDailyExtra`.
    static func parseDaily(_ docs: [[String: Any]], endpoint: String) -> (days: [WearableDailyRow], extras: [OuraDailyExtra]) {
        var byDay: [String: WearableDailyRow] = [:]
        var extras: [OuraDailyExtra] = []
        func extra(_ day: String, _ key: String, _ v: Double?) {
            if let v { extras.append(OuraDailyExtra(day: day, key: key, value: v)) }
        }

        for doc in docs {
            guard let day = WearableJSON.str(doc, "day") else { continue }
            switch endpoint {

            case "daily_readiness":
                var r = byDay[day] ?? WearableDailyRow(day: day)
                if let c = doc["contributors"] as? [String: Any] {
                    r.restingHr = WearableJSON.posInt(c, "resting_heart_rate") ?? r.restingHr
                    for (k, _) in c { extra(day, "oura_readiness_\(k)", WearableJSON.posDbl(c, k)) }
                }
                r.skinTempDevC = WearableJSON.dbl(doc, "temperature_deviation") ?? r.skinTempDevC
                r.readinessScore = WearableJSON.posInt(doc, "score") ?? r.readinessScore
                extra(day, "ref_readiness_score", WearableJSON.posDbl(doc, "score"))
                byDay[day] = r

            case "daily_sleep":
                extra(day, "ref_sleep_score", WearableJSON.posDbl(doc, "score"))
                if let c = doc["contributors"] as? [String: Any] {
                    for (k, _) in c { extra(day, "oura_sleep_\(k)", WearableJSON.posDbl(c, k)) }
                }

            case "daily_activity":
                var r = byDay[day] ?? WearableDailyRow(day: day)
                r.steps = WearableJSON.posInt(doc, "steps") ?? r.steps
                r.activeKcal = WearableJSON.posDbl(doc, "active_calories") ?? r.activeKcal
                r.totalKcal = WearableJSON.posDbl(doc, "total_calories") ?? r.totalKcal
                extra(day, "ref_activity_score", WearableJSON.posDbl(doc, "score"))
                extra(day, "oura_equiv_walk_m", WearableJSON.posDbl(doc, "equivalent_walking_distance"))
                byDay[day] = r

            case "daily_spo2":
                var r = byDay[day] ?? WearableDailyRow(day: day)
                if let s = doc["spo2_percentage"] as? [String: Any] {
                    r.spo2Pct = WearableJSON.posDbl(s, "average") ?? r.spo2Pct
                    extra(day, "spo2", WearableJSON.posDbl(s, "average"))
                }
                extra(day, "oura_breathing_disturbance_index", WearableJSON.dbl(doc, "breathing_disturbance_index"))
                byDay[day] = r

            case "daily_stress":
                extra(day, "oura_stress_high_s", WearableJSON.posDbl(doc, "stress_high"))
                extra(day, "oura_recovery_high_s", WearableJSON.posDbl(doc, "recovery_high"))

            case "daily_resilience":
                if let c = doc["contributors"] as? [String: Any] {
                    for (k, _) in c { extra(day, "oura_resilience_\(k)", WearableJSON.dbl(c, k)) }
                }
                extra(day, "ref_resilience_level", resilienceLevel(WearableJSON.str(doc, "level")))

            case "daily_cardiovascular_age":
                extra(day, "oura_vascular_age", WearableJSON.dbl(doc, "vascular_age"))
                extra(day, "oura_pulse_wave_velocity", WearableJSON.dbl(doc, "pulse_wave_velocity"))

            case "vO2_max":
                extra(day, "vo2max", WearableJSON.posDbl(doc, "vo2_max"))

            default:
                break
            }
        }
        return (Array(byDay.values), extras)
    }

    /// Oura resilience level → an ordered reference number (1…5). Reference-only — never a NOOP score.
    static func resilienceLevel(_ s: String?) -> Double? {
        switch s {
        case "limited":     return 1
        case "adequate":    return 2
        case "solid":       return 3
        case "strong":      return 4
        case "exceptional": return 5
        default:            return nil
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Packages/StrandImport --filter OuraApiParserDailyTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift \
        Packages/StrandImport/Sources/StrandImport/OuraApiParser+Daily.swift \
        Packages/StrandImport/Tests/StrandImportTests/OuraApiParserDailyTests.swift
git commit -m "feat(import): OuraApiParser.parseDaily — summary endpoints, scores kept reference-only"
```

---

### Task 5: `OuraApiParser` events — workouts + heart-rate time series

Parse `workout` documents (→ workout table later) and the `/heartrate` time-series page (→ hrSample later).

**Files:**
- Modify: `Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift` (add `OuraWorkout`)
- Create: `Packages/StrandImport/Sources/StrandImport/OuraApiParser+Events.swift`
- Test: `Packages/StrandImport/Tests/StrandImportTests/OuraApiParserEventsTests.swift`

**Interfaces:**
- Consumes: existing `WearableJSON`, `WhoopTime.parseISOWithOffset(_:)`; `OuraHRPoint` (Task 3).
- Produces:
  - `struct OuraWorkout { let start: Date; let end: Date; let activity: String; let source: String; let energyKcal: Double?; let distanceM: Double? }`
  - `OuraApiParser.parseWorkouts(_ docs: [[String: Any]]) -> [OuraWorkout]`
  - `OuraApiParser.parseHeartRate(_ docs: [[String: Any]]) -> [OuraHRPoint]`

- [ ] **Step 1: Write the failing test**

Create `Packages/StrandImport/Tests/StrandImportTests/OuraApiParserEventsTests.swift`:

```swift
import XCTest
@testable import StrandImport

final class OuraApiParserEventsTests: XCTestCase {
    func testWorkoutParse() throws {
        let w = OuraApiParser.parseWorkouts([[
            "activity": "running", "source": "autodetected",
            "start_datetime": "2026-01-02T07:00:00+00:00", "end_datetime": "2026-01-02T07:40:00+00:00",
            "calories": 410, "distance": 6200
        ]])
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w.first?.activity, "running")
        XCTAssertEqual(w.first?.source, "autodetected")
        XCTAssertEqual(w.first?.energyKcal, 410)
        XCTAssertEqual(w.first?.distanceM, 6200)
    }

    func testHeartRatePageParseDropsNonPositive() {
        let hr = OuraApiParser.parseHeartRate([
            ["timestamp": "2026-01-02T07:00:00+00:00", "bpm": 120, "source": "workout"],
            ["timestamp": "2026-01-02T07:05:00+00:00", "bpm": 0,   "source": "workout"]   // dropped
        ])
        XCTAssertEqual(hr.map(\.bpm), [120])
        XCTAssertEqual(hr.first?.ts, Int(ISO8601DateFormatter().date(from: "2026-01-02T07:00:00Z")!.timeIntervalSince1970))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/StrandImport --filter OuraApiParserEventsTests`
Expected: FAIL — `parseWorkouts` / `OuraWorkout` undefined.

- [ ] **Step 3: Add the `OuraWorkout` model**

Append to `Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift`:

```swift
/// One Oura workout (→ the `workout` table on write). Times are UTC; metric fields nil when absent.
public struct OuraWorkout: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let activity: String
    public let source: String
    public let energyKcal: Double?
    public let distanceM: Double?
    public init(start: Date, end: Date, activity: String, source: String, energyKcal: Double?, distanceM: Double?) {
        self.start = start; self.end = end; self.activity = activity; self.source = source
        self.energyKcal = energyKcal; self.distanceM = distanceM
    }
}
```

- [ ] **Step 4: Implement the event parsers**

Create `Packages/StrandImport/Sources/StrandImport/OuraApiParser+Events.swift`:

```swift
import Foundation

public extension OuraApiParser {

    /// Parse `workout` documents → `OuraWorkout`. Rows without a valid time span are skipped.
    static func parseWorkouts(_ docs: [[String: Any]]) -> [OuraWorkout] {
        var out: [OuraWorkout] = []
        for w in docs {
            guard let start = WhoopTime.parseISOWithOffset(WearableJSON.str(w, "start_datetime")),
                  let end = WhoopTime.parseISOWithOffset(WearableJSON.str(w, "end_datetime")),
                  end > start else { continue }
            out.append(OuraWorkout(
                start: start, end: end,
                activity: WearableJSON.str(w, "activity") ?? "workout",
                source: WearableJSON.str(w, "source") ?? "oura",
                energyKcal: WearableJSON.posDbl(w, "calories"),
                distanceM: WearableJSON.posDbl(w, "distance")))
        }
        return out
    }

    /// Parse a `/v2/usercollection/heartrate` page's `data[]` → HR points. Each row is
    /// {timestamp, bpm, source}; non-positive bpm is dropped. (The `source` enum is preserved in the raw
    /// archive, not in the compact hrSample.)
    static func parseHeartRate(_ docs: [[String: Any]]) -> [OuraHRPoint] {
        var out: [OuraHRPoint] = []
        for h in docs {
            guard let ts = WhoopTime.parseISOWithOffset(WearableJSON.str(h, "timestamp")),
                  let bpm = WearableJSON.posInt(h, "bpm") else { continue }
            out.append(OuraHRPoint(ts: Int(ts.timeIntervalSince1970), bpm: bpm))
        }
        return out
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path Packages/StrandImport --filter OuraApiParserEventsTests`
Expected: PASS.

- [ ] **Step 6: Run the full package test suites (no regressions)**

Run: `swift test --package-path Packages/StrandImport && swift test --package-path Packages/WhoopStore`
Expected: PASS (all existing tests + the 5 new suites).

- [ ] **Step 7: Commit**

```bash
git add Packages/StrandImport/Sources/StrandImport/OuraApiModels.swift \
        Packages/StrandImport/Sources/StrandImport/OuraApiParser+Events.swift \
        Packages/StrandImport/Tests/StrandImportTests/OuraApiParserEventsTests.swift
git commit -m "feat(import): OuraApiParser workouts + heartrate time-series parsing"
```

---

## Plan 1 self-review

- **Spec coverage:** §8.5 raw store → T1. §8.2 hypnogram/movement/in-sleep HR → T2/T3. `sleep` mapping → T3. Daily summaries + reference-only scores (§8.1, G4) → T4. Workouts + heartrate (§8.1, §8.3) → T5. Sessions/tags/rest_mode/personal_info/ring_* normalization is intentionally deferred to Plan 3's writer (raw-archived here via T1's store regardless). No spec requirement for the *foundation* layer is unaddressed.
- **Network-free:** every new file imports only `Foundation`/`GRDB`. ✓ (Constraint.)
- **Honest data:** every Oura score is emitted under `ref_*`/`oura_*` only; no path writes `recovery`/`strain`. ✓ (Asserted in T4.)
- **Type consistency:** `OuraHRPoint` defined in T3, reused verbatim in T5. `OuraApiParser` opened in T3, extended in T4/T5. `OuraDailyExtra`/`OuraWorkout` appended to the same `OuraApiModels.swift`. No dangling references.
- **No placeholders:** every step has full code + exact run command + expected result.

## What Plans 2 & 3 add (scope preview — detailed separately on request)

- **Plan 2 — Network + auth (app target `Strand/Oura/`):** `OuraCredentials` (xcconfig→Info.plist), `OuraTokenStore` (Keychain, mirroring `AIKeyStore`), `AuthProvider` + `OuraOAuthProvider` (`ASWebAuthenticationSession` + code→token exchange, refresh), `OuraAPIClient` (`URLSession`, `next_token` paging, 429/401 handling, prod/sandbox base URL) — tested with a `URLProtocol` stub and the Oura sandbox tree.
- **Plan 3 — Orchestration + UI + wiring:** `OuraSyncWriter` (parsed models → `upsertDailyMetrics`/`upsertSleepSessions`(+stagesJSON/motionJSON)/`upsertMetricSeries`/`insert(hrSample)`/`upsertWorkouts` + `upsertOuraRaw` + `DeviceRegistryStore.add`, no day-ownership seizure), `OuraSyncCoordinator` (one-time backfill across all endpoints), `DataSourceKind.ouraApi` + exhaustive-switch updates, the Data Sources "Connect Oura & Import Everything" card/progress/summary/disconnect, `project.yml`/Info.plist/.gitignore wiring, and doc updates (`PRIVACY_SECURITY.md` second opt-in network lane, `DEVICE_SUPPORT_ROADMAP.md`, `DATA_MODEL.md`).

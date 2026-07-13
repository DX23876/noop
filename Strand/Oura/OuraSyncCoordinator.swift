// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation
import WhoopStore
import WhoopProtocol
import StrandImport

/// Abstracts the page fetch so the coordinator is testable without a live network (OuraAPIClient conforms).
protocol OuraPageFetching {
    func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data]
}
extension OuraAPIClient: OuraPageFetching {}

struct OuraSyncProgress: Equatable {
    let endpoint: String
    let pages: Int
    /// Optional human detail (e.g. "window 4/17" for the chunked heartrate fetch).
    var detail: String? = nil
}

/// One-time backfill across every Oura v2 endpoint → an assembled OuraSyncResult → OuraSyncWriter. Merges
/// the per-day WearableDailyRows across endpoints (daily endpoints BEFORE sleep). Resting HR comes
/// exclusively from sleep's `lowest_heart_rate` — no daily endpoint sets it (see `OuraApiParser.parseDaily`).
final class OuraSyncCoordinator {
    private let fetcher: OuraPageFetching
    private let store: WhoopStore
    init(fetcher: OuraPageFetching, store: WhoopStore) { self.fetcher = fetcher; self.store = store }

    /// Daily-summary endpoints handed to `parseDaily(_, endpoint:)`. Merge order doesn't affect resting HR
    /// (only `sleep`, merged separately below, ever sets it); `daily_readiness`, `daily_sleep` etc.
    /// contribute their other fields / extras only.
    private static let dailyEndpoints = ["daily_readiness", "daily_activity", "daily_spo2", "daily_sleep",
                                         "daily_stress", "daily_resilience", "daily_cardiovascular_age", "vO2_max"]
    /// Endpoints with no Plan-1 parser — archived raw only.
    private static let rawOnlyEndpoints = ["personal_info", "ring_configuration", "sleep_time", "session",
                                           "tag", "enhanced_tag", "rest_mode_period", "ring_battery_level"]

    func runFullImport(startDate: String = "2013-01-01", today: String,
                       onProgress: @escaping (OuraSyncProgress) -> Void = { _ in }) async throws -> OuraSyncSummary {
        let deviceId = "oura-api"
        var result = OuraSyncResult()
        var byDay: [String: WearableDailyRow] = [:]

        func fetchRawQuery(_ endpoint: String, query: [String: String]) async throws -> [Data] {
            let pages = try await fetcher.fetchAllRaw(endpoint: endpoint, query: query)
            // Window-scoped raw key so multi-window endpoints (heartrate) never collide, and a re-pull
            // of the same window stays idempotent (same key → upsert overwrite).
            let windowKey = query["start_datetime"] ?? query["start_date"] ?? startDate
            var idx = 0
            for body in pages {
                result.rawPages.append(OuraRawRow(endpoint: endpoint, documentId: "\(endpoint)-\(windowKey)-\(idx)",
                                                  day: nil, payloadJSON: String(data: body, encoding: .utf8) ?? "",
                                                  fetchedAt: Int(Date().timeIntervalSince1970)))
                idx += 1
            }
            onProgress(OuraSyncProgress(endpoint: endpoint, pages: pages.count))
            return pages
        }
        func fetchRaw(_ endpoint: String, dateParam: String?) async throws -> [Data] {
            var q: [String: String] = [:]
            if let dateParam { q[dateParam] = startDate; q[dateParam == "start_datetime" ? "end_datetime" : "end_date"] = today }
            return try await fetchRawQuery(endpoint, query: q)
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

        // One failing endpoint must not abort the whole backfill (spec §7 — honest partial). A fetch
        // error (e.g. a scope 401 like the live spo2 naming mismatch) records the endpoint as skipped
        // and the run continues; the UI surfaces the skips from the summary.
        var skipped: [String] = []

        // Daily endpoints first, extras accumulate. None of them set resting HR (see parseDaily).
        for endpoint in Self.dailyEndpoints {
            do {
                let pages = try await fetchRaw(endpoint, dateParam: "start_date")
                let (days, extras) = OuraApiParser.parseDaily(docs(pages), endpoint: endpoint)
                merge(days); result.extras.append(contentsOf: extras)
            } catch { skipped.append(endpoint) }
        }
        // Sleep last: its lowestHr is the sole resting-HR source (no daily endpoint sets one).
        do {
            let sleepPages = try await fetchRaw("sleep", dateParam: "start_date")
            let (periods, sleepDays) = OuraApiParser.parseSleep(docs(sleepPages))
            result.sleepPeriods = periods; merge(sleepDays)
        } catch { skipped.append("sleep") }
        // Workouts.
        do {
            let workoutPages = try await fetchRaw("workout", dateParam: "start_date")
            result.workouts = OuraApiParser.parseWorkouts(docs(workoutPages))
        } catch { skipped.append("workout") }
        // Raw-only endpoints (no parser).
        for endpoint in Self.rawOnlyEndpoints {
            do {
                _ = try await fetchRaw(endpoint, dateParam: ["personal_info", "ring_configuration"].contains(endpoint) ? nil : "start_date")
            } catch { skipped.append(endpoint) }
        }

        // Persist the light data (days/sleeps/workouts/extras/raw + source registration) FIRST, as a
        // durable checkpoint. It's small and fetched one call apiece; landing it in SQLite before the long
        // heart-rate backfill means an interruption during HR can never cost it.
        result.days = Array(byDay.values)
        onProgress(OuraSyncProgress(endpoint: "saving", pages: 0))
        var summary = try await OuraSyncWriter.persist(result, into: store, deviceId: deviceId)

        // Whole-day heart-rate: the ONE endpoint with a hard ≤30-day range cap (probe-verified: a wider
        // span is HTTP 400 "Timerange ... has to be less than or equal to 30 days"; an unencoded '+00:00'
        // offset 422s since '+' decodes to a space). Fetched in 30-day windows of full ISO-'Z' datetimes,
        // floored at the earliest day the dailies returned (never page years of empty pre-account time).
        // CRITICAL: each window is PERSISTED before advancing, so a lock or interruption keeps every
        // completed window instead of losing the whole series (the prior one-shot end-persist did exactly
        // that). Re-runs re-fetch from the floor; hrSample dedupes on (deviceId, ts) and ouraRaw on
        // (endpoint, documentId), so replaying an already-saved window is a harmless overwrite.
        do {
            let floorDay = byDay.keys.min() ?? startDate
            var cursor = Self.dayFmt.date(from: floorDay) ?? Date(timeIntervalSince1970: 0)
            let endDate = (Self.dayFmt.date(from: today) ?? Date()).addingTimeInterval(86_400)
            let totalWindows = max(1, Int(ceil(endDate.timeIntervalSince(cursor) / (30 * 86_400))))
            let fetchedAt = Int(Date().timeIntervalSince1970)
            var window = 0
            while cursor < endDate {
                window += 1
                onProgress(OuraSyncProgress(endpoint: "heartrate", pages: 0, detail: "window \(window)/\(totalWindows)"))
                let next = min(cursor.addingTimeInterval(30 * 86_400), endDate)
                let startISO = Self.isoFmt.string(from: cursor)
                let pages = try await fetcher.fetchAllRaw(endpoint: "heartrate",
                    query: ["start_datetime": startISO, "end_datetime": Self.isoFmt.string(from: next)])
                // Persist THIS window before fetching the next — the durability guarantee.
                let rawRows = pages.enumerated().map { idx, body in
                    OuraRawRow(endpoint: "heartrate", documentId: "heartrate-\(startISO)-\(idx)", day: nil,
                               payloadJSON: String(data: body, encoding: .utf8) ?? "", fetchedAt: fetchedAt)
                }
                if !rawRows.isEmpty { summary.rawPages += try await store.upsertOuraRaw(rawRows, deviceId: deviceId) }
                let hr = OuraApiParser.parseHeartRate(docs(pages)).map { HRSample(ts: $0.ts, bpm: $0.bpm) }
                if !hr.isEmpty { summary.hrSamples += try await store.insert(Streams(hr: hr), deviceId: deviceId).hr }
                cursor = next
            }
        } catch { skipped.append("heartrate") }

        summary.skippedEndpoints = skipped
        return summary
    }

    // UTC day / ISO-'Z' datetime formatters for the windowed heartrate fetch.
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; return f
    }()
}
#endif // OURA_CLOUD_IMPORT

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
            row.respRateBpm = row.respRateBpm ?? session.respRateBpm
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
            // Finite-but-huge `ts` or `bpm` (e.g. a crafted `interval`/item of 1e300) must never trap
            // Int(...); skip the sample instead, mirroring WearableJSON.int's -9e18...9e18 range guard.
            let ts = t0.timeIntervalSince1970 + Double(i) * interval
            guard ts.isFinite, ts >= -9e18, ts <= 9e18, v <= 9e18 else { continue }
            out.append(OuraHRPoint(ts: Int(ts), bpm: Int(v)))
        }
        return out
    }
}

import Foundation
import StrandAnalytics
import WhoopProtocol
import StrandCore
import WhoopStore

/// The demo build's history in the core's store (Android plan E-3): six weeks of scored days, nights with stages
/// and Rest, so the screens show something on an emulator without a strap. Deterministic, so a screenshot taken
/// twice on the same day matches; written only into an empty store and only by the demo flavour.
public enum CoreDemo {
    public static let days = 42

    /// Writes the demo history under `deviceId`'s computed namespace when the store has no scored day yet;
    /// returns how many days it wrote (0 when the store already had some).
    @discardableResult
    public static func seedIfEmpty(store: WhoopStore, deviceId: String, now: Date = Date()) async throws -> Int {
        let computed = deviceId + "-noop"
        let today = StoreReader.localDayKey(now)
        guard try await store.dailyMetrics(deviceId: computed, from: "0000-01-01", to: today).isEmpty else { return 0 }
        let calendar = Calendar.current
        var rows: [DailyMetric] = [], rest: [MetricPoint] = [], nights: [CachedSleepSession] = []
        for back in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let day = StoreReader.localDayKey(date)
            let t = Double(days - back)
            let wave = sin(t / 3.1), slow = sin(t / 9.0)
            let deep = 78 + 14 * wave, rem = 96 + 12 * slow, light = 228 + 20 * sin(t / 2.3)
            let sleep = deep + rem + light
            let charge = (62 + 22 * wave + 8 * slow).rounded()
            let hrv = (78 + 12 * wave + 4 * slow).rounded()
            let rhr = Int((52 - 4 * wave).rounded())
            rows.append(DailyMetric(day: day, totalSleepMin: sleep.rounded(), efficiency: 0.9 + 0.04 * wave,
                                    deepMin: deep.rounded(), remMin: rem.rounded(), lightMin: light.rounded(),
                                    disturbances: 3, restingHr: rhr, avgHrv: hrv, recovery: charge,
                                    strain: (48 + 18 * sin(t / 1.7)).rounded(), exerciseCount: back % 3 == 0 ? 1 : 0,
                                    spo2Pct: 96 + wave, skinTempDevC: 0.2 * slow, respRateBpm: 14.4 + 0.4 * slow,
                                    steps: Int(8_500 + 2_500 * sin(t / 1.3))))
            rest.append(MetricPoint(day: day, key: "sleep_performance", value: (84 + 10 * wave).rounded()))
            guard let wake = calendar.date(bySettingHour: 7, minute: Int(20 + 15 * slow), second: 0, of: date) else {
                continue
            }
            let end = Int(wake.timeIntervalSince1970)
            let start = end - Int(sleep * 60) - 25 * 60
            nights.append(CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9 + 0.04 * wave,
                                             restingHr: rhr, avgHrv: hrv,
                                             stagesJSON: stagesJSON(start: start, end: end, deep: deep, rem: rem)))
        }
        _ = try await store.upsertDailyMetrics(rows, deviceId: computed)
        _ = try await store.insert(Streams(hr: heartRate(endingAt: now)), deviceId: deviceId)
        _ = try await store.upsertMetricSeries(rest, deviceId: computed)
        _ = try await store.upsertSleepSessions(nights, deviceId: computed)
        return rows.count
    }

    /// The last three days at one sample a minute: low and steady at night, higher and busier by day, with a
    /// workout late in the afternoon, so the Today trace has a day's shape.
    private static func heartRate(endingAt now: Date) -> [HRSample] {
        let end = Int(now.timeIntervalSince1970) / 60 * 60
        let calendar = Calendar.current
        return stride(from: end - 3 * 86_400, through: end, by: 60).map { ts in
            let hour = Double(calendar.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts))))
            let t = Double(ts) / 60
            let awake = hour >= 7 && hour < 23
            var bpm = awake ? 72 + 8 * sin(t / 47) + 4 * sin(t / 7.3) : 50 + 2 * sin(t / 31)
            if hour >= 17 && hour < 18 { bpm += 55 + 10 * sin(t / 5) }
            return HRSample(ts: ts, bpm: Int(bpm.rounded()))
        }
    }

    /// Four ninety-minute cycles: light into deep early, REM growing towards morning, short wakes between.
    private static func stagesJSON(start: Int, end: Int, deep: Double, rem: Double) -> String {
        var segments: [StageSegment] = []
        var t = start
        func add(_ stage: String, _ minutes: Double) {
            let next = min(end, t + Int(minutes * 60))
            if next > t { segments.append(StageSegment(start: t, end: next, stage: stage)) }
            t = next
        }
        add("wake", 12)
        let deepShare = [0.4, 0.3, 0.2, 0.1], remShare = [0.1, 0.2, 0.3, 0.4]
        for cycle in 0..<4 where t < end {
            add("light", 30)
            add("deep", deep * deepShare[cycle])
            add("light", 20)
            add("rem", rem * remShare[cycle])
            if cycle < 3 { add("wake", 3) }
        }
        add("light", Double(end - t) / 60)
        let data = (try? JSONEncoder().encode(segments)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Sources for target-value goals. The same reader assembles their windows and readings on Apple and Android.
@MainActor
protocol GoalLevelReading: AnyObject {
    func goalDays() async -> [DailyMetric]
    func goalLevelValues(key: String, source: String, days: Int) async -> [(day: String, value: Double)]
    func goalComputedSleepSessions(from: Int, to: Int, limit: Int) async -> [CachedSleepSession]
    func goalVO2Inputs(days: Int) async -> (manual: (day: String, value: Double)?, appleHealth: [(day: String, value: Double)])
    func goalBodyMetrics(days: Int) async -> BodyMetrics
}

@MainActor
enum GoalLevelReader {
    static func read(reader: any GoalLevelReading, metrics: Set<LongTermMetric>, now: Date)
        async -> [LongTermMetric: [GoalMilestones.Sample]] {
        var out: [LongTermMetric: [GoalMilestones.Sample]] = [:]
        func samples(_ rows: [(day: String, value: Double)]) -> [GoalMilestones.Sample] {
            rows.compactMap { row in GoalMeasurements.parseDay(row.day).map { GoalMilestones.Sample(date: $0, value: row.value) } }
        }
        if metrics.contains(.restingHr) {
            out[.restingHr] = samples(await reader.goalDays().compactMap { day in
                day.restingHr.flatMap { $0 > 0 ? (day.day, Double($0)) : nil }
            })
        }
        if metrics.contains(.sleepHeartRate) {
            out[.sleepHeartRate] = samples(await reader.goalLevelValues(key: "rhr_primary_session",
                                                                     source: MetricResolver.whoopSource, days: 400))
        }
        if metrics.contains(.sleepConsistency) {
            // The nightly score AgeLess averages, from the same computed sleep sessions and the same function.
            let to = Int(now.timeIntervalSince1970) + 86_400, from = to - 70 * 86_400
            let offset = TimeZone.current.secondsFromGMT(for: now)
            let sessions = await reader.goalComputedSleepSessions(from: from - 5 * 86_400, to: to, limit: 1_000)
                .map { SleepTimingConsistency.Interval(start: $0.effectiveStartTs, end: $0.endTs) }
            let scores = SleepTimingConsistency.scoresByDay(sessions: sessions, from: from, to: to) {
                AnalyticsEngine.dayString($0, offsetSec: offset)
            }
            out[.sleepConsistency] = samples(scores.map { (day: $0.key, value: $0.value) }.sorted { $0.day < $1.day })
        }
        if metrics.contains(.vo2max) {
            let vo2 = await reader.goalVO2Inputs(days: 400)
            out[.vo2max] = samples(HealthspanVO2.goalReadings(manual: vo2.manual, appleHealth: vo2.appleHealth,
                                                              today: StoreReader.localDayKey(now)))
        }
        let bodyKeys: [(LongTermMetric, String)] = [(.bodyFat, "body_fat"), (.leanMass, "lean_mass"), (.waist, "waist")]
        if bodyKeys.contains(where: { metrics.contains($0.0) }) {
            let body = await reader.goalBodyMetrics(days: 400)
            for (metric, key) in bodyKeys where metrics.contains(metric) {
                out[metric] = samples(body.series(key).map { ($0.day, $0.value) })
            }
        }
        return out
    }
}

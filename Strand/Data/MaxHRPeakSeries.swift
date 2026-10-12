import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MaxHRPeakSeries.swift — fork: banks each day's highest HELD workout heart rate (`MaxHRSuggestion.heldPeak`)
// while the band's raw trace exists, so the Settings suggestion of a measured maximum can look back six
// months although raw heart rate is kept for about five. Only adds a value per day; reads nothing back into
// any score.

extension IntelligenceEngine {

    static let heldPeakKey = "hr_peak_held_30s"

    /// Banks the held peak of every day in `[oldestDay, newestDay]` that has a workout with a band trace; on
    /// the first run (no banked day yet) back over the whole raw retention. A failed read banks nothing.
    nonisolated static func bankHeldPeaks(store: WhoopStore, strapId: String, computedId: String,
                                          oldestDay: String, newestDay: String, tzOffset: Int) async {
        do {
            let banked = try await store.metricSeries(deviceId: computedId, key: heldPeakKey,
                                                      from: HealthspanWindow.dayKey(newestDay, plus: -400),
                                                      to: newestDay)
            let from = banked.isEmpty
                ? min(oldestDay, HealthspanWindow.dayKey(newestDay, plus: -(HealthspanWindow.rawRetentionDays - 1)))
                : oldestDay
            guard let fromTs = midnightForDayKey(from, offsetSec: tzOffset),
                  let toTs = midnightForDayKey(newestDay, offsetSec: tzOffset).map({ $0 + 86_400 }) else { return }
            var byDay: [String: Int] = [:]
            for source in Set([strapId, computedId, Repository.appleHealthSource]) {
                for row in try await store.workouts(deviceId: source, from: fromTs, to: toTs, limit: 100_000) {
                    let trace = try await store.hrSamples(deviceId: strapId, from: row.startTs, to: row.endTs - 1,
                                                          limit: Int.max)
                    guard let peak = MaxHRSuggestion.heldPeak(trace) else { continue }
                    let day = AnalyticsEngine.dayString(row.startTs, offsetSec: tzOffset)
                    byDay[day] = max(byDay[day] ?? 0, peak)
                }
            }
            let points = byDay.map { MetricPoint(day: $0.key, key: heldPeakKey, value: Double($0.value)) }
            if !points.isEmpty { _ = try await store.upsertMetricSeries(points, deviceId: computedId) }
        } catch {
            // Nothing banked; the next pass tries again.
        }
    }
}

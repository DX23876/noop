import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MaxHRPeakSeries.swift — fork: banks each day's highest workout heart rate held for five consecutive samples
// (`StrainScorer.sustainedPeak`) while the band's raw trace exists. `MaxHeartRate.measuredLevels` reads the
// series to find the level a wearer reached on two days (#2438 step 0), so the maximum heart rate follows what
// the band measured instead of staying on the age formula.

extension DailyAnalysis {

    /// One value per day: the highest sustained peak of that day's workouts, raw (the plausibility bound
    /// is the resolver's, so a changed age re-reads the same series).
    public static let workoutPeakKey = "hr_peak_workout_5s"

    /// Banks the workout peak of every day in `[oldestDay, newestDay]` that has a workout with a band trace;
    /// on the first run (no banked day yet) back over the whole raw retention. A failed read banks nothing.
    public nonisolated static func bankWorkoutPeaks(store: WhoopStore, strapId: String, computedId: String,
                                                    oldestDay: String, newestDay: String, tzOffset: Int) async {
        do {
            let banked = try await store.metricSeries(deviceId: computedId, key: workoutPeakKey,
                                                      from: HealthspanWindow.dayKey(newestDay, plus: -400),
                                                      to: newestDay)
            let from = banked.isEmpty
                ? min(oldestDay, HealthspanWindow.dayKey(newestDay, plus: -(HealthspanWindow.rawRetentionDays - 1)))
                : oldestDay
            try await bankWorkoutPeaks(store: store, strapId: strapId, computedId: computedId,
                                       fromDay: from, toDay: newestDay, tzOffset: tzOffset)
        } catch {
            // Nothing banked; the next pass tries again.
        }
    }

    /// Banks the workout peak of every day in `[fromDay, toDay]`. Workouts of every source count (the strap's,
    /// NOOP's detected and recorded ones, Apple Health's), each measured on the band's own trace, so an
    /// imported workout's stored single-sample peak is never read.
    public nonisolated static func bankWorkoutPeaks(store: WhoopStore, strapId: String, computedId: String,
                                                    fromDay: String, toDay: String, tzOffset: Int) async throws {
        guard let fromTs = midnightForDayKey(fromDay, offsetSec: tzOffset),
              let toTs = midnightForDayKey(toDay, offsetSec: tzOffset).map({ $0 + 86_400 }) else { return }
        var byDay: [String: Double] = [:]
        for source in Set([strapId, computedId, MetricResolver.appleHealthSource]) {
            for row in try await store.workouts(deviceId: source, from: fromTs, to: toTs, limit: 100_000) {
                try Task.checkCancellation()
                let trace = try await store.hrSamples(deviceId: strapId, from: row.startTs, to: row.endTs - 1,
                                                      limit: Int.max)
                guard let peak = StrainScorer.sustainedPeak(trace) else { continue }
                let day = AnalyticsEngine.dayString(row.startTs, offsetSec: tzOffset)
                byDay[day] = max(byDay[day] ?? 0, peak)
            }
        }
        let points = byDay.map { MetricPoint(day: $0.key, key: workoutPeakKey, value: $0.value) }
        if !points.isEmpty { _ = try await store.upsertMetricSeries(points, deviceId: computedId) }
    }
}

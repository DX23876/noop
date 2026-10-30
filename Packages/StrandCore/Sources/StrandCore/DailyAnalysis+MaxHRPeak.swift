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
    func bankWorkoutPeaks(store: WhoopStore, strapId: String, computedId: String,
                          oldestDay: String, newestDay: String, tzOffset: Int) async {
        do {
            let banked = try await store.metricSeries(deviceId: computedId, key: Self.workoutPeakKey,
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

    /// Banks the workout peak of every day in `[fromDay, toDay]` from the workouts Effort reads
    /// (`AnalysisDataServices.rawWorkoutRows`).
    func bankWorkoutPeaks(store: WhoopStore, strapId: String, computedId: String,
                          fromDay: String, toDay: String, tzOffset: Int) async throws {
        guard let fromTs = Self.midnightForDayKey(fromDay, offsetSec: tzOffset),
              let toTs = Self.midnightForDayKey(toDay, offsetSec: tzOffset).map({ $0 + 86_400 }) else { return }
        let workouts = await repo.rawWorkoutRows(from: fromTs, to: toTs)
        try await Self.bankWorkoutPeaks(store: store, workouts: workouts, strapId: strapId, computedId: computedId,
                                        fromDay: fromDay, toDay: toDay, tzOffset: tzOffset)
    }

    /// Banks the workout peak of every day in `[fromDay, toDay]` from `workouts`. Workouts of every source count
    /// (the strap's, NOOP's detected and recorded ones, Apple Health's, imported sessions), each measured on the
    /// band trace of the strap that owns its day (`resolveDayOwner`), so an imported workout's stored
    /// single-sample peak is never read and a day worn on a retired strap banks that strap's peak. Reading only
    /// the current id left every day of a replaced strap without a peak.
    public nonisolated static func bankWorkoutPeaks(store: WhoopStore, workouts: [WorkoutRow], strapId: String,
                                                    computedId: String, fromDay: String, toDay: String,
                                                    tzOffset: Int) async throws {
        guard let fromTs = midnightForDayKey(fromDay, offsetSec: tzOffset),
              let toTs = midnightForDayKey(toDay, offsetSec: tzOffset).map({ $0 + 86_400 }) else { return }
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let devices = (try? registry.all()) ?? []
        let activeId = (try? registry.activeDeviceId()) ?? strapId
        var ownerByDay: [String: String] = [:]
        var byDay: [String: Double] = [:]
        for row in workouts where row.startTs >= fromTs && row.startTs < toTs && row.endTs > row.startTs {
            try Task.checkCancellation()
            let day = AnalyticsEngine.dayString(row.startTs, offsetSec: tzOffset)
            let owner: String
            if let known = ownerByDay[day] {
                owner = known
            } else {
                let dayStart = midnightForDayKey(day, offsetSec: tzOffset) ?? row.startTs
                owner = await resolveDayOwner(day: day, from: dayStart, to: dayStart + 86_400 - 1, store: store,
                                              devices: devices, activeId: activeId, registry: registry,
                                              fallbackDeviceId: strapId)
                ownerByDay[day] = owner
            }
            let trace = try await store.hrSamples(deviceId: owner, from: row.startTs, to: row.endTs - 1,
                                                  limit: Int.max)
            guard let peak = StrainScorer.sustainedPeak(trace) else { continue }
            byDay[day] = max(byDay[day] ?? 0, peak)
        }
        let points = byDay.map { MetricPoint(day: $0.key, key: workoutPeakKey, value: $0.value) }
        if !points.isEmpty { _ = try await store.upsertMetricSeries(points, deviceId: computedId) }
    }
}

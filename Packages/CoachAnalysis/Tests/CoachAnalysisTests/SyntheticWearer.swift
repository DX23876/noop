import Foundation
@testable import CoachAnalysis

/// A deterministic synthetic wearer for the executor tests: autocorrelated nightly and daily series,
/// workouts at known times, and effects injected at known sizes, so a test can ask whether an analysis
/// recovers what was put in — at several sizes, not one.
struct SyntheticWearer {
    var today = "2026-09-23"
    var days = 365
    var seed: UInt64 = 1

    /// Nightly sleep efficiency (%), keyed by wake day: AR(1) around 88 with SD ≈ 3.
    var efficiencyMean = 88.0
    /// Efficiency points lost in the night AFTER an evening workout (start ≥ 18:00).
    var eveningEffect = 0.0
    /// Probability of a workout on a day, and of that workout being in the evening.
    var workoutRate = 0.45
    var eveningShare = 0.4
    /// Strain of an evening workout day is higher by this much (a built-in confounder).
    var eveningStrainBoost = 0.0
    /// Daily HRV follows the previous day's strain: hrv(D + 1) += lagCoupling × strain(D).
    var lagCoupling = 0.0
    /// HRV drift in ms per 30 days.
    var hrvTrendPer30 = 0.0
    /// Share of days answered for the "alcohol" journal tag, and the efficiency cost of a yes night.
    var alcoholAnswerRate = 0.8
    var alcoholEffect = 0.0

    func make() -> AnalysisDataset {
        var rng = SplitMix64(seed: seed)
        func uniform() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }
        func normal() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }

        let last = DayKey.ordinal(today)!
        let first = last - days + 1
        var events: [AnalysisEvent] = []
        var strain: [Int: Double] = [:]
        var efficiency: [String: Double] = [:]
        var hrv: [String: Double] = [:]
        var strainValues: [String: Double] = [:]
        var alcoholAnswered = Set<String>(), alcoholYes = Set<String>()
        var eveningDays = Set<Int>(), alcoholDays = Set<Int>()

        for day in first...last {
            var dayStrain = 8 + 2 * normal()
            if uniform() < workoutRate {
                let evening = uniform() < eveningShare
                let hour = evening ? 18 + 3 * uniform() : 6 + 5 * uniform()
                events.append(AnalysisEvent(kind: "workout", day: DayKey.string(day), startHour: hour,
                                            durationMin: 45, category: uniform() < 0.5 ? "running" : "strength",
                                            intensity: 12))
                dayStrain += 4
                if evening { eveningDays.insert(day); dayStrain += eveningStrainBoost }
            }
            strain[day] = dayStrain
            strainValues[DayKey.string(day)] = dayStrain
            if uniform() < alcoholAnswerRate {
                alcoholAnswered.insert(DayKey.string(day))
                if uniform() < 0.25 { alcoholYes.insert(DayKey.string(day)); alcoholDays.insert(day) }
            }
        }

        var previousNoise = 0.0
        var previousHrvNoise = 0.0
        for day in first...last {
            // The night keyed `day` started on the evening of `day - 1`.
            previousNoise = 0.5 * previousNoise + 3 * 0.866 * normal()
            var e = efficiencyMean + previousNoise
            if eveningDays.contains(day - 1) { e -= eveningEffect }
            if alcoholDays.contains(day - 1) { e -= alcoholEffect }
            efficiency[DayKey.string(day)] = e

            previousHrvNoise = 0.5 * previousHrvNoise + 4 * 0.866 * normal()
            var h = 55 + previousHrvNoise + hrvTrendPer30 * Double(day - first) / 30
            if let s = strain[day - 1] { h += lagCoupling * (s - 10) }
            hrv[DayKey.string(day)] = h
        }

        return AnalysisDataset(
            today: today,
            series: [
                DailySeries(key: "sleep_efficiency", kind: .nightly, unit: "%", values: efficiency),
                DailySeries(key: "hrv", kind: .daily, unit: "ms", values: hrv),
                DailySeries(key: "strain", kind: .daily, values: strainValues),
            ],
            events: events,
            tags: [DayTag(key: "alcohol", answered: alcoholAnswered, yes: alcoholYes)],
            confounderKeys: ["strain", "alcohol"])
    }
}

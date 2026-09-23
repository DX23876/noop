import Foundation
import CoachAnalysis

/// The effects injected into one synthetic wearer. Every size varies across the cohort — including zero —
/// so the evaluation shows the Coach tracking the input, not matching one value.
public struct InjectedEffects: Equatable, Codable, Sendable {
    /// Sleep-efficiency points lost the night after a workout starting at 18:00 or later.
    public var eveningWorkoutEfficiency: Double
    /// HRV (ms) change the night after a day with alcohol.
    public var alcoholHrv: Double
    /// Resting-HR drift, bpm per 30 days.
    public var restingHrTrendPer30: Double
    /// HRV (ms) change the night after, per strain point above 10.
    public var strainHrvCoupling: Double
    /// Extra sleep minutes on the nights after Friday and Saturday.
    public var weekendSleepMin: Double
}

/// One synthetic wearer: the dataset the tool sees, and the raw values the reference reads.
public struct SyntheticWearer: Sendable {
    public let id: Int
    public let effects: InjectedEffects
    public let dataset: AnalysisDataset
}

/// A deterministic cohort of synthetic wearers. Values are rounded the way the app stores them (HRV and
/// efficiency to 0.1, resting HR, sleep minutes and steps to whole numbers), with realistic gaps: nights
/// the strap was off drop every nightly metric at once.
public enum SyntheticCohort {

    public static let today = "2026-09-23"
    public static let days = 400

    /// Effect sizes cycle independently across wearers, so each wearer carries a different combination.
    static func effects(for index: Int) -> InjectedEffects {
        InjectedEffects(
            eveningWorkoutEfficiency: [0, 2, 5][index % 3],
            alcoholHrv: [0, -4, -9][(index / 3) % 3],
            restingHrTrendPer30: [0, 0.6, -0.5][(index + 1) % 3],
            strainHrvCoupling: [0, -0.8, -1.6][(index + 2) % 3],
            weekendSleepMin: [0, 25, 45][(index / 2) % 3])
    }

    public static func make(count: Int = 9) -> [SyntheticWearer] {
        (0..<count).map { make(index: $0) }
    }

    public static func make(index: Int) -> SyntheticWearer {
        let effects = effects(for: index)
        var rng = Rng(seed: 0xC0AC_E7A1 &+ UInt64(index) &* 0x9E37_79B9)
        let last = DayKey.ordinal(today)!
        let first = last - days + 1

        var events: [AnalysisEvent] = []
        var strain: [Int: Double] = [:], steps: [Int: Double] = [:]
        var eveningDays = Set<Int>()
        var alcoholAnswered = Set<String>(), alcoholYes = Set<String>(), alcoholDays = Set<Int>()
        var caffeineAnswered = Set<String>(), caffeineYes = Set<String>()
        let categories = ["running", "strength", "cycling"]

        for day in first...last {
            let key = DayKey.string(day)
            let weekday = DayKey.isoWeekday(day)
            var dayStrain = 7 + 1.5 * rng.normal()
            var daySteps = 8_000 + 2_500 * rng.normal()
            if rng.uniform() < 0.5 {
                let evening = rng.uniform() < 0.4
                let hour = evening ? 18 + 3.5 * rng.uniform() : 6 + 5 * rng.uniform()
                let duration = 30 + 60 * rng.uniform()
                let category = categories[Int(rng.uniform() * 3) % 3]
                events.append(AnalysisEvent(kind: "workout", day: key, startHour: (hour * 100).rounded() / 100,
                                            durationMin: duration.rounded(), category: category,
                                            intensity: (8 + 8 * rng.uniform()).rounded()))
                dayStrain += 5 + duration / 30
                if category == "running" { daySteps += 3_000 }
                if evening { eveningDays.insert(day) }
            }
            if rng.uniform() > 0.03 { strain[day] = round1(dayStrain) }
            if rng.uniform() > 0.03 { steps[day] = max(500, daySteps).rounded() }
            if rng.uniform() < 0.85 {
                alcoholAnswered.insert(key)
                if rng.uniform() < (weekday == 5 || weekday == 6 ? 0.45 : 0.15) {
                    alcoholYes.insert(key)
                    alcoholDays.insert(day)
                }
            }
            if rng.uniform() < 0.85 {
                caffeineAnswered.insert(key)
                if rng.uniform() < 0.3 { caffeineYes.insert(key) }
            }
        }

        var hrv: [String: Double] = [:], rhr: [String: Double] = [:]
        var efficiency: [String: Double] = [:], sleepMin: [String: Double] = [:]
        var noise = (hrv: 0.0, rhr: 0.0, eff: 0.0, min: 0.0)
        for night in first...last {
            // The night keyed `night` started on the evening of `night - 1`.
            noise.hrv = 0.5 * noise.hrv + 6 * 0.866 * rng.normal()
            noise.rhr = 0.5 * noise.rhr + 2 * 0.866 * rng.normal()
            noise.eff = 0.5 * noise.eff + 3 * 0.866 * rng.normal()
            noise.min = 0.5 * noise.min + 30 * 0.866 * rng.normal()
            guard rng.uniform() > 0.04 else { continue }   // strap off that night
            let eve = night - 1
            let key = DayKey.string(night)
            let alcohol = alcoholDays.contains(eve)
            let weekendNight = [5, 6].contains(DayKey.isoWeekday(eve))
            var h = 55 + noise.hrv + (alcohol ? effects.alcoholHrv : 0)
            if let s = strain[eve] { h += effects.strainHrvCoupling * (s - 10) }
            hrv[key] = round1(max(15, h))
            rhr[key] = (56 + noise.rhr + effects.restingHrTrendPer30 * Double(night - first) / 30).rounded()
            var e = 88 + noise.eff - (eveningDays.contains(eve) ? effects.eveningWorkoutEfficiency : 0)
            if alcohol { e -= 1.5 }
            efficiency[key] = round1(min(99, max(60, e)))
            sleepMin[key] = (420 + noise.min + (weekendNight ? effects.weekendSleepMin : 0)).rounded()
        }

        func keyed(_ map: [Int: Double]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: map.map { (DayKey.string($0.key), $0.value) })
        }
        let dataset = AnalysisDataset(
            today: today,
            series: [
                DailySeries(key: "hrv", kind: .nightly, unit: "ms", values: hrv),
                DailySeries(key: "resting_hr", kind: .nightly, unit: "bpm", values: rhr),
                DailySeries(key: "sleep_efficiency", kind: .nightly, unit: "%", values: efficiency),
                DailySeries(key: "sleep_total_min", kind: .nightly, unit: "min", values: sleepMin),
                DailySeries(key: "strain", kind: .daily, values: keyed(strain)),
                DailySeries(key: "steps", kind: .daily, unit: "steps", values: keyed(steps)),
            ],
            events: events,
            tags: [
                DayTag(key: "alcohol", answered: alcoholAnswered, yes: alcoholYes),
                DayTag(key: "late_caffeine", answered: caffeineAnswered, yes: caffeineYes),
            ],
            confounderKeys: ["strain", "alcohol", "sleep_total_min"])
        return SyntheticWearer(id: index, effects: effects, dataset: dataset)
    }

    private static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// SplitMix64 with a Box–Muller normal; deterministic across platforms and runs.
struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

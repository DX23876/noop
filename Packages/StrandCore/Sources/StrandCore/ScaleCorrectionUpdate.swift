import Foundation
import StrandAnalytics
import WhoopStore

/// The scale's look at the strap, run when an energy page or the Food page loads (owner decisions 2026-11-27,
/// Q10, Q20 to Q23, Q31, Q33), the same on both platforms: the one scale estimate (`ScaleBurn`) from the days
/// marked as completely logged and the weigh-ins without a water mark, against the strap's burn on the same days
/// before any correction, evaluated into the stored `BurnCorrection`.
public enum ScaleCorrectionUpdate {
    /// What the energy page shows about the scale.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var status: String
        public var factor: Double
        public var targetFactor: Double?
        public var sinceDay: String?
        public var scaleKcal: Double?
        public var strapKcal: Double?
        public var completeDays: Int
        public var weeks: Int
        public var weighIns: Int
        public var spanDays: Int
        public var tooUncertain: Bool
        public var holding: Bool
        public var appliesToBasal: Bool
        /// Before a figure can be offered: the early look's scale over strap (`ScaleBurn.Gates.early`), shown as a
        /// direction only, never proposed or applied. Nil until three weeks hold enough.
        public var earlyRatio: Double? = nil
    }

    /// Days a change in eating or training holds the correction still (Q23).
    public static let holdDays = 21
    /// Days "creatine started" holds it.
    public static let creatineHoldDays = 28

    /// Whether a known disturbance is still settling on `today`: a plan started or its form changed, the burn
    /// model moved under it, strength training resumed after four weeks without, or a weigh-in marked
    /// "creatine started" (`BodyWeightRow.WaterMark.creatineStarted`).
    public static func holding(today: String, plan: DietPlan?, strengthDays: [String],
                               creatineStarts: [String], calendar: Calendar = .current) -> Bool {
        func daysSince(_ day: String?) -> Int? {
            guard let day, let a = WeightSeries.date(forDay: day), let b = WeightSeries.date(forDay: today) else { return nil }
            return calendar.dateComponents([.day], from: a, to: b).day
        }
        for day in [plan?.startDay, plan?.formChangedDay, plan?.burnModelChangedDay] {
            if let d = daysSince(day), (0..<holdDays).contains(d) { return true }
        }
        for day in creatineStarts {
            if let d = daysSince(day), (0..<creatineHoldDays).contains(d) { return true }
        }
        // Strength training back after at least four weeks without: the muscles hold water for a while.
        let sorted = Array(Set(strengthDays)).sorted()
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            guard let gap = daysSince(previous).flatMap({ p in daysSince(next).map { p - $0 } }), gap >= 28,
                  let since = daysSince(next), (0..<holdDays).contains(since) else { continue }
            return true
        }
        return false
    }

    /// Reads the scale and returns the evaluated state to store and what to show. `strapByDay` holds the strap's
    /// burn per day BEFORE any scale correction, so the correction never feeds on itself; `basalShare` is basal's
    /// share of the strap's day when a measured resting rate is in force (the correction then leaves it alone).
    public static func run(store: WhoopStore, reader: StoreReader, state: BurnCorrection, plan: DietPlan?,
                           strapByDay: [String: Double], kcalPerKg: Double, basalShare: Double?,
                           strengthDays: [String], today: String) async -> (state: BurnCorrection, snapshot: Snapshot) {
        let from = WeightSeries.date(forDay: today)
            .flatMap { Calendar.current.date(byAdding: .day, value: -ScaleBurn.windowDays, to: $0) }
            .map(StoreReader.localDayKey) ?? today
        let complete = (try? await store.foodCompleteDays(from: from, to: today)) ?? []
        let intake = await NutritionReads.nutritionByDay(store: store, from: from, to: today).compactMapValues(\.calories)
        let completeIntake = intake.filter { complete.contains($0.key) }
        // A day with a water-marked weigh-in is left out of the trend; "creatine started" also holds the correction.
        let series = await WeightSeries.series(reader: reader, from: from, to: today)
        let entries = (try? await store.bodyWeights(deviceId: WhoopStore.noopWeightSourceId, from: from, to: today)) ?? []
        let marked = Set(entries.filter { $0.waterMark != nil }.map(\.day))
        let creatine = entries.filter { $0.waterMark == .creatineStarted }.map(\.day)
        let weighIns = series.filter { !marked.contains($0.day) }.map { (day: $0.day, kg: $0.value) }
        let outcome = ScaleBurn.estimate(completeIntake: completeIntake, weighIns: weighIns, strapByDay: strapByDay,
                                         today: today, kcalPerKg: kcalPerKg)
        let hold = holding(today: today, plan: plan, strengthDays: strengthDays, creatineStarts: creatine)
        var target: Double?
        var snapshot = Snapshot(status: state.status.rawValue, factor: state.factor, targetFactor: state.targetFactor,
                                sinceDay: state.sinceDay, scaleKcal: nil, strapKcal: nil, completeDays: 0, weeks: 0,
                                weighIns: 0, spanDays: 0, tooUncertain: false, holding: hold,
                                appliesToBasal: state.appliesToBasal)
        switch outcome {
        case .estimate(let e):
            target = e.ratio.map { BurnCorrection.target(ratio: $0, basalShare: basalShare) }
            snapshot.scaleKcal = e.burnKcal
            snapshot.strapKcal = e.strapKcal
            snapshot.completeDays = e.completeDays
            snapshot.weighIns = e.weighIns
        case .missing(let days, let weeks, let weighs, let span, let uncertain):
            snapshot.completeDays = days
            snapshot.weeks = weeks
            snapshot.weighIns = weighs
            snapshot.spanDays = span
            snapshot.tooUncertain = uncertain
            if case .estimate(let early) = ScaleBurn.estimate(completeIntake: completeIntake, weighIns: weighIns,
                                                              strapByDay: strapByDay, today: today,
                                                              kcalPerKg: kcalPerKg, gates: .early) {
                snapshot.earlyRatio = early.ratio
            }
        }
        let next = state.evaluated(target: target, today: today, holding: hold, measured: basalShare != nil)
        snapshot.status = next.status.rawValue
        snapshot.factor = next.factor
        snapshot.targetFactor = next.targetFactor
        snapshot.sinceDay = next.sinceDay
        snapshot.appliesToBasal = next.appliesToBasal
        return (next, snapshot)
    }
}

/// What a kilogram is worth for this body today (`EnergyDensity`), from the body fat in force: a measurement,
/// else the tape method, else CUN-BAE (Q24, Q28). The one figure the plan's deficit, its forecast, the weight
/// page and the scale all read (Q25).
public enum EnergyDensityResolver {
    /// Readings older than this no longer stand for the body.
    public static let maximumAgeDays = 365

    public static func kcalPerKg(profile: UserProfile, metrics: BodyMetrics, today: String) -> Double {
        let reading = metrics.asOf("body_fat", day: today, maximumAgeDays: maximumAgeDays)
        let tape = reading.flatMap { $0.source == "navy" ? $0.value : nil }
        let measured = reading.flatMap { $0.source == "navy" ? nil : $0.value }
        let weight = metrics.asOf("weight", day: today)?.value ?? profile.weightKg
        let height = metrics.asOf("height", day: today)?.value ?? profile.heightCm
        let female: Bool? = profile.sex.lowercased() == "female" ? true : profile.sex.lowercased() == "male" ? false : nil
        guard let bodyFat = BodyFatEstimate.resolve(measured: measured, tape: tape, weightKg: weight, heightCm: height,
                                                    age: profile.age, female: female),
              let density = EnergyDensity.kcalPerKg(weightKg: weight, bodyFatPercent: bodyFat) else {
            return DietTargets.defaultKcalPerKg
        }
        return density
    }
}

extension ScaleCorrectionUpdate {
    /// The days of the window with a strength session, from the workouts the app lists.
    public static func strengthDays(_ workouts: [WorkoutRow]) -> [String] {
        workouts.filter { EnergyWorkoutKind.forSport($0.sport) == .resistance }
            .map { StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) }
    }

    /// Basal's share of the strap's days, when a measured resting rate is in force (the correction then leaves
    /// basal alone); nil otherwise.
    public static func basalShare(_ summaries: [DailyEnergySummary], measured: Bool) -> Double? {
        guard measured else { return nil }
        let days = summaries.filter { $0.source == .strapWornTime }
        let basal = days.compactMap(\.basalBurnedSoFar).reduce(0, +)
        let total = days.compactMap { $0.totalBeforeScaleKcal ?? $0.totalBurnedSoFar }.reduce(0, +)
        return total > 0 ? basal / total : nil
    }

    /// The strap's burn per finished day before any scale correction.
    public static func strapByDay(_ summaries: [DailyEnergySummary], today: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for s in summaries where s.day < today && s.source == .strapWornTime {
            if let total = s.totalBeforeScaleKcal ?? s.totalBurnedSoFar { out[s.day] = total }
        }
        return out
    }
}

import Foundation
import StrandAnalytics
import WhoopStore

/// The common daily-energy read model. Inputs retain their recording sources; source selection,
/// historical body mass, coverage and logged-workout pricing follow one path on every platform.
public enum EnergySummaryPreparation {
    public struct Inputs {
        public var appleByDay: [String: AppleDaily]
        public var strapByDay: [String: DailyMetric]
        public var derivedByDay: [String: WhoopDailyEnergyRow]
        public var strapActiveByDay: [String: Double]
        public var stepHoursByDay: [String: [Int]]
        public var sessionsByDay: [String: [WorkoutRow]]
        public var weightObservations: [CausalWeightObservation]
        public var calibrationStatus: EnergyCalibrationStatus
        public var calibrationFactor: Double?
        public var shape: ActivityShape?
        public var adaptivePrior: Double?
        public var appleCoverageByDay: [String: Int]
        public var stride: StepLengthTimeline

        public init(appleByDay: [String: AppleDaily], strapByDay: [String: DailyMetric],
                    derivedByDay: [String: WhoopDailyEnergyRow], strapActiveByDay: [String: Double],
                    stepHoursByDay: [String: [Int]], sessionsByDay: [String: [WorkoutRow]],
                    weightObservations: [CausalWeightObservation], calibrationStatus: EnergyCalibrationStatus,
                    calibrationFactor: Double?, shape: ActivityShape?, adaptivePrior: Double?,
                    appleCoverageByDay: [String: Int], stride: StepLengthTimeline) {
            self.appleByDay = appleByDay; self.strapByDay = strapByDay; self.derivedByDay = derivedByDay
            self.strapActiveByDay = strapActiveByDay; self.stepHoursByDay = stepHoursByDay
            self.sessionsByDay = sessionsByDay; self.weightObservations = weightObservations
            self.calibrationStatus = calibrationStatus; self.calibrationFactor = calibrationFactor
            self.shape = shape; self.adaptivePrior = adaptivePrior; self.appleCoverageByDay = appleCoverageByDay
            self.stride = stride
        }
    }

    public static func summaries(_ source: Inputs, profile: UserProfile, hrMax: Double?, now: Date,
                                 calendar: Calendar = .current, bodyFatOn: (String) -> Double?) -> [DailyEnergySummary] {
        let todayKey = StoreReader.localDayKey(now)
        let appleByDay = source.appleByDay, strapByDay = source.strapByDay, derivedByDay = source.derivedByDay
        let strapActiveByDay = source.strapActiveByDay, stepHoursByDay = source.stepHoursByDay
        let sessionsByDay = source.sessionsByDay, weightObservations = source.weightObservations
        let calibrationFactor = source.calibrationFactor, shape = source.shape, adaptivePrior = source.adaptivePrior
        let appleCoverageByDay = source.appleCoverageByDay
        let appleReference = (stride: source.stride, coverage: source.appleCoverageByDay)
        // TODAY is always included, even with no inputs at all. Without this the engine's
        // `.profileOnly` branch is unreachable in practice: a day with no Apple row and no strap row
        // produced no summary, so the card that exists to say "nothing recorded yet, here is your
        // estimated basal rate" simply never appeared. Past days stay data-driven — an empty card for
        // every unworn day last month would be noise, not honesty.
        let allDays = Set(appleByDay.keys).union(strapByDay.keys)
            .union(derivedByDay.keys).union([todayKey]).sorted()
        return allDays.map { day in
            let apple = appleByDay[day]
            let strap = strapByDay[day]
            let derived = derivedByDay[day]
            // A total and its coverage denominator MUST come from the same model. These two lines used
            // to disagree — the total preferred `derived`, the denominator preferred `strap` — so on
            // any day both existed the engine divided one model's kcal by the other's seconds. Where
            // the legacy denominator is the larger (low-confidence PPG stretches are dropped from the
            // bucket model but counted by `energyCoverageSeconds`), the basal top-up it implies is too
            // big and `max(0, total - basal)` silently eats the day's active energy.
            let legacyEnergy = day == todayKey
                ? nil
                : strap?.activeKcalEst.map { ($0, strap?.energyCoverageSeconds) }
            let strapEnergy: (kcal: Double, seconds: Int?)? = derived.map {
                ($0.rawTotalKcal, $0.representedSeconds)
            } ?? legacyEnergy
            var dayProfile = profile
            if let date = WeightSeries.date(forDay: day),
               let historicalWeight = CausalWeightResolver.weight(
                   at: Int(date.timeIntervalSince1970 + 43_200), observations: weightObservations,
                   calendar: calendar) {
                dayProfile.weightKg = historicalWeight
            }
            dayProfile.bodyFatPercent = bodyFatOn(day)
            // Priced with THIS day's body mass and resting heart rate: both belong to the day rather
            // than to today, the same reason the weight above is resolved causally. The engine reads
            // them only on a day nothing measured, so the decision stays in one place.
            let sessions = (sessionsByDay[day] ?? []).compactMap {
                activityContribution($0, profile: dayProfile, hrMax: hrMax,
                                          restingHR: strap?.restingHr.map(Double.init),
                                          peakMET: derivedByDay[day]?.peakMET)
            }
            let inputs = EnergyEngine.DayInputs(
                day: day,
                appleActiveKcal: apple?.activeKcal,
                appleBasalKcal: apple?.basalKcal,
                appleCoverageSeconds: appleCoverageByDay[day],
                strapTotalKcal: strapEnergy?.kcal,
                strapCoverageSeconds: strapEnergy?.seconds,
                // Only for a current-generation day: its hourly rows and its buckets are one pass.
                strapActiveKcal: derived.map { _ in strapActiveByDay[day] ?? 0 },
                strapCalibrationFactor: calibrationFactor,
                strapUncertaintyFraction: derived?.uncertaintyFraction,
                calibrationStatus: source.calibrationStatus,
                // Apple's own step total first (a phone counts all day), else the strap's.
                steps: apple?.steps ?? strap?.steps,
                hoursWithSteps: stepHoursByDay[day]?.count,
                stepHours: stepHoursByDay[day],
                strideM: appleReference.stride.estimate(onDay: day)?.metersPerStep,
                loggedActivity: sessions,
                unresolvedElevatedHRSeconds: derived.map {
                    contextSeconds($0.contextJSON, context: .unresolvedElevatedHR)
                } ?? 0,
                modelWeightSource: derived?.weightSource.rawValue ?? "profile")
            return EnergyEngine.summarize(
                inputs,
                profile: dayProfile,
                context: dayContext(day: day, now: now, calendar: calendar),
                shape: shape,
                adaptivePriorKcal: adaptivePrior)
        }
    }

    /// Only measured or modelled active energy reaches goals; a missing reading stays absent.
    public static func activeValues(_ summaries: [DailyEnergySummary]) -> [String: Double] {
        var result: [String: Double] = [:]
        for summary in summaries {
            if let active = summary.activeBurnedSoFar, active.isFinite, active >= 0 { result[summary.day] = active }
        }
        return result
    }

    public static func activityContribution(_ row: WorkoutRow, profile: UserProfile,
                                                 hrMax: Double?, restingHR: Double?,
                                                 peakMET: Double? = nil)
        -> ActivityContribution? {
        let source = contributionSource(row.source)
        let seconds = max(0, Double(row.endTs - row.startTs))
        func contribution(_ kcal: Double, estimated: Bool) -> ActivityContribution? {
            guard kcal.isFinite, kcal > 0 else { return nil }
            return ActivityContribution(startTs: row.startTs, endTs: row.endTs, kcal: kcal,
                                        source: source, isEstimated: estimated)
        }
        // The precedence itself lives in `WorkoutEnergyEstimate`, which the Workouts screen also
        // reads. Two copies of "recorded, else heart rate, else table" is two places for a day's
        // energy and the same session's own tile to come to different answers.
        return WorkoutEnergyEstimate.resolve(
            recordedKcal: row.energyKcal, sport: row.sport, durationSeconds: seconds,
            averageHR: row.avgHr, profile: profile, hrMax: hrMax, restingHR: restingHR,
            peakMET: peakMET, distanceM: row.distanceM)
            .flatMap { contribution($0.kcal, estimated: $0.isEstimated) }
    }

    public static func contributionSource(_ source: String) -> ActivityContribution.Source {
        switch WorkoutSource.classify(source) {
        case .whoop:        return .whoop
        case .apple:        return .apple
        case .detected:     return .detected
        // A confirmed suggestion is priced as the hand-logged session it now is.
        case .manual, .confirmed: return .manual
        case .lifting:      return .lifting
        case .activityFile: return .activityFile
        case .hevy:         return .hevy
        case .oura:         return .oura
        }
    }

    public static func dayContext(day: String, now: Date = Date(),
                                             calendar: Calendar = .current) -> EnergyEngine.DayContext {
        var parseCalendar = calendar
        parseCalendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let start = parseCalendar.date(from: DateComponents(
                calendar: parseCalendar, timeZone: parseCalendar.timeZone,
                year: parts[0], month: parts[1], day: parts[2])),
              let end = parseCalendar.date(byAdding: .day, value: 1, to: start) else {
            return .completePastDay
        }
        let duration = end.timeIntervalSince(start)
        let isToday = parseCalendar.isDate(now, inSameDayAs: start)
        return EnergyEngine.DayContext(isToday: isToday,
                                       dayDurationSeconds: duration,
                                       elapsedSeconds: isToday ? now.timeIntervalSince(start) : duration,
                                       startTs: Int(start.timeIntervalSince1970))
    }

    private static func contextSeconds(_ raw: String,
                                                         context: EnergyContext) -> Int {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return 0 }
        return max(0, object[context.rawValue] ?? 0)
    }
}

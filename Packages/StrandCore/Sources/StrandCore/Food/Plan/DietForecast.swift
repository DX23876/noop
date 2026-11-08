import Foundation
import WhoopStore

/// Where the plan's weight is heading, as a band rather than a line (decision 2026-11-09).
///
/// A day-by-day energy balance: the burn falls as the body gets lighter (about 25 kcal a day for each kilogram
/// lost, the middle of the 20 to 30 reported in the weight-maintenance literature), so the curve flattens instead
/// of running straight like the 7,700 kcal rule. The band takes the planned difference 20 % weaker and 20 %
/// stronger. On reaching the goal weight the intake moves to the new burn: the maintenance phase is part of the
/// plan from the start. A planned diet break holds a week at maintenance every so many weeks.
public enum DietForecast {
    public struct Week: Equatable, Sendable, Codable {
        public var week: Int
        public var lowKg: Double
        public var midKg: Double
        public var highKg: Double
        /// True from the first week the middle line holds at the goal.
        public var holding: Bool
        /// A planned diet break week.
        public var dietBreak: Bool
    }

    public struct Forecast: Equatable, Sendable, Codable {
        public var weeks: [Week]
        /// Weeks until the goal weight is reached, earliest and latest across the band; nil without a goal or when
        /// it is not reached within the horizon.
        public var goalWeeks: ClosedRange<Int>?
    }

    /// Burn lost per kilogram of body weight lost, per day.
    public static let burnPerKg: Double = 25

    public static func project(startKg: Double, goalKg: Double?, intakeKcal: Double, burnKcal: Double,
                               kcalPerKg: Double = DietTargets.defaultKcalPerKg, dietBreakEveryWeeks: Int? = nil,
                               weeks: Int = 52) -> Forecast {
        func run(_ strength: Double) -> (weights: [Double], holdingFrom: Int?) {
            var w = startKg
            var out = [w]
            var holdingFrom: Int?
            for week in 1...weeks {
                let isBreak = dietBreakEveryWeeks.map { $0 > 0 && week % ($0 + 1) == 0 } ?? false
                for _ in 0..<7 {
                    let burn = burnKcal - (startKg - w) * burnPerKg
                    let reached = goalKg.map { g in intakeKcal < burnKcal ? w <= g : w >= g } ?? false
                    if reached && holdingFrom == nil { holdingFrom = week }
                    let planned = reached || isBreak ? 0 : (intakeKcal - burn) * strength
                    w += planned / kcalPerKg
                }
                out.append(w)
            }
            return (out, holdingFrom)
        }
        let mid = run(1), weak = run(0.8), strong = run(1.2)
        var result: [Week] = []
        for i in 0...weeks {
            let values = [mid.weights[i], weak.weights[i], strong.weights[i]]
            let isBreak = dietBreakEveryWeeks.map { $0 > 0 && i > 0 && i % ($0 + 1) == 0 } ?? false
            result.append(Week(week: i, lowKg: values.min() ?? 0, midKg: mid.weights[i], highKg: values.max() ?? 0,
                               holding: mid.holdingFrom.map { i >= $0 } ?? false, dietBreak: isBreak))
        }
        let reachedWeeks = [mid.holdingFrom, weak.holdingFrom, strong.holdingFrom].compactMap { $0 }
        let goalWeeks: ClosedRange<Int>? = goalKg == nil || reachedWeeks.isEmpty ? nil
            : (reachedWeeks.min()!)...(reachedWeeks.count == 3 ? reachedWeeks.max()! : weeks)
        return Forecast(weeks: result, goalWeeks: goalWeeks)
    }
}

/// Forge's weekly look at the plan (decision 2026-11-09): it compares the pace the plan set with what the smoothed
/// weight trend really did and moves the calories by at most 150 kcal. It holds still, and says why, when the week
/// cannot be trusted: too few logged days, too few weigh-ins, the first two weeks of a plan (water weight), or a
/// week since the last change has not passed.
public enum DietAdjust {
    public enum Hold: String, Sendable, Codable {
        case manualSteering, tooEarly, notAWeekYet, fewLoggedDays, fewWeighIns, onPlan
    }

    public struct Outcome: Equatable, Sendable, Codable {
        /// The change to apply to the plan's adjustment, in kcal a day; zero when holding.
        public var changeKcal: Double
        public var hold: Hold?
        /// The trend's change a week (negative is losing), when it could be measured.
        public var trendKgPerWeek: Double?
        public var plannedKgPerWeek: Double
    }

    public static let maxChangeKcal: Double = 150

    /// `weighIns` are (day, kg) of the last 21 days; `loggedDays` counts days with a food log in the last 7.
    public static func weekly(plan: DietPlan, result: DietTargets.Result, weighIns: [(day: String, kg: Double)],
                              loggedDays: Int, today: String, kcalPerKg: Double = DietTargets.defaultKcalPerKg) -> Outcome {
        let planned = result.paceKgPerWeek
        func hold(_ h: Hold, trend: Double? = nil) -> Outcome {
            Outcome(changeKcal: 0, hold: h, trendKgPerWeek: trend, plannedKgPerWeek: planned)
        }
        guard plan.steering != .manual else { return hold(.manualSteering) }
        guard let todayDate = WeightSeries.date(forDay: today), let start = WeightSeries.date(forDay: plan.startDay),
              todayDate.timeIntervalSince(start) >= 14 * 86_400 else { return hold(.tooEarly) }
        if let last = plan.lastAdjustedDay.flatMap(WeightSeries.date(forDay:)), todayDate.timeIntervalSince(last) < 7 * 86_400 {
            return hold(.notAWeekYet)
        }
        guard loggedDays >= 5 else { return hold(.fewLoggedDays) }
        let lastWeek = weighIns.filter { w in
            WeightSeries.date(forDay: w.day).map { todayDate.timeIntervalSince($0) < 7 * 86_400 } ?? false
        }
        guard lastWeek.count >= 3, weighIns.count >= 5, let trend = slopePerWeek(weighIns) else { return hold(.fewWeighIns) }
        // Positive gap: the body moves less (or the wrong way) than planned in the plan's own direction.
        let gap = trend - planned
        let change = (-gap * kcalPerKg / 7).clamped(-maxChangeKcal, maxChangeKcal)
        guard abs(change) >= 25 else { return hold(.onPlan, trend: trend) }
        return Outcome(changeKcal: (change / 5).rounded() * 5, hold: nil, trendKgPerWeek: trend, plannedKgPerWeek: planned)
    }

    /// Least-squares slope of the weigh-ins, in kilograms a week: the trend, never one reading.
    static func slopePerWeek(_ points: [(day: String, kg: Double)]) -> Double? {
        let xy = points.compactMap { p in WeightSeries.date(forDay: p.day).map { ($0.timeIntervalSince1970 / 86_400, p.kg) } }
        guard xy.count >= 2 else { return nil }
        let mx = xy.map(\.0).reduce(0, +) / Double(xy.count), my = xy.map(\.1).reduce(0, +) / Double(xy.count)
        let sxx = xy.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = xy.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return sxy / sxx * 7
    }
}

/// Three ways of eating suggested in the planner, each with its reason: the one closest to what the wearer already
/// eats (the smallest change lasts longest, and only an app with the wearer's log can tell), then the best fits to
/// their answers.
public enum DietSuggest {
    public enum Reason: String, Sendable, Codable { case closestToYourLog, keepsWhatYouLove, likesRules, strength, easyStart }

    public struct Suggestion: Equatable, Sendable, Codable {
        public var form: DietForm
        public var reason: Reason
    }

    public static func top(entries: [FoodLogEntryLite], keep: [DietPlan.Keep], likesRules: Bool, strength: Bool,
                           mode: DietPlan.Mode) -> [Suggestion] {
        let offered = DietForm.allCases.filter { mode == .advanced || !$0.advancedOnly }
        var out: [Suggestion] = []
        if let split = loggedSplit(entries) {
            let closest = offered.filter { $0.fasting == nil && !blocked($0, keep) }
                .min { distance(split, $0.typicalSplit) < distance(split, $1.typicalSplit) }
            if let closest { out.append(.init(form: closest, reason: .closestToYourLog)) }
        }
        func add(_ form: DietForm, _ reason: Reason) {
            guard offered.contains(form), !blocked(form, keep), !out.contains(where: { $0.form == form }), out.count < 3 else { return }
            out.append(.init(form: form, reason: reason))
        }
        if strength { add(.highProtein, .strength) }
        if likesRules { add(mode == .advanced ? .fasting52 : .fasting168, .likesRules); add(.lowCarb, .likesRules) }
        if keep.contains(.breadAndPasta) { add(.mediterranean, .keepsWhatYouLove) }
        if keep.contains(.meat) { add(.highProtein, .keepsWhatYouLove) }
        add(.mediterranean, .easyStart)
        add(.balanced, .easyStart)
        add(.flexitarian, .easyStart)
        return out
    }

    static func blocked(_ form: DietForm, _ keep: [DietPlan.Keep]) -> Bool {
        if keep.contains(.breadAndPasta), form == .lowCarb || form == .keto { return true }
        if keep.contains(.sweets), form == .keto { return true }
        if keep.contains(.lateEating), form.fasting != nil || form == .fasting168 { return true }
        if keep.contains(.regularMeals), form.fasting != nil { return true }
        return false
    }

    static func loggedSplit(_ entries: [FoodLogEntryLite]) -> (protein: Double, carbs: Double, fat: Double)? {
        let p = entries.reduce(0) { $0 + $1.proteinG } * 4, c = entries.reduce(0) { $0 + $1.carbsG } * 4
        let f = entries.reduce(0) { $0 + $1.fatG } * 9
        let total = p + c + f
        guard total > 3_000 else { return nil }   // about two days of eating at the least
        return (p / total, c / total, f / total)
    }

    static func distance(_ a: (protein: Double, carbs: Double, fat: Double), _ b: (protein: Double, carbs: Double, fat: Double)) -> Double {
        pow(a.protein - b.protein, 2) + pow(a.carbs - b.carbs, 2) + pow(a.fat - b.fat, 2)
    }
}

/// The macros of a logged entry, enough for comparing a week with the ways of eating.
public struct FoodLogEntryLite: Equatable, Sendable {
    public var proteinG: Double, carbsG: Double, fatG: Double
    public init(proteinG: Double, carbsG: Double, fatG: Double) { self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG }

    public init(_ entry: FoodLogEntry) {
        self.init(proteinG: entry.totals["protein_g"] ?? 0, carbsG: entry.totals["carbs_g"] ?? 0, fatG: entry.totals["fat_g"] ?? 0)
    }
}

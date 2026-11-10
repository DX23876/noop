import Foundation
import WhoopStore

/// The plan's numbers: calories, fasting days, protein, carbohydrate and fat, the pace in kilograms, how hard it
/// is, and what the planner had to hold back. One resolver for the planner, the plan page, the Food page, the coach
/// and Android, so no two screens can disagree.
///
/// Safety lines (decision 2026-11-09), the same in both modes: the week's average never drops below 1,200 kcal;
/// the pace is bound to body weight (a large body may run a large deficit, nobody may starve); a fasting form's
/// eating days must carry the protein goal. Under 18, pregnant or nursing, or underweight: no deficit.
public enum DietTargets {
    public static let weeklyFloorKcal: Double = 1_200
    /// Energy in a kilogram of body weight lost or gained, until the wearer's own figure exists.
    public static let defaultKcalPerKg: Double = 7_700

    public enum Effort: String, Sendable, Codable { case easy, doable, demanding, veryHard }

    public enum Note: String, Sendable, Codable, CaseIterable {
        /// The chosen pace was above what the mode allows and was lowered.
        case paceCapped
        /// The pace is above 1 % a week (advanced only): allowed, but hard on muscle and hunger.
        case paceAboveRecommended
        /// The week's average would have gone under 1,200 kcal and was raised to it.
        case floorApplied
        /// Protein is set below what the goal recommends.
        case proteinLow
        /// Under 18: the planner offers holding weight and eating well, no deficit.
        case youngNoDeficit
        /// Pregnant or nursing: no deficit.
        case pregnancyNoDeficit
        /// Underweight (BMI under 18.5): no deficit.
        case underweightNoDeficit
        /// The goal weight was below BMI 18.5 and was raised to it.
        case goalWeightRaised
    }

    public struct Result: Equatable, Sendable, Codable {
        /// The goal actually planned (a deficit may be held back to maintenance).
        public var goal: DietPlan.Goal
        /// The week's average daily calories.
        public var averageKcal: Double
        /// Calories on an ordinary day; equals the average without a fasting form.
        public var eatingDayKcal: Double
        /// Calories on a fasting day, and how many a week; nil without a fasting form.
        public var fastingDayKcal: Double?
        public var fastingDaysPerWeek: Double?
        public var proteinG: Double
        public var carbsG: Double
        public var fatG: Double
        /// The usual burn the plan starts from.
        public var burnKcal: Double
        /// The planned daily change against the burn (negative in a deficit), before the floor.
        public var dailyDeltaKcal: Double
        public var pacePercent: Double
        public var paceKgPerWeek: Double
        /// Forge's weekly adjustments so far.
        public var adjustmentKcal: Double
        /// 1 to 5, the form and the pace together.
        public var effortScore: Double
        public var effort: Effort
        public var goalWeightKg: Double?
        public var notes: [Note]
    }

    public static func resolve(_ plan: DietPlan, person: DietPerson, burnKcal: Double,
                               kcalPerKg: Double? = nil) -> Result {
        var notes: [Note] = []
        var goal = plan.goal
        if goal == .lose {
            if let age = person.age, age < 18 { goal = .maintain; notes.append(.youngNoDeficit) }
            else if plan.pregnantOrNursing { goal = .maintain; notes.append(.pregnancyNoDeficit) }
            else if let bmi = person.bmi, bmi < 18.5 { goal = .maintain; notes.append(.underweightNoDeficit) }
        } else if goal == .gain, plan.pregnantOrNursing {
            // Gaining in pregnancy is the doctor's plan, not ours; hold instead.
            goal = .maintain; notes.append(.pregnancyNoDeficit)
        }

        var pace = goal == .maintain ? 0 : max(0, plan.pacePercent)
        let limit = DietPlan.paceLimit(goal: goal, mode: plan.mode)
        if pace > limit { pace = limit; notes.append(.paceCapped) }
        if goal == .lose, pace > 1.0 { notes.append(.paceAboveRecommended) }

        let goalWeight = plannedGoalWeight(plan, person: person)
        if goalWeight != plan.goalWeightKg { notes.append(.goalWeightRaised) }

        let perKg = (kcalPerKg ?? defaultKcalPerKg).clamped(5_000, 9_500)
        let kgPerWeek = person.weightKg * pace / 100
        let sign: Double = goal == .lose ? -1 : goal == .gain ? 1 : 0
        let delta = sign * kgPerWeek * perKg / 7
        let adjustment = plan.steering == .manual ? 0 : plan.adjustmentKcal
        var average = plan.steering == .manual ? (plan.fixedKcal ?? burnKcal + delta) : burnKcal + delta + adjustment
        if average < weeklyFloorKcal { average = weeklyFloorKcal; notes.append(.floorApplied) }

        var fastingKcal: Double?
        var fastingDays: Double?
        var eatingKcal = average
        if let fasting = plan.form.fasting {
            let fastDay = burnKcal * fasting.share
            fastingKcal = fastDay
            fastingDays = fasting.daysPerWeek
            eatingKcal = (average * 7 - fastDay * fasting.daysPerWeek) / (7 - fasting.daysPerWeek)
        }

        let reference = person.referenceWeightKg
        let defaultProtein = proteinPerKg(goal: goal, strength: plan.strength) + plan.form.proteinBonusPerKg
        let perKgProtein = plan.mode == .advanced ? (plan.proteinPerKg ?? defaultProtein) : defaultProtein
        if perKgProtein + 0.01 < proteinPerKg(goal: goal, strength: plan.strength) { notes.append(.proteinLow) }
        // Protein on an eating day; with fasting days the week's average carries the macros below.
        let proteinG = min(reference * perKgProtein, 300)
        let restKcal = max(0, average - proteinG * 4)
        let carbsG: Double
        if let cap = plan.form.carbCapG {
            carbsG = min(cap, restKcal / 4)
        } else {
            let share = plan.mode == .advanced ? (plan.carbShareOfRest ?? plan.form.carbShareOfRest) : plan.form.carbShareOfRest
            carbsG = restKcal * share.clamped(0.05, 0.9) / 4
        }
        let fatG = max(0, restKcal - carbsG * 4) / 9

        let score = effortScore(form: plan.form, addon: plan.addon, goal: goal, pace: pace)
        return Result(goal: goal, averageKcal: average, eatingDayKcal: eatingKcal, fastingDayKcal: fastingKcal,
                      fastingDaysPerWeek: fastingDays, proteinG: proteinG, carbsG: carbsG, fatG: fatG, burnKcal: burnKcal,
                      dailyDeltaKcal: delta, pacePercent: pace, paceKgPerWeek: kgPerWeek * sign, adjustmentKcal: adjustment,
                      effortScore: score, effort: effort(score), goalWeightKg: goalWeight, notes: notes)
    }

    /// The goal weight the plan works toward: the wearer's, raised to the lowest healthy weight for their height
    /// (BMI 18.5) when it was below. The plan page, the way to the goal and Today's card all read this one.
    public static func plannedGoalWeight(_ plan: DietPlan, person: DietPerson) -> Double? {
        guard let g = plan.goalWeightKg else { return nil }
        if let lowest = person.lowestGoalWeightKg, g < lowest { return (lowest * 10).rounded(.up) / 10 }
        return g
    }

    /// Grams of protein per kilogram of reference weight: 1.6 in a deficit (2.0 with strength training), 1.2 when
    /// holding or gaining without it (1.6 with it).
    public static func proteinPerKg(goal: DietPlan.Goal, strength: Bool) -> Double {
        switch goal {
        case .lose: strength ? 2.0 : 1.6
        case .maintain, .gain: strength ? 1.6 : 1.2
        }
    }

    static func effortScore(form: DietForm, addon: DietAddon?, goal: DietPlan.Goal, pace: Double) -> Double {
        var score = Double(form.effort) + (addon?.effort ?? 0)
        if goal == .lose {
            score += pace <= 0.5 ? 0 : pace <= 0.75 ? 0.5 : pace <= 1.0 ? 1 : 2
        } else if goal == .gain {
            score += pace <= 0.25 ? 0 : 0.5
        }
        return min(5, max(1, score))
    }

    static func effort(_ score: Double) -> Effort {
        switch score {
        case ..<2: .easy
        case ..<3: .doable
        case ..<4.5: .demanding
        default: .veryHard
        }
    }

    /// Calories for one day of the plan: the eating day, or the fasting day on a fasting form's fasting days.
    /// Fasting days follow a fixed rhythm from the plan's start: every other day for alternate-day forms, Monday
    /// and Thursday for 5:2.
    public static func kcal(on day: String, plan: DietPlan, result: Result, calendar: Calendar = .current) -> Double {
        guard let fastKcal = result.fastingDayKcal, isFastingDay(day, plan: plan, calendar: calendar) else {
            return result.eatingDayKcal
        }
        return fastKcal
    }

    public static func isFastingDay(_ day: String, plan: DietPlan, calendar: Calendar = .current) -> Bool {
        guard let date = WeightSeries.date(forDay: day) else { return false }
        switch plan.form {
        case .fasting52:
            let weekday = calendar.component(.weekday, from: date)   // 2 Monday, 5 Thursday
            return weekday == 2 || weekday == 5
        case .alternateDay, .alternateDayFull:
            guard let start = WeightSeries.date(forDay: plan.startDay),
                  let days = calendar.dateComponents([.day], from: start, to: date).day else { return false }
            return days >= 0 && days % 2 == 1
        default:
            return false
        }
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, self)) }
}

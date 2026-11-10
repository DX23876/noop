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

    /// `phase` is the program's phase of the day (`DietProgram`): a break or holding eats the burn, the step after the
    /// goal half the change.
    public static func resolve(_ plan: DietPlan, person: DietPerson, burnKcal: Double,
                               kcalPerKg: Double? = nil, phase: DietProgram.Phase = .main) -> Result {
        var notes: [Note] = []
        var goal = plan.goal
        if goal == .lose {
            if let age = person.age, age < 18 { goal = .maintain; notes.append(.youngNoDeficit) }
            else if plan.pregnantOrNursing { goal = .maintain; notes.append(.pregnancyNoDeficit) }
            else if let bmi = person.bmi, bmi < 18.5 { goal = .maintain; notes.append(.underweightNoDeficit) }
        } else if goal == .gain, plan.pregnantOrNursing {
            // Gaining in pregnancy is the doctor's plan, not ours; hold instead.
            goal = .maintain; notes.append(.pregnancyNoDeficit)
        } else if goal == .recomp {
            // Recomposition runs a small deficit: the same people as above hold instead.
            if let age = person.age, age < 18 { goal = .maintain; notes.append(.youngNoDeficit) }
            else if plan.pregnantOrNursing { goal = .maintain; notes.append(.pregnancyNoDeficit) }
            else if let bmi = person.bmi, bmi < 18.5 { goal = .maintain; notes.append(.underweightNoDeficit) }
        }

        var pace = goal == .maintain || goal == .recomp ? 0 : max(0, plan.pacePercent)
        let limit = DietPlan.paceLimit(goal: goal, mode: plan.mode)
        if pace > limit { pace = limit; notes.append(.paceCapped) }
        if goal == .lose, pace > 1.0 { notes.append(.paceAboveRecommended) }

        let goalWeight = plannedGoalWeight(plan, person: person)
        if goalWeight != plan.goalWeightKg { notes.append(.goalWeightRaised) }

        let perKg = (kcalPerKg ?? defaultKcalPerKg).clamped(5_000, 9_500)
        let kgPerWeek = person.weightKg * pace / 100
        let sign: Double = goal == .lose ? -1 : goal == .gain ? 1 : 0
        // Recomposition: a few percent under the burn instead of a pace in kilograms.
        let delta = (goal == .recomp ? -burnKcal * plan.recompDeficit / 100 : sign * kgPerWeek * perKg / 7) * phase.deltaFactor
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
        // Protein on an eating day; with fasting days the week's average carries the macros below. Recomposition
        // with a known body fat share reckons on lean mass (`recompProteinG`) unless the wearer set their own.
        let leanProtein = goal == .recomp && plan.proteinPerKg == nil ? recompProteinG(person: person, deficitPercent: plan.recompDeficit) : nil
        let proteinG = min(leanProtein ?? reference * perKgProtein, 300)
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
    /// holding or gaining without it (1.6 with it). Recomposition 2.0 whatever the answer, since it needs training.
    public static func proteinPerKg(goal: DietPlan.Goal, strength: Bool) -> Double {
        switch goal {
        case .lose: strength ? 2.0 : 1.6
        case .maintain, .gain: strength ? 1.6 : 1.2
        case .recomp: 2.0
        }
    }

    /// Recomposition's protein from lean mass, when the body fat share is known: 2.3 g per kilogram of fat-free mass
    /// at a small deficit, rising toward 3.1 as the deficit deepens (Helms and others 2014, 2.3 to 3.1 g/kg FFM
    /// for resistance-trained people in a deficit, scaled up with the deficit). Nil without a usable body fat value.
    public static func recompProteinG(person: DietPerson, deficitPercent: Double) -> Double? {
        guard let lean = person.leanMassKg else { return nil }
        let perKgLean = (2.3 + 0.8 * (deficitPercent.clamped(0, 15) / 15)).clamped(2.3, 3.1)
        return lean * perKgLean
    }

    static func effortScore(form: DietForm, addon: DietAddon?, goal: DietPlan.Goal, pace: Double) -> Double {
        var score = Double(form.effort) + (addon?.effort ?? 0)
        if goal == .lose {
            score += pace <= 0.5 ? 0 : pace <= 0.75 ? 0.5 : pace <= 1.0 ? 1 : 2
        } else if goal == .gain {
            score += pace <= 0.25 ? 0 : 0.5
        } else if goal == .recomp {
            // It asks for regular strength training and plenty of protein.
            score += 1
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

    /// Calories for one day of the plan: the eating day, or the fasting day on a fasting form's fasting days, moved
    /// up on a training day and down on a rest day when the plan shifts calories. Fasting days follow a fixed rhythm
    /// from the plan's start: every other day for alternate-day forms, Monday and Thursday for 5:2.
    public static func kcal(on day: String, plan: DietPlan, result: Result, training: DietTrainingDays = .init(),
                            calendar: Calendar = .current) -> Double {
        if let fastKcal = result.fastingDayKcal, isFastingDay(day, plan: plan, calendar: calendar) { return fastKcal }
        return result.eatingDayKcal + shiftKcal(on: day, plan: plan, result: result, training: training, calendar: calendar)
    }

    /// What the training-day shift adds (a training day) or takes away (a rest day). Training days get the share of
    /// the eating day; rest days give back the same amount spread over them, so the week's average holds, counted
    /// from the training days of that week. A logged strength day outside them gets the extra without a give-back.
    public static func shiftKcal(on day: String, plan: DietPlan, result: Result, training: DietTrainingDays = .init(),
                                 calendar: Calendar = .current) -> Double {
        let share = plan.effectiveDayShift
        let count = weekTrainingCount(day, plan: plan, training: training, calendar: calendar)
        guard share > 0, (1...6).contains(count) else { return 0 }
        let extra = result.eatingDayKcal * share
        if isTrainingDay(day, plan: plan, training: training, calendar: calendar) { return extra }
        return -extra * Double(count) / Double(7 - count)
    }

    /// A training day's and a rest day's calories in the week of `day`, for the planner and the plan page; nil
    /// without a shift.
    public static func trainingAndRestKcal(plan: DietPlan, result: Result, training: DietTrainingDays = .init(),
                                           day: String, calendar: Calendar = .current) -> (training: Double, rest: Double)? {
        let share = plan.effectiveDayShift
        let count = weekTrainingCount(day, plan: plan, training: training, calendar: calendar)
        guard share > 0, (1...6).contains(count) else { return nil }
        let extra = result.eatingDayKcal * share
        return (result.eatingDayKcal + extra, result.eatingDayKcal - extra * Double(count) / Double(7 - count))
    }

    /// A training day: a day the training planner has a session on, a day with logged strength training, or, in a
    /// week the training planner leaves empty, one of the plan's weekdays. The one resolver the calories, the
    /// macros, the plate's line and the active-day rule all read.
    public static func isTrainingDay(_ day: String, plan: DietPlan, training: DietTrainingDays = .init(),
                                     calendar: Calendar = .current) -> Bool {
        if training.logged.contains(day) || training.planned.contains(day) { return true }
        guard plannedInWeek(day, training: training, calendar: calendar).isEmpty,
              let date = WeightSeries.date(forDay: day) else { return false }
        return (plan.trainingWeekdays ?? []).contains(calendar.component(.weekday, from: date))
    }

    /// How many training days the week of `day` plans: the training planner's, else the plan's weekdays.
    public static func weekTrainingCount(_ day: String, plan: DietPlan, training: DietTrainingDays = .init(),
                                         calendar: Calendar = .current) -> Int {
        let planned = plannedInWeek(day, training: training, calendar: calendar)
        if !planned.isEmpty { return planned.count }
        return Set(plan.trainingWeekdays ?? []).filter { (1...7).contains($0) }.count
    }

    /// The training planner's days in the Monday-to-Sunday week of `day`.
    static func plannedInWeek(_ day: String, training: DietTrainingDays, calendar: Calendar) -> Set<String> {
        guard !training.planned.isEmpty, let date = WeightSeries.date(forDay: day) else { return [] }
        var monday = calendar
        monday.firstWeekday = 2
        guard let week = monday.dateInterval(of: .weekOfYear, for: date) else { return [] }
        return training.planned.filter { d in
            WeightSeries.date(forDay: d).map { week.contains($0) } ?? false
        }
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

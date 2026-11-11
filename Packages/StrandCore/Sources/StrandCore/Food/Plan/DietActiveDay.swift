import Foundation

/// Active days bring more calories (owner, 2026-11-10). When the plan has it on, half of what the strap measured
/// above the usual burn so far is added to the day's goal, at most 600 kcal. Half, because measured burn tends to
/// run high; when the real burn from food and weight is known (`DietExpenditure`), the strap's figure is scaled
/// by it first. Protein and fat stay, the extra goes to carbohydrate. A fasting day keeps its own figure.
///
/// One resolver for the plate, the week strip, the macro goals and the evening sentence; the clock is passed in.
public enum DietActiveDay {
    public static let share: Double = 0.5
    public static let maxBonusKcal: Double = 600
    /// Below this the plate does not mention the extra.
    public static let shownFromKcal: Double = 50

    /// The extra calories for `day`. `burnedKcal` is what the strap and Health measured that day so far,
    /// `usualStrapKcal` the strap's usual burn for a whole day, `elapsedFraction` how much of the day has passed
    /// (1 for a past day), `realToStrap` the real burn divided by the strap's when it is known.
    public static func bonusKcal(plan: DietPlan, day: String, burnedKcal: Double?, usualStrapKcal: Double,
                                 elapsedFraction: Double, realToStrap: Double? = nil, training: DietTrainingDays = .init(),
                                 calendar: Calendar = .current) -> Double {
        // A training day with the plan's shift already carries its extra; the same burn must not count twice.
        if plan.effectiveDayShift > 0,
           (1...6).contains(DietTargets.weekTrainingCount(day, plan: plan, training: training, calendar: calendar)),
           DietTargets.isTrainingDay(day, plan: plan, training: training, calendar: calendar) { return 0 }
        guard plan.activeDays == true, plan.steering != .manual,
              let burned = burnedKcal, burned.isFinite, usualStrapKcal.isFinite, usualStrapKcal > 0 else { return 0 }
        if plan.form.fasting != nil, DietTargets.isFastingDay(day, plan: plan, calendar: calendar) { return 0 }
        let usualSoFar = usualStrapKcal * elapsedFraction.clamped(0, 1)
        let extra = max(0, burned - usualSoFar) * (realToStrap ?? 1).clamped(0.5, 1.5)
        return min(maxBonusKcal, (extra * share / 5).rounded() * 5)
    }

    /// How much of `day` has passed at `now`: 1 for a past day, 0 for a later one, the share of the clock today.
    public static func elapsedFraction(day: String, now: Date, calendar: Calendar = .current) -> Double {
        guard let date = WeightSeries.date(forDay: day) else { return 1 }
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 1 }
        if now >= end { return 1 }
        if now <= start { return 0 }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }
}

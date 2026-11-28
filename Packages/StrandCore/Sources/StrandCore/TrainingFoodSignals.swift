import Foundation
import WhoopStore

/// What the food log adds to Training Load (Training Load plan, phase 2, Q37 to Q42): an explanation beside the
/// verdict, never a verdict of its own, and one safety rule for the morning advice.
///
/// Only days the wearer marked as completely logged count (Q41), the rule the real burn follows
/// (`DietExpenditure`): guessing completeness from the amount eaten would drop exactly the days on which they
/// really ate little. Without a plan or without complete days every signal is off, and nothing asks the wearer
/// to log (Q42).
public enum TrainingFoodSignals {
    public struct Signals: Equatable, Sendable {
        /// Complete days well under plan, or under the weekly floor, during a heavy week: the advice never
        /// pushes and says so calmly (Q38). Low intake is never praised.
        public var ateTooLittle: Bool
        /// Losing, the weight trend has stalled, and the complete days were over plan: the screen says "eaten
        /// over plan" instead of letting a stalled weight read as cardio not working (Q37).
        public var ateOverPlan: Bool
        /// Protein under 80 % of the plan's goal on the complete days: a possible reason beside falling
        /// strength, as the Food page's own suggestion (Q40).
        public var proteinLow: Bool
        public var completeDays: Int

        public init(ateTooLittle: Bool = false, ateOverPlan: Bool = false, proteinLow: Bool = false, completeDays: Int = 0) {
            self.ateTooLittle = ateTooLittle; self.ateOverPlan = ateOverPlan; self.proteinLow = proteinLow
            self.completeDays = completeDays
        }

        public static let none = Signals()
    }

    /// Days read back.
    public static let windowDays = 7
    /// Complete days needed before any signal speaks.
    public static let minimumCompleteDays = 3
    /// Under plan by more than this a day, on average, is "well under plan".
    public static let underPlanKcal = 500.0
    /// The plan's own weekly floor (`DietTargets`: the week's average never under 1,200 kcal).
    public static let floorKcal = 1_200.0
    /// Over plan by more than this a day, on average, is "eaten over plan".
    public static let overPlanKcal = 100.0
    /// The Food page's protein rule (`DietAdvice`): under 80 % of the goal.
    public static let proteinShare = 0.8
    /// The Food page's stall rule (`DietAdvice`): a three-week trend above −0.1 kg a week while losing.
    public static let stalledTrendKgPerWeek = -0.1

    public static func evaluate(intake: [Double], protein: [Double], goalKcal: Double?, proteinGoalG: Double?,
                                heavyWeek: Bool, losing: Bool, trendKgPerWeek: Double?) -> Signals {
        guard intake.count >= minimumCompleteDays, let goal = goalKcal, goal > 0 else {
            return Signals(completeDays: intake.count)
        }
        let mean = intake.reduce(0, +) / Double(intake.count)
        let tooLittle = heavyWeek && (mean < goal - underPlanKcal || mean < floorKcal)
        let stalled = losing && (trendKgPerWeek.map { $0 > stalledTrendKgPerWeek } ?? false)
        let over = stalled && mean > goal + overPlanKcal
        var proteinLow = false
        if let pGoal = proteinGoalG, pGoal > 0, protein.count >= minimumCompleteDays {
            proteinLow = protein.reduce(0, +) / Double(protein.count) < pGoal * proteinShare
        }
        return Signals(ateTooLittle: tooLittle, ateOverPlan: over, proteinLow: proteinLow, completeDays: intake.count)
    }

    /// The signals over the last week, from the store. `goalKcal` and `proteinGoalG` are the plan's day goals as
    /// the Food page resolves them (`DietDayResolver`); nil without a plan, which turns every signal off.
    public static func read(store: WhoopStore, today: String, goalKcal: Double?, proteinGoalG: Double?,
                            heavyWeek: Bool, losing: Bool, trendKgPerWeek: Double?) async -> Signals {
        guard goalKcal != nil else { return .none }
        let from = dayKey(today, minus: windowDays - 1)
        let complete = (try? await store.foodCompleteDays(from: from, to: today)) ?? []
        guard !complete.isEmpty else { return .none }
        let days = await NutritionReads.nutritionByDay(store: store, from: from, to: today)
        let rows = complete.sorted().compactMap { days[$0] }
        return evaluate(intake: rows.compactMap(\.calories), protein: rows.compactMap(\.proteinG), goalKcal: goalKcal,
                        proteinGoalG: proteinGoalG, heavyWeek: heavyWeek, losing: losing, trendKgPerWeek: trendKgPerWeek)
    }

    static func dayKey(_ day: String, minus days: Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        return f.string(from: d.addingTimeInterval(-Double(days) * 86_400))
    }
}

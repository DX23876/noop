import Foundation

/// One day of a diet plan as the Food page reads it, in one place (Android parity, 2026-11-12): the real burn
/// from completely logged days and the weight trend (`DietExpenditure`), the burn the plan starts from, the day's
/// phase (`DietProgram`), its training-day shift and its active-day extra (`DietActiveDay`). iOS's
/// `ForgeFoodModel` runs the same steps; the Android core calls this so both read the same figures.
public enum DietDayResolver {
    public struct Inputs {
        public var plan: DietPlan
        public var person: DietPerson
        /// The strap's usual burn for a whole day, whatever the plan starts from; active days are measured against it.
        public var strapBurnKcal: Double
        public var kcalPerKg: Double?
        /// What each recent day burned as the strap and Health measured it, today until now.
        public var burnedByDay: [String: Double]
        public var completeDays: Set<String>
        /// The kcal the energy plan counts per day: a typed day value or an import wins over the food log.
        public var intakeByDay: [String: Double]
        public var weighIns: [(day: String, kg: Double)]
        public var training: DietTrainingDays
        public var today: String

        public init(plan: DietPlan, person: DietPerson, strapBurnKcal: Double, kcalPerKg: Double?,
                    burnedByDay: [String: Double], completeDays: Set<String>, intakeByDay: [String: Double],
                    weighIns: [(day: String, kg: Double)], training: DietTrainingDays, today: String) {
            self.plan = plan; self.person = person; self.strapBurnKcal = strapBurnKcal; self.kcalPerKg = kcalPerKg
            self.burnedByDay = burnedByDay; self.completeDays = completeDays; self.intakeByDay = intakeByDay
            self.weighIns = weighIns; self.training = training; self.today = today
        }
    }

    public struct Day {
        public var expenditure: DietExpenditure.Outcome
        /// The burn the plan starts from: the real one when the wearer chose the scale and it is known.
        public var planBurnKcal: Double
        public var phase: DietProgram.Phase
        public var result: DietTargets.Result
        public var calories: FoodTargets.Calories
        public var macros: FoodTargets.Macros
        public var activeBonusKcal: Double
        public var isTrainingDay: Bool
    }

    public static func resolve(_ inputs: Inputs, day: String, now: Date = Date()) -> Day {
        let plan = inputs.plan
        let kcalPerKg = inputs.kcalPerKg ?? DietTargets.defaultKcalPerKg
        let expenditure = DietExpenditure.estimate(intakeByDay: inputs.intakeByDay, completeDays: inputs.completeDays,
                                                   weighIns: inputs.weighIns, strapByDay: inputs.burnedByDay,
                                                   today: inputs.today, kcalPerKg: kcalPerKg)
        var planBurn = inputs.strapBurnKcal
        var realToStrap: Double?
        if case .estimate(let e) = expenditure {
            realToStrap = e.realToStrap
            if plan.burnSource == .scale { planBurn = e.burnKcal }
        }
        let goalReached = DietProgram.goalReachedDay(plan: plan,
                                                     goalWeightKg: DietTargets.plannedGoalWeight(plan, person: inputs.person),
                                                     weighIns: inputs.weighIns)
        let phase = DietProgram.phase(on: day, plan: plan, goalReachedDay: goalReached)
        let result = DietTargets.resolve(plan, person: inputs.person, burnKcal: planBurn, kcalPerKg: inputs.kcalPerKg,
                                         phase: phase)
        let bonus = DietActiveDay.bonusKcal(plan: plan, day: day, burnedKcal: inputs.burnedByDay[day],
                                            usualStrapKcal: inputs.strapBurnKcal,
                                            elapsedFraction: DietActiveDay.elapsedFraction(day: day, now: now),
                                            realToStrap: realToStrap, training: inputs.training)
        return Day(expenditure: expenditure, planBurnKcal: planBurn, phase: phase, result: result,
                   calories: FoodTargets.calories(plan: plan, result: result, day: day, activeBonusKcal: bonus,
                                                  training: inputs.training),
                   macros: FoodTargets.macros(plan: plan, result: result, day: day, activeBonusKcal: bonus,
                                              training: inputs.training),
                   activeBonusKcal: bonus,
                   isTrainingDay: DietTargets.isTrainingDay(day, plan: plan, training: inputs.training))
    }
}

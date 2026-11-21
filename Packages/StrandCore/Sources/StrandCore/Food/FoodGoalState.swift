import Foundation

/// Where a day and its week stand against the wearer's own goal (owner, 2026-11-21,
/// `backlog/ideas/food-score-coach-2026-11-21.md`): energy, protein, and what the diet form fixes (keto's and
/// low carb's carbohydrate cap). Kept apart from the quality note on purpose: a day of fast food can keep the
/// deficit, and a day of perfect food can be far over it.
///
/// The burn behind an energy goal is an estimate, often 10 to 20 % off, so a day is generous (±15 %) and what is
/// rewarded is mostly the seven-day mean in range. A day below the floor never counts as kept, so eating too
/// little is never rewarded; a larger deficit is never better than one in range.
public enum FoodGoalState {
    public enum Energy: String, Equatable, Sendable, Codable {
        case inRange, over, under
        /// Below the floor: never counted as kept, whatever the goal says.
        case belowFloor
    }

    public struct Goals: Equatable, Sendable {
        public var kcal: Double
        public var proteinG: Double?
        /// The diet form's daily carbohydrate cap (`DietForm.carbCapG`).
        public var carbCapG: Double?
        /// The lowest intake that may count as kept (`floorKcal`).
        public var floorKcal: Double

        public init(kcal: Double, proteinG: Double?, carbCapG: Double?, floorKcal: Double) {
            self.kcal = kcal; self.proteinG = proteinG; self.carbCapG = carbCapG; self.floorKcal = floorKcal
        }
    }

    public struct Day: Equatable, Sendable {
        public var energy: Energy
        /// Eaten energy over the goal (1 = on goal).
        public var energyRatio: Double
        /// Nil without a protein goal.
        public var proteinMet: Bool?
        /// Nil without a carbohydrate cap.
        public var carbsWithinCap: Bool?

        /// Every goal the day has, kept.
        public var kept: Bool { energy == .inRange && proteinMet != false && carbsWithinCap != false }
    }

    /// ±15 % of the goal on one day.
    public static let dayTolerance = 0.15
    /// Protein counts as met from 90 % of its goal.
    public static let proteinMetShare = 0.9
    /// A week's mean needs this many logged days.
    public static let weekMinimumDays = 5
    /// The floor's fixed part: 1,500 kcal for men, 1,200 for women, the stricter 1,500 when the sex is unknown.
    public static func floorKcal(basalKcal: Double?, male: Bool?) -> Double {
        max(basalKcal ?? 0, male == false ? 1_200 : 1_500)
    }

    public static func day(kcal: Double, proteinG: Double, carbsG: Double, goals: Goals) -> Day {
        let ratio = goals.kcal > 0 ? kcal / goals.kcal : 0
        let energy: Energy
        if kcal < goals.floorKcal { energy = .belowFloor }
        else if ratio > 1 + dayTolerance { energy = .over }
        else if ratio < 1 - dayTolerance { energy = .under }
        else { energy = .inRange }
        return Day(energy: energy, energyRatio: ratio,
                   proteinMet: goals.proteinG.map { $0 > 0 ? proteinG >= $0 * proteinMetShare : true },
                   carbsWithinCap: goals.carbCapG.map { carbsG <= $0 })
    }

    /// The seven-day mean against the goal; nil with fewer than `weekMinimumDays` logged days. A mean below the
    /// floor is `belowFloor`, so a week of too little is never the week that kept the goal.
    public static func week(dailyKcal: [Double], goals: Goals) -> (energy: Energy, ratio: Double)? {
        guard dailyKcal.count >= weekMinimumDays, goals.kcal > 0 else { return nil }
        let mean = dailyKcal.reduce(0, +) / Double(dailyKcal.count)
        let ratio = mean / goals.kcal
        if mean < goals.floorKcal { return (.belowFloor, ratio) }
        if ratio > 1 + dayTolerance { return (.over, ratio) }
        if ratio < 1 - dayTolerance { return (.under, ratio) }
        return (.inRange, ratio)
    }

    /// The warning while logging (owner, 2026-11-21): when the wearer is losing weight and this entry takes the
    /// day more than 20 % over the goal, the day's energy with it, else nil. Off unless `losing`.
    public static func overWarning(dayKcal: Double, adding: Double, goalKcal: Double, losing: Bool) -> Double? {
        guard losing, goalKcal > 0, adding > 0 else { return nil }
        let after = dayKcal + adding
        return after > goalKcal * (1 + warnOverShare) ? after : nil
    }

    /// The share over the goal from which logging warns.
    public static let warnOverShare = 0.20
}

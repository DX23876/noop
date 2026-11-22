import Foundation
import WhoopStore

/// What the food notifications say, worked out once for both platforms (owner, 2026-11-21,
/// `backlog/ideas/food-score-coach-2026-11-21.md`); each platform only words and delivers it.
///
/// - Every morning a look back at yesterday: its note, the goal, what lifted the note and one thing to watch,
///   and any badge earned. On Mondays the week's look back takes its place, on the first of a month the month's.
/// - In the evening only when one meal can still close a gap (protein, vegetables). Being over the goal is never
///   a push of its own: it is said once, neutrally, in the next morning's look back.
public enum FoodNotice {
    public enum Kind: String, Equatable, Sendable, Codable { case day, week, month }

    public struct Recap: Equatable, Sendable {
        public var kind: Kind
        /// The note looked back on; nil when the day or span has none.
        public var note: FoodQuality.Note?
        /// The span before, for "up from 7.1" on a week or month.
        public var previous: FoodQuality.Note?
        /// The part that did best (8 points or more).
        public var strongest: FoodScore.Component?
        /// The part with the most room to grow (under 6 points).
        public var weakest: FoodScore.Component?
        public var goal: FoodGoalState.Energy?
        public var badges: [FoodBadges.Earned]
    }

    /// The morning's kind: the month's look back on the first, else the week's on a Monday, else the day's.
    public static func morningKind(today: String, calendar: Calendar = FoodBadges.isoCalendar) -> Kind {
        guard let date = WeightSeries.date(forDay: today) else { return .day }
        if calendar.component(.day, from: date) == 1 { return .month }
        return calendar.component(.weekday, from: date) == 2 ? .week : .day
    }

    /// The look back for `kind`, ending yesterday. `badges` are the badges earned since the last look back.
    public static func recap(kind: Kind, note: FoodQuality.Note?, previous: FoodQuality.Note?,
                             goal: FoodGoalState.Energy?, badges: [FoodBadges.Earned]) -> Recap {
        let parts = note?.parts ?? []
        // A day's look back leaves the weekly foods out of "what to watch": a day without fish is not news.
        let candidates = kind == .day ? parts.filter { !$0.component.isWeekly } : parts
        let strongest = candidates.filter { $0.points >= 8 }.max { $0.points < $1.points }?.component
        let weakest = candidates.filter { $0.points < 6 }.min { $0.points < $1.points }?.component
        return Recap(kind: kind, note: note, previous: previous, strongest: strongest, weakest: weakest, goal: goal,
                     badges: badges)
    }

    /// What one more meal can still close tonight.
    public struct Gap: Equatable, Sendable {
        /// Grams of protein short of the goal, when one meal can bring them (15 to 60 g).
        public var proteinG: Double?
        /// Vegetable portions short of two, when the day has fewer.
        public var vegetablePortions: Double?
        public var isEmpty: Bool { proteinG == nil && vegetablePortions == nil }
    }

    public static let eveningProteinRange = 15.0...60.0
    public static let eveningVegetablePortions = 2.0

    /// Nil when nothing a meal can fix is open, so the evening stays quiet.
    public static func eveningGap(proteinEatenG: Double, proteinGoalG: Double?, vegetableGrams: Double) -> Gap? {
        var gap = Gap()
        if let goal = proteinGoalG, goal > 0 {
            let short = goal - proteinEatenG
            if eveningProteinRange.contains(short) { gap.proteinG = short }
        }
        let portions = vegetableGrams / FoodScore.Portion.vegetables
        if portions < eveningVegetablePortions { gap.vegetablePortions = eveningVegetablePortions - portions }
        return gap.isEmpty ? nil : gap
    }

    /// The day's vegetable grams as the score counts them.
    public static func vegetableGrams(_ entries: [FoodLogEntry], facts: [String: FoodScore.FoodFacts] = [:]) -> Double {
        entries.reduce(0) { sum, entry in
            guard let g = entry.grams, g > 0 else { return sum }
            let share = FoodScore.groups(of: entry, facts: facts).first { $0.0 == .vegetables }?.1 ?? 0
            return sum + g * share
        }
    }

    /// When the evening reminder goes: three hours before the usual bedtime, never before 17:00.
    public static func eveningTime(usualBedtime: DateComponents, calendar: Calendar = .current) -> DateComponents {
        let bedMinutes = (usualBedtime.hour ?? 23) * 60 + (usualBedtime.minute ?? 0)
        let minutes = max(17 * 60, (bedMinutes - 180 + 24 * 60) % (24 * 60))
        return DateComponents(hour: minutes / 60, minute: minutes % 60)
    }
}

import Foundation
import WhoopStore

/// How good the eating was, 0 to 10, for one day, a week or a month (owner, 2026-11-21,
/// `backlog/ideas/food-score-coach-2026-11-21.md`). The one place every screen, notification and the coach read the
/// notes from, computed from the food log when asked; nothing is stored, so an entry changed later can never leave
/// a stale note behind.
///
/// - A day's note scores the day's own food on the `FoodScore` parts, except the foods eaten a few times a week
///   (fish, nuts and pulses, meat), which it reads over the seven days ending on that day.
/// - A week's or a month's note adds up the amounts of its 7 or 28 days first and scores them once, the NCI's
///   method for more than one day. Averaging day notes would not give the same figure, since each part is capped
///   at 10 a day; the two may differ, and say different things (the day, the habit).
/// - A day counts once it holds at least half the wearer's usual intake; today's note is provisional.
/// - Food the log cannot place in any group is shown as a share; from 30 % of the energy the note is uncertain.
public enum FoodQuality {
    public struct Note: Equatable, Sendable, Codable {
        /// The last day the note covers (the day itself for a day's note).
        public var day: String
        /// The days it covers: 1, 7 or 28.
        public var span: Int
        /// 0 to 10.
        public var score: Double
        public var parts: [FoodScore.Part]
        /// Days in the span that carry a log.
        public var loggedDays: Int
        /// Share of the energy from foods whose group is known, 0 to 1.
        public var placedShare: Double
        /// Share of the energy from highly processed foods (NOVA 4), when any food knew its class.
        public var processedShare: Double?
        /// A day still being eaten (today).
        public var provisional: Bool

        /// Too much unplaced food to call the note sure; it then earns no badge.
        public var uncertain: Bool { placedShare < 1 - FoodQuality.uncertainUnplacedShare }
    }

    /// Why a day has no note.
    public enum Missing: Equatable, Sendable {
        /// Nothing logged.
        case nothing
        /// Less than half the usual intake logged so far.
        case tooLittle(loggedKcal: Double, neededKcal: Double)
    }

    public static let weekSpan = 7
    public static let monthSpan = 28
    /// From this share of unplaced energy a note is uncertain.
    public static let uncertainUnplacedShare = 0.30
    /// A day counts from this share of the usual intake.
    public static let countsFromShare = 0.5
    /// The usual intake is the median of up to this many logged days before.
    public static let usualDays = 14
    /// Fewer logged days than this before a day leave the usual intake to the calorie goal.
    public static let usualMinimumDays = 3

    /// The note of `day`. `entries` must cover the seven days ending on `day` (earlier ones are ignored);
    /// `usualKcal` is the wearer's usual intake (`usualKcal(entries:before:)`, else the calorie goal).
    public static func day(_ day: String, entries: [FoodLogEntry], facts: [String: FoodScore.FoodFacts] = [:],
                           male: Bool?, options: FoodScore.Options = .init(), usualKcal: Double?, today: String,
                           calendar: Calendar = .current) -> Result<Note, MissingError> {
        let own = entries.filter { $0.day == day }
        guard !own.isEmpty else { return .failure(MissingError(reason: .nothing)) }
        let kcal = own.reduce(0) { $0 + ($1.totals["energy_kcal"] ?? 0) }
        if let usualKcal, usualKcal > 0, kcal < usualKcal * countsFromShare {
            return .failure(MissingError(reason: .tooLittle(loggedKcal: kcal, neededKcal: usualKcal * countsFromShare)))
        }
        guard let first = shifted(day, by: -(weekSpan - 1), calendar: calendar) else {
            return .failure(MissingError(reason: .nothing))
        }
        let week = entries.filter { $0.day >= first && $0.day <= day }
        let weekly = FoodScore.weeklyFoods(week, days: Double(Set(week.map(\.day)).count), facts: facts)
        let result = FoodScore.score(own, days: 1, facts: facts, male: male, options: options, weekly: weekly)
        return .success(Note(day: day, span: 1, score: result.score / 10, parts: result.parts, loggedDays: 1,
                             placedShare: placedShare(own, facts: facts), processedShare: result.processedShare,
                             provisional: day >= today))
    }

    /// The note of the `span` days ending on `lastDay`, from their amounts added up. Nil with fewer than five
    /// logged days in a week, or fewer than half the days of a longer span.
    public static func period(span: Int, lastDay: String, entries: [FoodLogEntry],
                              facts: [String: FoodScore.FoodFacts] = [:], male: Bool?,
                              options: FoodScore.Options = .init(), today: String,
                              calendar: Calendar = .current) -> Note? {
        guard let first = shifted(lastDay, by: -(span - 1), calendar: calendar) else { return nil }
        let inSpan = entries.filter { $0.day >= first && $0.day <= lastDay }
        let days = Set(inSpan.map(\.day)).count
        guard days >= minimumLoggedDays(span: span) else { return nil }
        let result = FoodScore.score(inSpan, days: Double(days), facts: facts, male: male, options: options)
        return Note(day: lastDay, span: span, score: result.score / 10, parts: result.parts, loggedDays: days,
                    placedShare: placedShare(inSpan, facts: facts), processedShare: result.processedShare,
                    provisional: lastDay >= today)
    }

    /// Five of seven days for a week (as the week's score always asked), half the days for a longer span.
    public static func minimumLoggedDays(span: Int) -> Int {
        span <= weekSpan ? FoodScore.minimumDays : Int((Double(span) / 2).rounded(.up))
    }

    /// The wearer's usual intake before `day`: the median energy of up to `usualDays` logged days before it.
    /// Nil with fewer than `usualMinimumDays`, when the calorie goal stands in.
    public static func usualKcal(entries: [FoodLogEntry], before day: String) -> Double? {
        let byDay = Dictionary(grouping: entries.filter { $0.day < day }, by: \.day)
        let recent = byDay.keys.sorted().suffix(usualDays)
        guard recent.count >= usualMinimumDays else { return nil }
        let kcal = recent.map { key in byDay[key]!.reduce(0) { $0 + ($1.totals["energy_kcal"] ?? 0) } }.sorted()
        let mid = kcal.count / 2
        return kcal.count % 2 == 0 ? (kcal[mid - 1] + kcal[mid]) / 2 : kcal[mid]
    }

    /// The energy share of food whose group is known: a BLS or recipe id, a stored group, or a name the score
    /// places. A quick calorie entry and an own food saved without a group are not placed.
    public static func placedShare(_ entries: [FoodLogEntry], facts: [String: FoodScore.FoodFacts]) -> Double {
        var total = 0.0, placed = 0.0
        for entry in entries {
            let kcal = entry.totals["energy_kcal"] ?? 0
            total += kcal
            if isPlaced(entry, facts: facts) { placed += kcal }
        }
        return total > 0 ? placed / total : 1
    }

    static func isPlaced(_ entry: FoodLogEntry, facts: [String: FoodScore.FoodFacts]) -> Bool {
        guard let id = entry.foodId else { return false }
        if id.hasPrefix("bls:") || id.hasPrefix("recipe:") { return true }
        if let group = facts[id]?.group, !group.isEmpty { return true }
        return FoodScore.kind(of: entry, group: nil, name: entry.name.lowercased()) != nil
    }

    /// The reason a day has no note, as an error so `day` reads as one result.
    public struct MissingError: Error, Equatable, Sendable {
        public var reason: Missing
    }

    static func shifted(_ day: String, by days: Int, calendar: Calendar) -> String? {
        guard let date = WeightSeries.date(forDay: day),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return StoreReader.localDayKey(moved)
    }
}

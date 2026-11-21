import Foundation
import WhoopStore

/// Badges and the logging streak for the food log (owner, 2026-11-21, `backlog/ideas/food-score-coach-2026-11-21.md`).
/// They reward what the wearer does, never a number on the scale: staying with it, eating well, and holding a habit.
/// No points and no levels, and nothing for a larger deficit; an uncertain note earns nothing either. Everything is worked out from the food log when asked, so a corrected entry corrects the
/// badges too.
public enum FoodBadges {
    public enum Badge: Hashable, Sendable, Codable {
        /// Seven counted days in one week (Monday to Sunday).
        case firstFullWeek
        /// 30 and 100 counted days in all.
        case days30, days100
        /// The first week, and the first 28 days, with a note of 8 or more.
        case goodWeek, goodMonth
        /// A part of the note at 8 or more in four weeks in a row.
        case habit(FoodScore.Component)
    }

    public struct Earned: Equatable, Sendable {
        public var badge: Badge
        /// The day it was earned on.
        public var day: String
    }

    public struct Summary: Equatable, Sendable {
        public var earned: [Earned]
        /// Counted days in a row up to the last day, one missed day a week bridged by a joker.
        public var streakDays: Int
        /// The best week note so far and the Sunday it ended on.
        public var bestWeek: FoodQuality.Note?
    }

    public static let goodNote = 8.0
    public static let habitPoints = 8.0
    public static let habitWeeks = 4

    /// `countedDays` are the days with a note (`FoodQuality.day` succeeded and the note is not uncertain), oldest
    /// first; `weekNotes` the notes of each Sunday's seven days and `monthNotes` of each Sunday's 28 days, both
    /// keyed by that Sunday. `today` ends the streak.
    public static func summary(countedDays: [String], weekNotes: [String: FoodQuality.Note],
                               monthNotes: [String: FoodQuality.Note], today: String,
                               calendar: Calendar = isoCalendar) -> Summary {
        var earned: [Earned] = []
        func earn(_ badge: Badge, _ day: String) {
            if !earned.contains(where: { $0.badge == badge }) { earned.append(Earned(badge: badge, day: day)) }
        }
        let days = countedDays.sorted()
        for (index, day) in days.enumerated() {
            if index + 1 == 30 { earn(.days30, day) }
            if index + 1 == 100 { earn(.days100, day) }
        }
        let byWeek = Dictionary(grouping: days, by: { weekStart($0, calendar: calendar) ?? $0 })
        for start in byWeek.keys.sorted() where (byWeek[start]?.count ?? 0) >= 7 {
            earn(.firstFullWeek, byWeek[start]!.max()!)
        }
        let sundays = weekNotes.keys.sorted()
        for sunday in sundays {
            if let note = weekNotes[sunday], !note.uncertain, note.score >= goodNote { earn(.goodWeek, sunday) }
            if let note = monthNotes[sunday], !note.uncertain, note.score >= goodNote { earn(.goodMonth, sunday) }
        }
        for component in FoodScore.Component.allCases {
            var run = 0
            var previous: String?
            for sunday in sundays {
                let held = weekNotes[sunday].flatMap { note in
                    note.uncertain ? nil : note.parts.first { $0.component == component }
                }.map { $0.points >= habitPoints } ?? false
                let follows = previous.flatMap { FoodQuality.shifted($0, by: 7, calendar: calendar) } == sunday
                run = held ? (follows ? run + 1 : 1) : 0
                previous = sunday
                if run >= habitWeeks { earn(.habit(component), sunday) }
            }
        }
        let best = weekNotes.values.filter { !$0.uncertain }.max { $0.score < $1.score }
        return Summary(earned: earned.sorted { $0.day < $1.day }, streakDays: streak(days: Set(days), today: today, calendar: calendar),
                       bestWeek: best)
    }

    /// Counted days in a row ending today or yesterday (today may still be in progress). One missed day in each
    /// week is bridged by a joker, so a birthday dinner does not break the run; a second miss in the same week does.
    public static func streak(days: Set<String>, today: String, calendar: Calendar = isoCalendar) -> Int {
        guard var day = days.contains(today) ? today : FoodQuality.shifted(today, by: -1, calendar: calendar) else { return 0 }
        var count = 0
        var jokerWeek: String?
        while true {
            if days.contains(day) {
                count += 1
            } else {
                let week = weekStart(day, calendar: calendar)
                guard count > 0, jokerWeek != week,
                      let before = FoodQuality.shifted(day, by: -1, calendar: calendar), days.contains(before) else { break }
                jokerWeek = week
            }
            guard let previous = FoodQuality.shifted(day, by: -1, calendar: calendar) else { break }
            day = previous
        }
        return count
    }

    /// The badges' inputs from the whole food log: the counted days, and each Sunday's week and 28-day notes up to
    /// `today`. `usualFallbackKcal` stands in for the usual intake while fewer than three days are logged.
    public static func summary(entries: [FoodLogEntry], facts: [String: FoodScore.FoodFacts] = [:], male: Bool?,
                               options: FoodScore.Options = .init(), usualFallbackKcal: Double?, today: String,
                               calendar: Calendar = isoCalendar) -> Summary {
        let byDay = Dictionary(grouping: entries, by: \.day)
        let days = byDay.keys.sorted()
        var counted: [String] = []
        for day in days where day <= today {
            guard let first = FoodQuality.shifted(day, by: -(FoodQuality.weekSpan - 1), calendar: calendar) else { continue }
            let window = entries.filter { $0.day >= first && $0.day <= day }
            let usual = FoodQuality.usualKcal(entries: entries, before: day) ?? usualFallbackKcal
            if case .success(let note) = FoodQuality.day(day, entries: window, facts: facts, male: male, options: options,
                                                         usualKcal: usual, today: today, calendar: calendar),
               !note.uncertain {
                counted.append(day)
            }
        }
        var weekNotes: [String: FoodQuality.Note] = [:]
        var monthNotes: [String: FoodQuality.Note] = [:]
        if let first = days.first, let start = WeightSeries.date(forDay: first), let end = WeightSeries.date(forDay: today) {
            var date = calendar.dateInterval(of: .weekOfYear, for: start).flatMap {
                calendar.date(byAdding: .day, value: 6, to: $0.start)
            } ?? start
            while date <= end {
                let sunday = StoreReader.localDayKey(date)
                weekNotes[sunday] = FoodQuality.period(span: FoodQuality.weekSpan, lastDay: sunday, entries: entries,
                                                       facts: facts, male: male, options: options, today: today, calendar: calendar)
                monthNotes[sunday] = FoodQuality.period(span: FoodQuality.monthSpan, lastDay: sunday, entries: entries,
                                                        facts: facts, male: male, options: options, today: today, calendar: calendar)
                guard let next = calendar.date(byAdding: .day, value: 7, to: date) else { break }
                date = next
            }
        }
        return summary(countedDays: counted, weekNotes: weekNotes.compactMapValues { $0 },
                       monthNotes: monthNotes.compactMapValues { $0 }, today: today, calendar: calendar)
    }

    /// Weeks start on Monday, whatever the device's first weekday.
    public static var isoCalendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    static func weekStart(_ day: String, calendar: Calendar) -> String? {
        guard let date = WeightSeries.date(forDay: day),
              let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return nil }
        return StoreReader.localDayKey(start)
    }
}

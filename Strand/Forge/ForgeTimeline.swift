import Foundation
import StrandAnalytics

/// The redesigned Today timeline (2026-11): one list of what happened, newest first, assembled from data
/// the app already stores. Nothing here is persisted and nothing is derived: every figure is copied from an
/// input that another screen already shows, so the timeline can never disagree with the screen behind it.
///
/// Pure on purpose (no Repository, no SwiftUI) so the ordering, day grouping and text splitting are pinned
/// by `ForgeTimelineTests` without a strap or a database.
enum ForgeTimeline {

    // MARK: Inputs (plain values copied from existing reads)

    struct CoachNote: Equatable {
        enum Origin: String {
            case brief, checkIn, nudge, weeklyReview, afterWorkout, evening

            /// The kind of a note stored before kinds were (2026-11-07): the workout note and the evening
            /// recap were nudges told apart only by their first line, in English or in the app's language.
            static func legacy(nudgeText text: String) -> Origin {
                let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if first == "After your workout" || first == String(localized: "After your workout") { return .afterWorkout }
                if first == "Evening recap" || first == String(localized: "Evening recap") { return .evening }
                return .nudge
            }
        }
        let id: String
        let date: Date
        let text: String
        let origin: Origin
        /// The workout this note is about, when the coach wrote it for one. The two then share one entry.
        var workoutId: String? = nil
        /// Answers the coach offered with this note. Empty unless the note asks something.
        var replies: [String] = []
        /// What Today showed when the note was written (`ForgeNoteBasis`).
        var basis: String? = nil
        /// Questions asked under the note and the coach's answers, in order.
        var followUps: [FollowUp] = []
    }

    /// One question asked from a note and the coach's answer, shown under the note.
    struct FollowUp: Equatable {
        let question: String
        let answer: String
    }

    struct Workout: Equatable {
        let id: String
        let start: Date
        let end: Date
        let sport: String
        /// Stored 0–100 Effort for the session, if scored.
        let effort: Double?
        let distanceM: Double?
        let energyKcal: Double?
        /// A walk the app detected or another app imported: bundled with the day's others.
        var bundles = false
    }

    struct Sleep: Equatable {
        let start: Date
        let end: Date
        let minutesAsleep: Double?
        /// Rest for that night (0–100), if scored.
        let rest: Double?
    }

    struct Nap: Equatable {
        let start: Date
        let end: Date
        let minutesAsleep: Double
    }

    struct Weight: Equatable {
        let date: Date
        let kg: Double
        /// False for a daily cell (Apple's weights have no time): it sits at the end of its day, without one.
        var timed = true
    }

    /// One line per day for things logged several times or without a time.
    struct DayLog: Equatable {
        enum Kind: String { case drink, food, journal }
        let kind: Kind
        let date: Date
        let value: Double
        /// False when the source only knows the day.
        var timed = true
    }

    struct Ecg: Equatable {
        let id: String
        let date: Date
        let averageHr: Int?
    }

    /// A notice from the data (a Momentum signal, a strap that still has the night, a body signal),
    /// already admitted by `TimelineFeed.admit` and placed at the moment it first appeared.
    struct Notice: Equatable {
        enum Tone: String { case positive, neutral, caution, critical }
        enum Action: Equatable { case none, charge, plan, goals, sleep, confirmWake }
        let key: String
        let date: Date
        let topic: String
        let tone: Tone
        let headline: String
        let detail: String
        var action: Action = .none
        var actionTitle: String? = nil
    }

    /// The evening report without a coach: Effort against today's target, the sessions, tomorrow's plan,
    /// and a bedtime only while sleep debt grows.
    struct DayEnd: Equatable {
        let date: Date
        let sessions: Int
        let tomorrow: String?
        let bedtime: Date?
    }

    struct Input: Equatable {
        var coach: [CoachNote] = []
        var workouts: [Workout] = []
        var sleeps: [Sleep] = []
        var naps: [Nap] = []
        var weights: [Weight] = []
        var dayLogs: [DayLog] = []
        var ecgs: [Ecg] = []
        var notices: [Notice] = []
        /// The day's own close, shown when no evening recap from the coach covers it.
        var dayEnd: DayEnd? = nil
        /// The week in bars on Sunday evening, when no weekly review from the coach covers it.
        var week: Date? = nil
    }

    // MARK: Output

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case coach(CoachNote.Origin)
            case workout
            case wake
            case nap
            case weight
            case dayLog(DayLog.Kind)
            case ecg
            case notice
            case dayEnd
            case walks
            case week
        }
        let id: String
        let date: Date
        let kind: Kind
        /// Coach: the short label the coach put above the note ("After your workout"), if any.
        var kicker: String? = nil
        /// Coach: the first sentence. Others: the event name.
        let title: String
        /// Coach: the rest of the note. Others: a short detail line.
        let detail: String
        let value: Double?
        let sourceId: String?
        /// False for a daily figure: the row shows no time.
        var timed = true
        /// Coach: answers offered under the note.
        var replies: [String] = []
        /// Coach: the workout shown inside this note, instead of as an entry of its own.
        var workoutId: String? = nil
        /// Morning brief: the wake moment of the night shown inside it, instead of as an entry of its own.
        var wake: Date? = nil
        /// Coach: what Today showed when the note was written (`ForgeNoteBasis`).
        var basis: String? = nil
        /// Notice: what it says and where it leads.
        var notice: Notice? = nil
        /// The evening report.
        var dayEnd: DayEnd? = nil
        /// Walks: the bundled walks of the day, earliest first.
        var walkIds: [String] = []
        /// Coach: questions asked under the note and their answers.
        var followUps: [FollowUp] = []
    }

    struct Day: Identifiable, Equatable {
        let id: String          // logical day key
        let date: Date
        let entries: [Entry]
    }

    /// Group `input` into logical days, newest day first and newest entry first within a day.
    ///
    /// One thing happens once: a note written about a workout takes that workout's place, at the moment the
    /// workout ended, and the morning brief takes the place of the night it reads. `dayKey` maps a moment to
    /// its logical day (the app's 04:00 rollover); it is injected so tests can use a fixed calendar. `now`
    /// drops anything in the future and `days` caps how far back the list reaches.
    static func build(_ input: Input, now: Date, days: Int = 2, dayKey: (Date) -> String) -> [Day] {
        var entries: [Entry] = []
        // A night belongs to the day it wakes into, even when it ends before the 04:00 rollover.
        func nightDay(_ wake: Date) -> String { dayKey(wake.addingTimeInterval(nightDayShift)) }
        let shownWorkouts = Dictionary(input.workouts.filter { $0.end <= now }.map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
        let shownWakes = input.sleeps.filter { $0.end <= now }
        var workoutsInNotes = Set<String>()
        var wakesInBriefs = Set<Date>()
        for note in input.coach where note.date <= now {
            let split = splitNote(note.text)
            let workout = note.workoutId.flatMap { shownWorkouts[$0] }
            if let workout { workoutsInNotes.insert(workout.id) }
            var wake: Date?
            if note.origin == .brief,
               let night = shownWakes.first(where: { nightDay($0.end) == dayKey(note.date) && $0.end <= note.date }) {
                wake = night.end
                wakesInBriefs.insert(night.end)
            }
            entries.append(Entry(id: "coach-\(note.id)", date: workout?.end ?? note.date, kind: .coach(note.origin),
                                 kicker: split.kicker, title: split.headline, detail: split.body,
                                 value: nil, sourceId: note.id, replies: note.replies,
                                 workoutId: workout?.id, wake: wake, basis: note.basis,
                                 followUps: note.followUps))
        }
        // Two or more detected or imported walks on a day are one entry; a walk the wearer started stays.
        let bundled = TimelineFeed.walkBundles(
            shownWorkouts.values.filter { !workoutsInNotes.contains($0.id) }
                .map { TimelineFeed.Walk(id: $0.id, start: $0.start, end: $0.end, bundles: $0.bundles) },
            dayKey: dayKey)
        let inBundles = Set(bundled.values.flatMap { $0.map(\.id) })
        for (day, walks) in bundled {
            guard let last = walks.last else { continue }
            entries.append(Entry(id: "walks-\(day)", date: last.end, kind: .walks, title: "", detail: "",
                                 value: walks.reduce(0) { $0 + $1.minutes }, sourceId: nil,
                                 walkIds: walks.map(\.id)))
        }
        for w in shownWorkouts.values where !workoutsInNotes.contains(w.id) && !inBundles.contains(w.id) {
            entries.append(Entry(id: "workout-\(w.id)", date: w.end, kind: .workout, title: w.sport,
                                 detail: "", value: w.effort, sourceId: w.id))
        }
        for s in shownWakes where !wakesInBriefs.contains(s.end) {
            entries.append(Entry(id: "wake-\(Int(s.end.timeIntervalSince1970))", date: s.end, kind: .wake,
                                 title: "", detail: "", value: s.minutesAsleep, sourceId: nil))
        }
        for n in input.naps where n.end <= now {
            entries.append(Entry(id: "nap-\(Int(n.end.timeIntervalSince1970))", date: n.end, kind: .nap,
                                 title: "", detail: "", value: n.minutesAsleep, sourceId: nil))
        }
        for w in input.weights where w.date <= now {
            entries.append(Entry(id: "weight-\(Int(w.date.timeIntervalSince1970))", date: w.date, kind: .weight,
                                 title: "", detail: "", value: w.kg, sourceId: nil, timed: w.timed))
        }
        for log in input.dayLogs where log.date <= now {
            entries.append(Entry(id: "\(log.kind.rawValue)-\(dayKey(log.date))", date: log.date, kind: .dayLog(log.kind),
                                 title: "", detail: "", value: log.value, sourceId: nil, timed: log.timed))
        }
        for e in input.ecgs where e.date <= now {
            entries.append(Entry(id: "ecg-\(e.id)", date: e.date, kind: .ecg, title: "", detail: "",
                                 value: e.averageHr.map(Double.init), sourceId: e.id))
        }
        if let end = input.dayEnd, end.date <= now,
           !input.coach.contains(where: { $0.origin == .evening && dayKey($0.date) == dayKey(end.date) && $0.date <= now }) {
            entries.append(Entry(id: "dayEnd-\(dayKey(end.date))", date: end.date, kind: .dayEnd, title: "",
                                 detail: end.tomorrow ?? "", value: Double(end.sessions), sourceId: nil,
                                 dayEnd: end))
        }
        if let week = input.week, week <= now,
           !input.coach.contains(where: { $0.origin == .weeklyReview && dayKey($0.date) == dayKey(week) && $0.date <= now }) {
            entries.append(Entry(id: "week-\(dayKey(week))", date: week, kind: .week, title: "", detail: "",
                                 value: nil, sourceId: nil))
        }
        for n in input.notices where n.date <= now {
            entries.append(Entry(id: "notice-\(n.key)-\(dayKey(n.date))", date: n.date, kind: .notice,
                                 title: n.headline, detail: n.detail, value: nil, sourceId: n.key, notice: n))
        }

        let keyed = Dictionary(grouping: entries) { entry in
            entry.kind == .wake ? nightDay(entry.date) : dayKey(entry.date)
        }
        let keptKeys = keyed.keys.sorted(by: >).prefix(max(0, days))
        return keptKeys.compactMap { key in
            guard let list = keyed[key], let first = list.first else { return nil }
            let sorted = list.sorted { a, b in
                a.date != b.date ? a.date > b.date : a.id < b.id
            }
            return Day(id: key, date: first.date, entries: sorted)
        }
    }

    // MARK: Blocks (2026-11-07)

    /// How a day's entries are drawn: the morning, the evening, coach notes and notices each on a card of
    /// their own, and runs of small events (a session, walks, a weigh-in, drinks, an ECG, a nap) as rows
    /// sharing one card, so a busy day reads as a few blocks rather than a dozen equal cards.
    enum Block: Identifiable, Equatable {
        case card(Entry)
        case rows([Entry])

        var id: String {
            switch self {
            case .card(let entry): return entry.id
            case .rows(let entries): return "rows-" + (entries.first?.id ?? "")
            }
        }
    }

    static func isRow(_ kind: Entry.Kind) -> Bool {
        switch kind {
        case .workout, .walks, .weight, .dayLog, .ecg, .nap: return true
        case .coach, .wake, .notice, .dayEnd, .week: return false
        }
    }

    /// `entries` in order, with neighbouring small events joined into one block.
    static func blocks(_ entries: [Entry]) -> [Block] {
        var out: [Block] = []
        var run: [Entry] = []
        func flush() {
            if !run.isEmpty { out.append(.rows(run)); run = [] }
        }
        for entry in entries {
            if isRow(entry.kind) {
                run.append(entry)
            } else {
                flush()
                out.append(.card(entry))
            }
        }
        flush()
        return out
    }

    /// Moves a wake moment past the rollover when working out its day; never far enough to reach the next one.
    private static let nightDayShift: TimeInterval = 4 * 3600

    /// Split a coach note into an optional kicker, a headline (its first sentence) and the remaining text.
    ///
    /// Seeded coach turns open with a short label line and a blank line ("Weekly review\n\n…"); that line
    /// becomes the kicker rather than the headline. A sentence ends only at a mark followed by a space or the
    /// end, so "1.7 hours" and "13.2/21" stay whole, and any emphasis it closes stays with it. A first
    /// sentence longer than `maxHeadline` characters is divided at a clause (a dash, colon, semicolon or
    /// comma) and continues in the body; with no clause to divide at it stays whole. Nothing is said twice.
    static func splitNote(_ raw: String, maxHeadline: Int = 90) -> (kicker: String?, headline: String, body: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, "", "") }
        var kicker: String?
        if let gap = text.range(of: "\n\n") {
            let first = text[..<gap.lowerBound].trimmingCharacters(in: .whitespaces)
            if !first.isEmpty, first.count <= 40, !first.contains("\n"),
               first.last.map({ !".!?:".contains($0) }) ?? false {
                kicker = stripEmphasis(first)
                text = String(text[gap.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let lead = String(firstLine.first ?? "").trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        var headline = lead
        var rest = firstLine.count > 1 ? String(firstLine[1]) : ""
        if let end = sentenceEnd(in: lead) {
            headline = String(lead[..<end])
            let remainder = String(lead[end...]).trimmingCharacters(in: .whitespaces)
            rest = [remainder, rest].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        // The headline is plain text; the body keeps the model's emphasis so figures can show in bold.
        headline = stripEmphasis(headline)
        if headline.count > maxHeadline, let clause = clauseBreak(in: headline, limit: maxHeadline) {
            let tail = String(headline[clause.upperBound...]).trimmingCharacters(in: .whitespaces)
            let head = String(headline[..<clause.lowerBound]).trimmingCharacters(in: .whitespaces)
            headline = head + "."
            rest = [tail.prefix(1).uppercased() + tail.dropFirst(), rest].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return (kicker, headline, balancedEmphasis(rest.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// The end of the first sentence, past any emphasis it closes. A full stop inside a number is no end.
    private static func sentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            if ".!?".contains(text[index]) {
                var next = text.index(after: index)
                while next < text.endIndex, text[next] == "*" { next = text.index(after: next) }
                if next == text.endIndex || text[next].isWhitespace { return next }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The last clause break within `limit`, stronger marks first, not so early that the headline says nothing.
    private static func clauseBreak(in text: String, limit: Int) -> Range<String.Index>? {
        let window = text.prefix(limit)
        for mark in [" — ", " – ", "; ", ": ", ", "] {
            if let found = window.range(of: mark, options: .backwards),
               window.distance(from: window.startIndex, to: found.lowerBound) >= 24 {
                return found
            }
        }
        return nil
    }

    /// Emphasis markers that do not pair up would print as asterisks, so they go; pairs stay for the bold.
    private static func balancedEmphasis(_ text: String) -> String {
        let markers = text.components(separatedBy: "**").count - 1
        return markers % 2 == 0 ? text : stripEmphasis(text)
    }

    /// Markdown emphasis markers removed, for text shown plain (headlines, kickers, notifications).
    static func stripEmphasis(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
    }
}

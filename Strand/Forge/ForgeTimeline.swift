import Foundation

/// The redesigned Today timeline (2026-11): one list of what happened, newest first, assembled from data
/// the app already stores. Nothing here is persisted and nothing is derived: every figure is copied from an
/// input that another screen already shows, so the timeline can never disagree with the screen behind it.
///
/// Pure on purpose (no Repository, no SwiftUI) so the ordering, day grouping and text splitting are pinned
/// by `ForgeTimelineTests` without a strap or a database.
enum ForgeTimeline {

    // MARK: Inputs (plain values copied from existing reads)

    struct CoachNote: Equatable {
        enum Origin: String { case brief, checkIn, nudge, weeklyReview }
        let id: String
        let date: Date
        let text: String
        let origin: Origin
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
    }

    struct Sleep: Equatable {
        let start: Date
        let end: Date
        let minutesAsleep: Double?
        /// Rest for that night (0–100), if scored.
        let rest: Double?
    }

    struct Weight: Equatable {
        let date: Date
        let kg: Double
    }

    struct Input: Equatable {
        var coach: [CoachNote] = []
        var workouts: [Workout] = []
        var sleeps: [Sleep] = []
        var weights: [Weight] = []
    }

    // MARK: Output

    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable {
            case coach(CoachNote.Origin)
            case workout
            case wake
            case weight
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
    }

    struct Day: Identifiable, Equatable {
        let id: String          // logical day key
        let date: Date
        let entries: [Entry]
    }

    /// Group `input` into logical days, newest day first and newest entry first within a day.
    ///
    /// `dayKey` maps a moment to its logical day (the app's 04:00 rollover); it is injected so tests can use
    /// a fixed calendar. `now` drops anything in the future and `days` caps how far back the list reaches.
    static func build(_ input: Input, now: Date, days: Int = 2, dayKey: (Date) -> String) -> [Day] {
        var entries: [Entry] = []
        for note in input.coach where note.date <= now {
            let split = splitNote(note.text)
            entries.append(Entry(id: "coach-\(note.id)", date: note.date, kind: .coach(note.origin),
                                 kicker: split.kicker, title: split.headline, detail: split.body,
                                 value: nil, sourceId: note.id))
        }
        for w in input.workouts where w.end <= now {
            entries.append(Entry(id: "workout-\(w.id)", date: w.end, kind: .workout, title: w.sport,
                                 detail: "", value: w.effort, sourceId: w.id))
        }
        for s in input.sleeps where s.end <= now {
            entries.append(Entry(id: "wake-\(Int(s.end.timeIntervalSince1970))", date: s.end, kind: .wake,
                                 title: "", detail: "", value: s.minutesAsleep, sourceId: nil))
        }
        for w in input.weights where w.date <= now {
            entries.append(Entry(id: "weight-\(Int(w.date.timeIntervalSince1970))", date: w.date, kind: .weight,
                                 title: "", detail: "", value: w.kg, sourceId: nil))
        }

        let keyed = Dictionary(grouping: entries, by: { dayKey($0.date) })
        let keptKeys = keyed.keys.sorted(by: >).prefix(max(0, days))
        return keptKeys.compactMap { key in
            guard let list = keyed[key], let first = list.first else { return nil }
            let sorted = list.sorted { a, b in
                a.date != b.date ? a.date > b.date : a.id < b.id
            }
            return Day(id: key, date: first.date, entries: sorted)
        }
    }

    /// Split a coach note into an optional kicker, a headline (its first sentence) and the remaining text.
    ///
    /// Seeded coach turns open with a short label line and a blank line ("Weekly review\n\n…"); that line
    /// becomes the kicker rather than the headline. Markdown emphasis is removed so a headline never shows
    /// asterisks. A first sentence longer than `maxHeadline` characters is cut at the last word boundary
    /// with an ellipsis and the full sentence stays in the body, so nothing the coach said is lost.
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
        if let end = lead.firstIndex(where: { ".!?".contains($0) }) {
            let next = lead.index(after: end)
            headline = String(lead[..<next])
            let remainder = String(lead[next...]).trimmingCharacters(in: .whitespaces)
            rest = [remainder, rest].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        // The headline is plain text; the body keeps the model's emphasis so figures can show in bold.
        headline = stripEmphasis(headline)
        if headline.count > maxHeadline {
            let cut = headline.prefix(maxHeadline)
            let wordEnd = cut.lastIndex(of: " ") ?? cut.endIndex
            let short = String(cut[..<wordEnd]).trimmingCharacters(in: .whitespaces) + "…"
            rest = [headline, rest].filter { !$0.isEmpty }.joined(separator: "\n")
            headline = short
        }
        return (kicker, headline, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Markdown emphasis markers removed, for text shown plain (headlines, kickers, notifications).
    static func stripEmphasis(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
    }
}

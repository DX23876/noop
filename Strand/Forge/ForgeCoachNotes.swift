import Foundation

/// The redesign's proactive coach notes (2026-11, coach phase b): a short note after a workout and an
/// evening recap, on top of the morning brief, check-in, nudges and weekly review that already exist.
///
/// This is the pure policy: which kinds are switched on, the daily budget, quiet hours and the once-per
/// moment stamps. The generation itself is the coach's existing seeded turn (`AICoachEngine`), so a note
/// uses the same consent, model and transcript as every other coach message. Everything stays behind the
/// coach's own master switch.
///
/// Analysis migration required: no. Coach presentation and scheduling only; no derived health value.
enum ForgeCoachNotes {

    enum Kind: String, CaseIterable {
        case afterWorkout, evening

        /// Per-kind switch in UserDefaults. On by default: the coach itself is off by default, and a person
        /// who turned it on asked for it to speak; each kind can be turned off on its own.
        var enabledKey: String { "noop.forge.coachNote.\(rawValue).enabled" }
    }

    /// At most this many coach-initiated messages (brief, check-in, nudge, notes) per logical day. The
    /// weekly review is outside the budget, as agreed.
    static let dailyBudget = 3
    /// No note is generated or announced between these hours (local time).
    static let quietStartHour = 22
    static let quietEndHour = 7
    /// The evening recap is offered from this hour until quiet hours begin.
    static let eveningStartHour = 19
    /// A workout is "just finished" for this long after it ends.
    static let workoutWindow: TimeInterval = 6 * 3600

    static let lastWorkoutNoteKey = "noop.forge.coachNote.lastWorkoutId"
    static let lastEveningDayKey = "noop.forge.coachNote.lastEveningDay"

    static func isEnabled(_ kind: Kind, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: kind.enabledKey) as? Bool ?? true
    }

    static func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= quietStartHour || hour < quietEndHour
    }

    /// Whether a note of `kind` may be generated now.
    ///
    /// - Parameters:
    ///   - initiatedToday: coach-initiated messages already written today (any kind except the weekly
    ///     review), the budget's input.
    static func mayPost(_ kind: Kind, now: Date, enabled: Bool, initiatedToday: Int,
                        calendar: Calendar = .current) -> Bool {
        guard enabled, initiatedToday < dailyBudget, !isQuiet(now, calendar: calendar) else { return false }
        if kind == .evening {
            return calendar.component(.hour, from: now) >= eveningStartHour
        }
        return true
    }

    /// The workout a post-workout note should be about: the newest one that ended within the window and
    /// has not had a note yet. `id` is the caller's stable workout key.
    static func workoutDue<W>(_ workouts: [W], now: Date, lastNotedId: String?,
                              end: (W) -> Date, id: (W) -> String) -> W? {
        let recent = workouts.filter { end($0) <= now && now.timeIntervalSince(end($0)) <= workoutWindow }
        guard let newest = recent.max(by: { end($0) < end($1) }) else { return nil }
        return id(newest) == lastNotedId ? nil : newest
    }

    // MARK: Instructions (the model writes the words; figures come from its tools)

    static func workoutInstruction(sport: String, minutes: Int) -> String {
        """
        The user just finished a workout: \(sport), about \(minutes) minutes. Unprompted, write a short note \
        about it. Use the tools to read the session and today's Charge before saying anything about effort \
        or recovery; never invent a figure. One headline sentence, then at most two short sentences: what \
        stood out and one practical suggestion for the rest of the day. No greeting, no list.
        """
    }

    static func eveningInstruction() -> String {
        """
        It is evening. Unprompted, write a short recap of the user's day. Use the tools to read today's \
        Effort, any workouts and goals progress; never invent a figure. One headline sentence, then at most \
        two short sentences, ending with one concrete point for tonight or tomorrow (for example when to go \
        to bed). No greeting, no list.
        """
    }
}

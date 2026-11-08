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
        case morning, afterWorkout, evening

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
    /// A shorter session gets no note of its own.
    static let minNoteMinutes = 15

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
    ///   - eveningStart: when the evening may begin today (`ForgeToday.eveningStart`); 19:00 when nil.
    static func mayPost(_ kind: Kind, now: Date, enabled: Bool, initiatedToday: Int,
                        eveningStart: Date? = nil, calendar: Calendar = .current) -> Bool {
        guard enabled, initiatedToday < dailyBudget, !isQuiet(now, calendar: calendar) else { return false }
        if kind == .evening {
            if let eveningStart { return now >= eveningStart }
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

    /// A session worth a note: long enough to say something about and not an everyday walk. A walk is a
    /// fact for the timeline; nobody needs a coach's verdict or a rest suggestion for it.
    static func isWorthANote(sport: String, minutes: Int, isDetected: Bool) -> Bool {
        guard !isDetected, minutes >= minNoteMinutes else { return false }
        return !sport.localizedCaseInsensitiveContains("walk")
    }

    // MARK: Instructions (the model writes the words; figures come from its tools)

    /// The whole reply when the coach has nothing new to say. Nothing is posted.
    static let skipWord = "SKIP"

    /// Answers are the model's, written for this one note. A note that asks nothing offers none.
    static let repliesClause = """
    Only if your note asks the user something or offers a real choice, add a last line in exactly this form: \
    REPLIES: first answer | second answer. At most two answers of at most four words each, in the user's \
    language. Otherwise leave that line out.
    """

    /// Every note sits above figures the device fills in, so the words carry no figures of their own: a
    /// number the model writes can be wrong, out of date after a re-score, or on another scale than the
    /// rings (seen in real notes: "HRV 50" over a stored 44, Effort "13.2/21" for a 0 to 100 wearer).
    static let noFiguresClause = """
    Do not write any number, percentage, duration or unit in the note: the screen shows the figures \
    directly under your words. Say what they mean instead ("above your usual", "a short night").
    """

    /// How every note speaks: what helps rather than what was lost, no praise that was not earned, and no
    /// verdict on a single night, which can feed the very worry that spoils the next one.
    static let voiceClause = """
    Say what helps rather than what was lost. No praise unless it was earned, no alarm, and never judge \
    a single night; a pattern over several nights is worth naming, one night is not.
    """

    /// The new design's morning note: the day's one point in a headline and at most two sentences, with
    /// the night and the Charge drivers drawn under it by the device. It replaces both the long brief and
    /// the separate check-in there: one note in the morning, which may ask one thing about yesterday.
    static func morningInstruction(toolsActive: Bool) -> String {
        let read = toolsActive
            ? "You have not been given any of my numbers. First call get_readiness and get_biometric_summary; "
                + "call get_charge_drivers if my Charge is notably high or low, get_sleep_detail if sleep is the "
                + "story, and get_plan_adherence to see whether yesterday's planned session happened."
            : "Use the data above."
        let plan = toolsActive
            ? "Record exactly one session for today with propose_plan (pass zone and duration_min whenever you "
                + "name them), the easy or short option or rest when readiness is low. Do not describe it: the "
                + "screen shows the proposal under your note for me to accept, change or decline. Anything "
                + "already awaiting my decision or committed is recorded; do not propose it again."
            : "Name the kind of session that fits today in a few words; you cannot record it."
        return """
        \(read) Then write my morning note for the Today screen: one headline sentence with the one thing \
        that matters today, then at most two short sentences, under 40 words in all. If yesterday's planned \
        session is still open or was skipped, ask about it once in one of those sentences, reading a skip \
        as information and never as laziness. \(plan) No greeting, no list, no headings, no dashes.

        \(noFiguresClause)

        \(voiceClause)
        """
    }

    static func workoutInstruction(sport: String, minutes: Int, ended: String) -> String {
        """
        The user finished a workout: \(sport), about \(minutes) minutes, ended at \(ended). Unprompted, write \
        a short note about this one session. Use the tools to read it before saying anything about it; never \
        invent a figure. Say what stood out in the session and what it means for their training. Stay on the \
        session: do not bring up sleep or the scores of the day, other notes cover those. One headline \
        sentence, then at most one short sentence, under 30 words in all. No greeting, no list, no dashes.

        \(noFiguresClause)

        \(voiceClause)
        """
    }

    static func eveningInstruction() -> String {
        """
        It is evening. Unprompted, write a short recap of the user's day. Use the tools to read today's \
        Effort, any workouts and goals progress; never invent a figure. One headline sentence, then at most \
        one short sentence ending with one concrete point for tonight or tomorrow, under 30 words in all. \
        No greeting, no list, no dashes.

        \(noFiguresClause)

        \(voiceClause)
        """
    }

    static let lastInlineAnswerKey = "noop.forge.inlineAnswer.last"

    /// Where the answer to "explain this" for one entry on one day is kept.
    static func explanationKey(_ key: String, day: String) -> String { "noop.forge.explain.\(day).\(key)" }

    /// A reply chip under a note, answered under the note.
    static func inlineAnswerInstruction(_ question: String) -> String {
        """
        The user answered your last note with: "\(question)". Reply to that in at most two short sentences, \
        under 35 words, in the user's language. Read data with the tools if you need it; never invent a \
        figure. No greeting, no list, no dashes.

        \(voiceClause)
        """
    }

    /// "Explain this" on one timeline entry, with the figures the device shows beside it.
    static func explainInstruction(title: String, figures: String) -> String {
        """
        The user tapped "explain this" on an entry of their Today screen. The entry: "\(title)". What the \
        screen shows with it: \(figures). Explain in at most two short sentences, under 40 words, what this \
        means for them today and what helps. Read more with the tools only if needed; never invent a figure. \
        No greeting, no list, no dashes.

        \(voiceClause)
        """
    }

    /// Added to every unprompted turn: what the coach has already told the person today. Three notes in a row
    /// about one bad night is the failure this prevents.
    static func alreadySaidClause(_ headlines: [String]) -> String? {
        guard !headlines.isEmpty else { return nil }
        let list = headlines.map { "- \($0)" }.joined(separator: "\n")
        return """
        Earlier today you already told the user:
        \(list)
        Do not repeat any of those points or their topic. If you would only be repeating them, reply with \
        exactly \(skipWord) and nothing else.
        """
    }

    static func isSkip(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == skipWord
    }

    /// Separates the REPLIES line from the note, so it is never shown as text.
    static func splitReplies(_ reply: String) -> (text: String, replies: [String]) {
        var lines = reply.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("REPLIES:") else {
            return (reply.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        lines.removeLast()
        let answers = last.dropFirst("REPLIES:".count).split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), Array(answers.prefix(2)))
    }
}

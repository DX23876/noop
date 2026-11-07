import Foundation
import UserNotifications
import WhoopStore
import StrandCore

/// The redesign's proactive notes (coach phase b, see `ForgeCoachNotes`): one note after a finished
/// workout and one evening recap, written through the same seeded turn as the nudges and the weekly
/// review, so consent, model, transcript and the Stop button all behave the same.
///
/// Analysis migration required: no. Coach messages only.
extension AICoachEngine {

    @MainActor private static var forgeNotesRunning = false

    /// Coach-initiated messages written today (the budget's input). The weekly review does not count.
    func forgeInitiatedToday(now: Date = Date()) -> Int {
        let today = LogicalDay.key(now)
        return conversations.reduce(0) { total, conversation in
            total + conversation.messages.filter {
                $0.role == .assistant && $0.origin.isCoachInitiated && $0.origin != .weeklyReview
                    && LogicalDay.key($0.date) == today
            }.count
        }
    }

    /// Write whichever redesign note is due right now, at most one per call: the morning note, then a note
    /// after a workout, then the evening recap. Called when Today loads.
    @discardableResult
    func runForgeNotesIfDue(workouts: [WorkoutRow], now: Date = Date()) async -> Bool {
        // Never before the person has read the coach's first-use note (what it is, what it sends): the
        // notes are the coach speaking unasked, so they wait for the same acknowledgement the chat does.
        guard CoachFeaturePrefs.isEnabled, proactiveLevel != .off, isConfigured, dataConsent, !sending,
              UserDefaults.standard.bool(forKey: CoachFirstUse.acknowledgedKey),
              !Self.forgeNotesRunning else {
            return false
        }
        // One note run at a time: Today reloads when a note lands and would otherwise start a second run
        // while the first is still finishing.
        Self.forgeNotesRunning = true
        defer { Self.forgeNotesRunning = false }
        let defaults = UserDefaults.standard
        let used = forgeInitiatedToday(now: now)
        // Notes are short; they use the cheap card model rather than the chat model.
        noteTurn = true
        defer { noteTurn = false }

        // The morning note first: the day's first word, once the night has settled. `startBriefIfNeeded`
        // owns the once-a-day stamp and stays silent while the wake time still needs review. It is not
        // announced: whoever wakes opens the app, and a notification each morning would teach to ignore them.
        if ForgeCoachNotes.mayPost(.morning, now: now, enabled: ForgeCoachNotes.isEnabled(.morning),
                                   initiatedToday: used),
           CoachBriefStamp.lastBriefDay() != LogicalDay.key(now) {
            return await startBriefIfNeeded()
        }

        if ForgeCoachNotes.mayPost(.afterWorkout, now: now, enabled: ForgeCoachNotes.isEnabled(.afterWorkout),
                                   initiatedToday: used),
           let workout = ForgeCoachNotes.workoutDue(
               workouts.filter { row in
                   ForgeCoachNotes.isWorthANote(sport: row.sport, minutes: Self.noteMinutes(row),
                                                isDetected: WorkoutSource.classify(row.source) == .detected)
               },
               now: now, lastNotedId: defaults.string(forKey: ForgeCoachNotes.lastWorkoutNoteKey),
               end: { Date(timeIntervalSince1970: TimeInterval($0.endTs)) },
               id: { "\($0.startTs)|\($0.sport)" }) {
            let workoutId = "\(workout.startTs)|\(workout.sport)"
            let ended = Date(timeIntervalSince1970: TimeInterval(workout.endTs)).formatted(date: .omitted, time: .shortened)
            let spoke = await runSeededTurnCancellable(
                instruction: ForgeCoachNotes.workoutInstruction(
                    sport: WorkoutSource.localizedDisplaySport(workout.sport),
                    minutes: Self.noteMinutes(workout), ended: ended),
                prefix: String(localized: "After your workout"),
                stampKey: ForgeCoachNotes.lastWorkoutNoteKey,
                stampValue: workoutId, workoutId: workoutId, origin: .afterWorkout)
            if spoke { announceLatestNote(now: now) }
            return spoke
        }

        if ForgeCoachNotes.mayPost(.evening, now: now, enabled: ForgeCoachNotes.isEnabled(.evening),
                                   initiatedToday: used),
           defaults.string(forKey: ForgeCoachNotes.lastEveningDayKey) != LogicalDay.key(now) {
            let spoke = await runSeededTurnCancellable(
                instruction: ForgeCoachNotes.eveningInstruction(),
                prefix: String(localized: "Evening recap"),
                stampKey: ForgeCoachNotes.lastEveningDayKey, origin: .evening)
            if spoke { announceLatestNote(now: now) }
            return spoke
        }
        return false
    }

    private static func noteMinutes(_ row: WorkoutRow) -> Int {
        Int(((row.durationS ?? Double(row.endTs - row.startTs)) / 60).rounded())
    }

    /// The note just written, as a local notification with its headline. No extra model call: the text
    /// is the transcript's. Only when notifications are already allowed and outside quiet hours.
    private func announceLatestNote(now: Date) {
        guard !ForgeCoachNotes.isQuiet(now),
              let message = conversations.flatMap(\.messages).last(where: { $0.role == .assistant }) else { return }
        let parts = ForgeTimeline.splitNote(message.text)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = parts.kicker ?? String(localized: "Coach")
            content.body = parts.headline
            center.add(UNNotificationRequest(identifier: "forge-coach-note-\(message.id.uuidString)",
                                             content: content, trigger: nil))
        }
    }
}

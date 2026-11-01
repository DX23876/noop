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

    /// Write whichever redesign note is due right now, at most one per call. Called when Today loads, the
    /// same moment the brief and nudges use, so nothing runs in the background.
    @discardableResult
    func runForgeNotesIfDue(workouts: [WorkoutRow], now: Date = Date()) async -> Bool {
        guard CoachFeaturePrefs.isEnabled, proactiveLevel != .off, isConfigured, dataConsent, !sending else {
            return false
        }
        let defaults = UserDefaults.standard
        let used = forgeInitiatedToday(now: now)

        if ForgeCoachNotes.mayPost(.afterWorkout, now: now, enabled: ForgeCoachNotes.isEnabled(.afterWorkout),
                                   initiatedToday: used),
           let workout = ForgeCoachNotes.workoutDue(
               workouts, now: now, lastNotedId: defaults.string(forKey: ForgeCoachNotes.lastWorkoutNoteKey),
               end: { Date(timeIntervalSince1970: TimeInterval($0.endTs)) },
               id: { "\($0.startTs)|\($0.sport)" }) {
            let minutes = Int(((workout.durationS ?? Double(workout.endTs - workout.startTs)) / 60).rounded())
            let spoke = await runSeededTurnCancellable(
                instruction: ForgeCoachNotes.workoutInstruction(
                    sport: WorkoutSource.localizedDisplaySport(workout.sport), minutes: minutes),
                prefix: String(localized: "After your workout"),
                stampKey: ForgeCoachNotes.lastWorkoutNoteKey,
                stampValue: "\(workout.startTs)|\(workout.sport)", origin: .nudge)
            if spoke { announceLatestNote() }
            return spoke
        }

        if ForgeCoachNotes.mayPost(.evening, now: now, enabled: ForgeCoachNotes.isEnabled(.evening),
                                   initiatedToday: used),
           defaults.string(forKey: ForgeCoachNotes.lastEveningDayKey) != LogicalDay.key(now) {
            let spoke = await runSeededTurnCancellable(
                instruction: ForgeCoachNotes.eveningInstruction(),
                prefix: String(localized: "Evening recap"),
                stampKey: ForgeCoachNotes.lastEveningDayKey, origin: .nudge)
            if spoke { announceLatestNote() }
            return spoke
        }
        return false
    }

    /// The note just written, as a local notification with its headline. No extra model call: the text
    /// is the transcript's. Only when notifications are already allowed and outside quiet hours.
    private func announceLatestNote() {
        guard !ForgeCoachNotes.isQuiet(Date()),
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

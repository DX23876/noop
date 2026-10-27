import Foundation

@MainActor
extension GoalMissedQuestions {
    /// Records the answer: the journal entry for a journal-linked goal, the tick for any other goal on yes;
    /// then marks the question answered and refreshes, so streaks and rings take the late tick at once.
    static func answer(_ occurrence: GoalActionOccurrence, yes: Bool, repo: Repository,
                       defaults: UserDefaults = .standard) async {
        if let entry = journalAnswer(occurrence.action.requirement, yes: yes) {
            await repo.saveJournalAnswer(day: occurrence.day, question: entry.question,
                                         answeredYes: entry.answeredYes)
        } else if yes, !GoalActionStore.shared.checkoffs.contains(where: { $0.id == occurrence.id }) {
            GoalActionStore.shared.toggleManual(occurrence.action.id, day: occurrence.day)
        }
        let today = GoalActionEvaluator.dayKey(Date(), calendar: TrainingPreferences.weekCalendar)
        defaults.set(adding(occurrence.id, to: defaults.string(forKey: answeredKey) ?? "", today: today,
                            calendar: TrainingPreferences.weekCalendar), forKey: answeredKey)
        await GoalTrackingStore.shared.refresh(repo: repo)
    }
}

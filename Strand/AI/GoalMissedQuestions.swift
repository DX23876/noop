import Foundation
import WhoopStore

/// The next-day question (goals plan §17j): a daily goal NOOP could not see done is asked about once,
/// "Did you do this yesterday?", for up to three days, then dropped without a word.
///
/// Asked about: boxes ticked by hand, journal-linked goals with nothing logged, and workout goals with
/// no recorded workout (the strap was off, the run was not recorded). Steps, sleep and calories are
/// numbers the wearer cannot recall better than the strap, so a missing reading is never asked about.
enum GoalMissedQuestions {
    /// Answered questions as "<goal id>:<day>" lines. A string so it travels in the goals backup.
    static let answeredKey = "goals.missedAnswered.v1"
    static let lookbackDays = 3

    static func asks(_ requirement: GoalAction.Requirement) -> Bool {
        switch requirement {
        case .manual, .journal, .workout: return true
        case .steps, .sleep, .activeCalories: return false
        }
    }

    /// The open questions among `occurrences`: from the last `lookbackDays` days before today, not done,
    /// of a kind NOOP asks about and not answered yet. Newest day first, goals in their own order. A
    /// journal-linked goal whose entry was logged that day either way is not asked: the entry answered it.
    static func open(_ occurrences: [GoalActionOccurrence], answered: Set<String>, today: String,
                     journalByDay: [String: [JournalEntry]] = [:],
                     calendar: Calendar) -> [GoalActionOccurrence] {
        guard let todayDate = PeriodGoalTracker.date(today, calendar: calendar),
              let earliestDate = calendar.date(byAdding: .day, value: -lookbackDays, to: todayDate) else { return [] }
        let earliest = GoalActionEvaluator.dayKey(earliestDate, calendar: calendar)
        let open = occurrences.filter {
            $0.day < today && $0.day >= earliest && !$0.isCompleted && asks($0.action.requirement)
                && !answered.contains($0.id) && !journalLogged($0, journalByDay)
        }
        // A stable sort keeps the goals' own order within a day.
        return open.enumerated().sorted { a, b in
            a.element.day != b.element.day ? a.element.day > b.element.day : a.offset < b.offset
        }.map(\.element)
    }

    private static func journalLogged(_ occurrence: GoalActionOccurrence,
                                      _ journalByDay: [String: [JournalEntry]]) -> Bool {
        guard case .journal(let question, _) = occurrence.action.requirement else { return false }
        return (journalByDay[occurrence.day] ?? []).contains { $0.question == question }
    }

    /// One question per goal, about its most recent open day; answering it brings up the next one.
    /// `open` is newest first, so the first of each goal is the one to ask.
    static func onePerGoal(_ open: [GoalActionOccurrence]) -> [GoalActionOccurrence] {
        var seen = Set<UUID>()
        return open.filter { seen.insert($0.action.id).inserted }
    }

    /// What an answer writes to the journal for a journal-linked goal, or nil for any other goal. Yes
    /// logs the goal's own answer ("Meditation: yes", "Alcohol: no"); no logs the opposite, so the
    /// journal and everything that reads it agree with the goal (§17j Q3, Q10).
    static func journalAnswer(_ requirement: GoalAction.Requirement, yes: Bool)
        -> (question: String, answeredYes: Bool)? {
        guard case .journal(let question, let wantsYes) = requirement else { return nil }
        return (question, yes ? wantsYes : !wantsYes)
    }

    static func parse(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    /// `raw` with `id` added and answers older than two weeks dropped, so the record stays small.
    static func adding(_ id: String, to raw: String, today: String, calendar: Calendar) -> String {
        let cutoff = PeriodGoalTracker.date(today, calendar: calendar)
            .flatMap { calendar.date(byAdding: .day, value: -14, to: $0) }
            .map { GoalActionEvaluator.dayKey($0, calendar: calendar) } ?? ""
        var lines = parse(raw).filter { line in
            guard let day = line.split(separator: ":").last else { return false }
            return String(day) >= cutoff
        }
        lines.insert(id)
        return lines.sorted().joined(separator: "\n")
    }
}

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

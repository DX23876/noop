import XCTest
import WhoopStore
@testable import Strand

/// Journal-linked daily goals and the next-day question (goals plan §17j).
@MainActor
final class GoalMissedQuestionsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: String) -> Date { PeriodGoalTracker.date(day, calendar: calendar)! }

    private func occurrence(_ action: GoalAction, _ day: String, done: Bool = false) -> GoalActionOccurrence {
        GoalActionOccurrence(action: action, day: day, isCompleted: done, isAutomatic: false)
    }

    // MARK: - Ticked by the journal

    func testAJournalGoalIsDoneOnlyByTheAnswerItWants() {
        let created = date("2026-09-01")
        let meditate = GoalAction(title: "Meditate", requirement: .journal(question: "Did you meditate?", wantsYes: true),
                                  goalIds: [], createdAt: created)
        let noAlcohol = GoalAction(title: "No alcohol",
                                   requirement: .journal(question: "Did you drink any alcohol?", wantsYes: false),
                                   goalIds: [], createdAt: created)
        let journal: [String: [JournalEntry]] = [
            "2026-10-01": [JournalEntry(day: "2026-10-01", question: "Did you meditate?", answeredYes: true, notes: nil),
                           JournalEntry(day: "2026-10-01", question: "Did you drink any alcohol?", answeredYes: true, notes: nil)],
            "2026-10-02": [JournalEntry(day: "2026-10-02", question: "Did you drink any alcohol?", answeredYes: false, notes: nil)],
        ]

        let result = GoalActionEvaluator.occurrences(
            actions: [meditate, noAlcohol], checkoffs: [], activeGoalIds: [], days: [], workouts: [],
            from: date("2026-10-01"), through: date("2026-10-03"), journalByDay: journal, calendar: calendar)
        func done(_ action: GoalAction, _ day: String) -> Bool? {
            result.first { $0.action.id == action.id && $0.day == day }?.isCompleted
        }

        XCTAssertEqual(done(meditate, "2026-10-01"), true)
        XCTAssertEqual(done(noAlcohol, "2026-10-01"), false, "logged yes to alcohol: the avoid goal is missed")
        XCTAssertEqual(done(noAlcohol, "2026-10-02"), true, "logged no: the avoid goal is done")
        XCTAssertEqual(done(meditate, "2026-10-03"), false, "nothing logged is not done")
        XCTAssertEqual(result.first { $0.action.id == meditate.id && $0.day == "2026-10-01" }?.isAutomatic, true)
    }

    // MARK: - Which questions are open

    func testOpenQuestionsCoverThreeDaysBackAndOnlyWhatNOOPCannotSee() {
        let tick = GoalAction(title: "Stretch", requirement: .manual, goalIds: [])
        let run = GoalAction(title: "Run", requirement: .workout(sports: ["Running"], minimumMinutes: nil), goalIds: [])
        let habit = GoalAction(title: "Meditate", requirement: .journal(question: "Did you meditate?", wantsYes: true),
                               goalIds: [])
        let steps = GoalAction(title: "Steps", requirement: .steps(minimum: 10_000), goalIds: [])
        let all = [
            occurrence(tick, "2026-10-04"),              // today: not asked yet
            occurrence(tick, "2026-10-03"),
            occurrence(steps, "2026-10-03"),             // a number: never asked
            occurrence(run, "2026-10-03", done: true),   // done: nothing to ask
            occurrence(habit, "2026-10-02"),
            occurrence(run, "2026-10-01"),
            occurrence(tick, "2026-09-30"),              // four days back: dropped
        ]

        let open = GoalMissedQuestions.open(all, answered: [], today: "2026-10-04", calendar: calendar)
        XCTAssertEqual(open.map(\.id), [tick, habit, run].enumerated().map { index, action in
            "\(action.id.uuidString):\(["2026-10-03", "2026-10-02", "2026-10-01"][index])"
        })

        let answered: Set<String> = ["\(habit.id.uuidString):2026-10-02"]
        XCTAssertEqual(GoalMissedQuestions.open(all, answered: answered, today: "2026-10-04", calendar: calendar).count, 2)
    }

    func testAJournalEntryLoggedEitherWayAnswersTheQuestion() {
        let habit = GoalAction(title: "No alcohol",
                               requirement: .journal(question: "Did you drink any alcohol?", wantsYes: false),
                               goalIds: [])
        let missed = occurrence(habit, "2026-10-03")   // logged yes: missed, but already answered
        let silent = occurrence(habit, "2026-10-02")   // nothing logged: asked
        let journal = ["2026-10-03": [JournalEntry(day: "2026-10-03", question: "Did you drink any alcohol?",
                                                    answeredYes: true, notes: nil)]]

        let open = GoalMissedQuestions.open([missed, silent], answered: [], today: "2026-10-04",
                                            journalByDay: journal, calendar: calendar)

        XCTAssertEqual(open.map(\.day), ["2026-10-02"])
    }

    func testOneQuestionPerGoalStartingWithItsMostRecentDay() {
        let tick = GoalAction(title: "Stretch", requirement: .manual, goalIds: [])
        let run = GoalAction(title: "Run", requirement: .workout(sports: [], minimumMinutes: nil), goalIds: [])
        let open = GoalMissedQuestions.open(
            [occurrence(tick, "2026-10-01"), occurrence(tick, "2026-10-03"), occurrence(run, "2026-10-02")],
            answered: [], today: "2026-10-04", calendar: calendar)

        XCTAssertEqual(GoalMissedQuestions.onePerGoal(open).map(\.id),
                       ["\(tick.id.uuidString):2026-10-03", "\(run.id.uuidString):2026-10-02"])
    }

    // MARK: - What an answer writes

    func testAnAnswerToAJournalGoalWritesTheMatchingEntry() {
        let doIt = GoalAction.Requirement.journal(question: "Did you meditate?", wantsYes: true)
        let avoid = GoalAction.Requirement.journal(question: "Did you drink any alcohol?", wantsYes: false)

        XCTAssertEqual(GoalMissedQuestions.journalAnswer(doIt, yes: true)?.answeredYes, true)
        XCTAssertEqual(GoalMissedQuestions.journalAnswer(doIt, yes: false)?.answeredYes, false)
        XCTAssertEqual(GoalMissedQuestions.journalAnswer(avoid, yes: true)?.answeredYes, false,
                       "yes, I avoided it, logs alcohol: no")
        XCTAssertEqual(GoalMissedQuestions.journalAnswer(avoid, yes: false)?.answeredYes, true)
        XCTAssertNil(GoalMissedQuestions.journalAnswer(.manual, yes: true))
    }

    func testTheAnswerRecordKeepsTwoWeeks() {
        let id = UUID().uuidString
        let raw = ["\(id):2026-09-01", "\(id):2026-09-25"].joined(separator: "\n")

        let updated = GoalMissedQuestions.adding("\(id):2026-10-03", to: raw, today: "2026-10-04", calendar: calendar)

        XCTAssertEqual(GoalMissedQuestions.parse(updated), ["\(id):2026-09-25", "\(id):2026-10-03"])
    }

    // MARK: - Coach

    func testCoachJournalRoutineMustUseAnEntryFromTheJournal() async {
        let suite = "GoalMissed-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let proposals = CoachGoalSetupProposalStore(defaults: defaults, storageKey: "setups")
        let engine = AICoachEngine(repo: Repository(deviceId: "test-goal-journal-\(UUID().uuidString)"))

        let result = await engine.proposeGoalSetupTool(input: [
            "goal": ["kind": "consistency", "title": "Calmer evenings"],
            "routines": [["title": "Meditate", "type": "journal",
                          "journal_question": "Not an entry \(UUID().uuidString)", "supports_setup_goal": true]],
        ], proposalStore: proposals)

        XCTAssertTrue(result.contains("journal_question must be one of"), result)
        XCTAssertTrue(proposals.proposals.isEmpty)
    }
}

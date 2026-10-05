import XCTest
@testable import Strand

/// The goal model + its migration + the feasibility check.
///
/// The property worth defending hardest here is that `.unknown` is a real answer: NOOP says "I can't
/// judge this" wherever it genuinely cannot, instead of producing a confident guess.
@MainActor
final class CoachGoalTests: XCTestCase {

    private func makeDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - Migration

    /// A user who typed a sentence into the old free-text field must not lose it.
    func testLegacyGoalStringMigratesIntoTheNewModel() {
        let d = makeDefaults("test.goal.migrate")
        d.set("Half marathon in October", forKey: CoachGoalStore.legacyGoalKey)

        let store = CoachGoalStore(defaults: d)
        XCTAssertEqual(store.goals.first?.title, "Half marathon in October")
        XCTAssertEqual(store.goals.first?.kind, .custom)
        XCTAssertFalse(store.goals.first?.history.isEmpty ?? true, "the carry-over should be noted in the log")
    }

    /// We deliberately don't parse a date out of the sentence — guessing wrong is worse than asking.
    func testMigrationDoesNotInventATargetDate() {
        let d = makeDefaults("test.goal.migrate.nodate")
        d.set("Half marathon in October", forKey: CoachGoalStore.legacyGoalKey)
        XCTAssertNil(CoachGoalStore(defaults: d).goals.first?.targetDate)
    }

    func testNoLegacyGoalMeansNoGoal() {
        XCTAssertTrue(CoachGoalStore(defaults: makeDefaults("test.goal.none")).goals.isEmpty)
    }

    func testGoalRoundTripsThroughStorage() {
        let d = makeDefaults("test.goal.roundtrip")
        let store = CoachGoalStore(defaults: d)
        store.goals = [CoachGoal(kind: .run, title: "5k", baseline: 2, target: 5,
                                 targetDate: Date().addingTimeInterval(60 * 24 * 3600),
                                 motivation: "private", shareMotivation: false)]

        let reloaded = CoachGoalStore(defaults: d)
        XCTAssertEqual(reloaded.goals.first?.title, "5k")
        XCTAssertEqual(reloaded.goals.first?.kind, .run)
        XCTAssertEqual(reloaded.goals.first?.target, 5)
        XCTAssertEqual(reloaded.goals.first?.motivation, "private")
        XCTAssertEqual(reloaded.goals.first?.shareMotivation, false)
    }

    // MARK: - Goals written by a newer build

    /// A goal as a newer build stores it: a kind this build does not know plus fields it has no property for.
    private let newerBuildGoalJSON = """
    [{"kind":"climbing","title":"Climb 7a","status":"active","grade":"7a",
      "plan":{"sessions":["Mon","Thu"],"weeks":12,"indoor":true,"note":null}},
     {"kind":"weight","title":"Get lighter","baseline":90,"target":80,"status":"active"}]
    """

    /// The goals are read as one array, so one unreadable goal used to empty the whole list.
    func testUnknownKindReadsAsCustomAndKeepsTheOtherGoals() {
        let d = makeDefaults("test.goal.newer.kind")
        d.set(Data(newerBuildGoalJSON.utf8), forKey: CoachGoalStore.goalsKey)

        let store = CoachGoalStore(defaults: d)
        XCTAssertEqual(store.goals.count, 2)
        XCTAssertEqual(store.goals.first?.kind, .custom)
        XCTAssertEqual(store.goals.first?.title, "Climb 7a")
        XCTAssertEqual(store.goals.last?.kind, .weight)
        XCTAssertNil(store.goals.last?.unknownKindRaw)
        XCTAssertTrue(store.goals.last?.unknownFields.isEmpty ?? false)
    }

    /// A save from this build must write the newer build's kind and fields back unchanged, or installing
    /// the newer build again would find them gone.
    func testSaveWritesTheNewerBuildsKindAndFieldsBack() throws {
        let d = makeDefaults("test.goal.newer.save")
        d.set(Data(newerBuildGoalJSON.utf8), forKey: CoachGoalStore.goalsKey)
        let store = CoachGoalStore(defaults: d)
        store.note(store.goals[0].id, "Touched by an older build")

        let saved = try XCTUnwrap(d.data(forKey: CoachGoalStore.goalsKey))
        let goals = try XCTUnwrap(try JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        let first = try XCTUnwrap(goals.first)
        XCTAssertEqual(first["kind"] as? String, "climbing")
        XCTAssertEqual(first["grade"] as? String, "7a")
        let plan = try XCTUnwrap(first["plan"] as? [String: Any])
        XCTAssertEqual(plan["sessions"] as? [String], ["Mon", "Thu"])
        XCTAssertEqual(plan["weeks"] as? Double, 12)
        XCTAssertEqual(plan["indoor"] as? Bool, true)
        XCTAssertTrue(plan["note"] is NSNull)
        XCTAssertEqual(goals.last?["kind"] as? String, "weight")
        XCTAssertNil(goals.last?["grade"])
    }

    /// An edit rebuilds the goal from the editor's draft; what the newer build stored must survive it.
    func testEditKeepsWhatTheNewerBuildStored() {
        let d = makeDefaults("test.goal.newer.edit")
        d.set(Data(newerBuildGoalJSON.utf8), forKey: CoachGoalStore.goalsKey)
        let store = CoachGoalStore(defaults: d)
        let id = store.goals[0].id

        store.commit(CoachGoal(kind: .custom, title: "Climb 7b"), editingId: id)

        let edited = store.goal(id: id)
        XCTAssertEqual(edited?.title, "Climb 7b")
        XCTAssertEqual(edited?.unknownKindRaw, "climbing")
        XCTAssertEqual(edited?.unknownFields["grade"], .string("7a"))
    }

    // MARK: - Derived

    func testWeeksRemainingGoesNegativeAfterTheDate() {
        let goal = CoachGoal(targetDate: Date().addingTimeInterval(-14 * 24 * 3600))
        XCTAssertLessThan(goal.weeksRemaining() ?? 0, 0,
                          "a passed date must read as passed, not as zero")
    }

    /// The phase heuristic is a coarse convention for performance goals only — it would be meaningless
    /// on a "sleep better" goal, so it isn't offered there.
    func testPhaseOnlyAppliesToPerformanceGoals() {
        let run = CoachGoal(kind: .run, targetDate: Date().addingTimeInterval(60 * 24 * 3600))
        XCTAssertEqual(run.phase(), "build")

        let sleep = CoachGoal(kind: .sleep, targetDate: Date().addingTimeInterval(60 * 24 * 3600))
        XCTAssertNil(sleep.phase())
    }

    func testPhaseTapersCloseToTheDate() {
        let goal = CoachGoal(kind: .run, targetDate: Date().addingTimeInterval(7 * 24 * 3600))
        XCTAssertEqual(goal.phase(), "taper")
    }

    // MARK: - Feasibility

    func testRunGoalWithinReachIsSupported() {
        let goal = CoachGoal(kind: .run, title: "5k", target: 5,
                             targetDate: Date().addingTimeInterval(60 * 24 * 3600))
        let a = GoalFeasibility.assess(goal: goal,
                                       evidence: .init(longestRecentRunKm: 3))
        XCTAssertEqual(a.verdict, .supported)
    }

    /// The backstop case: a target far past anything the user has ever done gets a plain no — and,
    /// crucially, a concrete alternative rather than just a refusal.
    func testRunGoalFarBeyondTheEvidenceIsUnrealisticAndSuggestsAnAlternative() {
        let goal = CoachGoal(kind: .run, title: "Marathon", target: 42,
                             targetDate: Date().addingTimeInterval(28 * 24 * 3600))
        let a = GoalFeasibility.assess(goal: goal, evidence: .init(longestRecentRunKm: 5))
        XCTAssertEqual(a.verdict, .unrealistic)
        XCTAssertNotNil(a.suggestion, "an unrealistic verdict must always offer what IS reachable")
    }

    /// No running history is NOT a no — it's an honest "I can't tell yet".
    func testRunGoalWithoutEvidenceIsUnknownNotNegative() {
        let goal = CoachGoal(kind: .run, title: "5k", target: 5,
                             targetDate: Date().addingTimeInterval(60 * 24 * 3600))
        let a = GoalFeasibility.assess(goal: goal, evidence: .init())
        XCTAssertEqual(a.verdict, .unknown)
        XCTAssertNil(a.suggestion)
    }

    /// NOOP has no nutrition data, so it declines to judge whether a weight goal lands — the pace is
    /// still checked, but by the safety gate, which is the honest place for it.
    func testWeightGoalFeasibilityIsAlwaysUnknown() {
        let goal = CoachGoal(kind: .weight, title: "Weight", baseline: 80, target: 70,
                             targetDate: Date().addingTimeInterval(90 * 24 * 3600))
        XCTAssertEqual(GoalFeasibility.assess(goal: goal, evidence: .init()).verdict, .unknown)
    }

    /// Strength isn't measurable from the strap, so the coach holds the goal without pretending to
    /// track it.
    func testStrengthGoalIsUnknown() {
        let goal = CoachGoal(kind: .strength, title: "Bench 100kg",
                             targetDate: Date().addingTimeInterval(90 * 24 * 3600))
        XCTAssertEqual(GoalFeasibility.assess(goal: goal, evidence: .init()).verdict, .unknown)
    }

    func testGoalWithoutDateIsUnknown() {
        let goal = CoachGoal(kind: .run, title: "5k", target: 5, targetDate: nil)
        XCTAssertEqual(GoalFeasibility.assess(goal: goal, evidence: .init(longestRecentRunKm: 3)).verdict,
                       .unknown)
    }

    func testBigConsistencyJumpIsAmbitious() {
        let goal = CoachGoal(kind: .consistency, title: "Train often", baseline: 1, target: 6,
                             targetDate: Date().addingTimeInterval(60 * 24 * 3600))
        let a = GoalFeasibility.assess(goal: goal, evidence: .init(sessionsPerWeek: 1))
        XCTAssertEqual(a.verdict, .ambitious)
    }
}

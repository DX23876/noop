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
        XCTAssertEqual(store.goal?.title, "Half marathon in October")
        XCTAssertEqual(store.goal?.kind, .custom)
        XCTAssertFalse(store.goal?.history.isEmpty ?? true, "the carry-over should be noted in the log")
    }

    /// We deliberately don't parse a date out of the sentence — guessing wrong is worse than asking.
    func testMigrationDoesNotInventATargetDate() {
        let d = makeDefaults("test.goal.migrate.nodate")
        d.set("Half marathon in October", forKey: CoachGoalStore.legacyGoalKey)
        XCTAssertNil(CoachGoalStore(defaults: d).goal?.targetDate)
    }

    func testNoLegacyGoalMeansNoGoal() {
        XCTAssertNil(CoachGoalStore(defaults: makeDefaults("test.goal.none")).goal)
    }

    func testGoalRoundTripsThroughStorage() {
        let d = makeDefaults("test.goal.roundtrip")
        let store = CoachGoalStore(defaults: d)
        store.goal = CoachGoal(kind: .run, title: "5k", baseline: 2, target: 5,
                               targetDate: Date().addingTimeInterval(60 * 24 * 3600),
                               motivation: "private", shareMotivation: false)

        let reloaded = CoachGoalStore(defaults: d)
        XCTAssertEqual(reloaded.goal?.title, "5k")
        XCTAssertEqual(reloaded.goal?.kind, .run)
        XCTAssertEqual(reloaded.goal?.target, 5)
        XCTAssertEqual(reloaded.goal?.motivation, "private")
        XCTAssertEqual(reloaded.goal?.shareMotivation, false)
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

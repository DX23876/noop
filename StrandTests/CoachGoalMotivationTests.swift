import XCTest
@testable import Strand

/// Pins the P8 goal additions: structured motivation tags (8.4), the new held goal kinds (8.2), and
/// that the structured WHY reaches the coach context so it can personalise (15.2).
@MainActor
final class CoachGoalMotivationTests: XCTestCase {

    // MARK: - Structured motivation (8.4) persistence

    func testMotivationTagsSurviveEncodingRoundTrip() throws {
        let goal = CoachGoal(kind: .sleep, title: "Sleep 7.5h",
                             motivationTags: [.moreEnergy, .lessExhausted])
        let data = try JSONEncoder().encode(goal)
        let back = try JSONDecoder().decode(CoachGoal.self, from: data)
        XCTAssertEqual(back.motivationTags, [.moreEnergy, .lessExhausted])
    }

    /// A goal stored before motivation tags existed decodes with an empty list, not a failure.
    func testGoalWithoutMotivationTagsDecodesToEmpty() throws {
        let legacyJSON = #"{"id":"\#(UUID().uuidString)","kind":"sleep","title":"Sleep better","status":"active","motivation":"","shareMotivation":false,"createdAt":0,"history":[]}"#
        let back = try JSONDecoder().decode(CoachGoal.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(back.motivationTags, [])
        XCTAssertEqual(back.title, "Sleep better")
    }

    // MARK: - New held kinds (8.2)

    func testStressAndRecoveryAreHeldNotQuantified() {
        XCTAssertFalse(CoachGoal.Kind.stress.isQuantified)
        XCTAssertFalse(CoachGoal.Kind.recovery.isQuantified)
        XCTAssertEqual(CoachGoal.Kind.stress.unit, "")
        // Every kind has a non-empty label, blurb and icon (the cards render all of them).
        for k in CoachGoal.Kind.allCases {
            XCTAssertFalse(k.label.isEmpty)
            XCTAssertFalse(k.blurb.isEmpty)
            XCTAssertFalse(k.icon.isEmpty)
        }
    }

    /// A non-quantified goal (stress) is judged `.unknown` by feasibility and unflagged by the safety
    /// gate — the same honest "I can hold it, I can't measure it" handling strength/custom already get.
    func testStressGoalIsHeldNotJudged() {
        let goal = CoachGoal(kind: .stress, title: "Bring my stress down")
        let feas = GoalFeasibility.assess(goal: goal, evidence: GoalFeasibility.Evidence())
        XCTAssertEqual(feas.verdict, .unknown)
        let safety = GoalSafetyGate.assess(goal: goal, bodyWeightKg: 75)
        XCTAssertNil(safety.warning, "a held goal has no rate to flag")
    }

    // MARK: - 15.2: the structured WHY reaches the coach

    func testMotivationTagsAppearInTheGoalContextWithoutNeedingShareMotivation() {
        CoachGoalStore.shared.goals = [CoachGoal(kind: .sleep, title: "Sleep 7.5h",
                                                 motivationTags: [.moreEnergy, .feelHealthier],
                                                 shareMotivation: false)]
        defer { CoachGoalStore.shared.goals = [] }

        let engine = AICoachEngine(repo: Repository(deviceId: "test-goal-motivation-\(UUID().uuidString)"))
        let ctx = engine.buildContext()
        XCTAssertTrue(ctx.contains("What they're after"),
                      "the structured why must reach the coach even without sharing the private prose")
        XCTAssertTrue(ctx.contains("More energy"))
        XCTAssertTrue(ctx.contains("Feel healthier"))
    }

    /// The intimate free-text motivation still requires the explicit opt-in — unchanged by the tags.
    func testFreeTextMotivationStillRequiresShareOptIn() {
        CoachGoalStore.shared.goals = [CoachGoal(kind: .sleep, title: "Sleep 7.5h",
                                                 motivation: "So I can keep up with my kids",
                                                 shareMotivation: false)]
        defer { CoachGoalStore.shared.goals = [] }

        let engine = AICoachEngine(repo: Repository(deviceId: "test-goal-freetext-\(UUID().uuidString)"))
        XCTAssertFalse(engine.buildContext().contains("keep up with my kids"),
                       "the private prose must stay off the wire until the user opts in")
    }
}

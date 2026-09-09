import XCTest
import StrandAnalytics
@testable import Strand

/// Pins the weekly-hard-sets goal kind.
///
/// The reason this kind exists at all is a migration hazard, and the first test holds it: an existing
/// strength goal carries a target in MINUTES per week, so reading that same stored number as SETS would
/// silently redefine someone's goal on the next launch. Two kinds means an old goal keeps meaning what
/// it meant, and the tests below make that structural rather than a comment.
///
/// The rest hold the same restraint the other goal kinds do — a verdict only where there is evidence
/// for one, and a warning that warns rather than blocks.
final class HardSetsGoalTests: XCTestCase {

    private func goal(baseline: Double?, target: Double?, weeks: Double,
                      kind: CoachGoal.Kind = .hardSets) -> CoachGoal {
        CoachGoal(kind: kind, title: "Sets", baseline: baseline, target: target,
                  targetDate: Date().addingTimeInterval(weeks * 7 * 86_400))
    }

    // MARK: - The kinds stay apart

    /// The two strength kinds carry DIFFERENT units, and neither reads the other's target.
    func testTheTwoStrengthKindsAreMeasuredInDifferentUnits() {
        XCTAssertEqual(CoachGoal.Kind.strength.unit, "min/week")
        XCTAssertEqual(CoachGoal.Kind.hardSets.unit, "sets/week")
        XCTAssertNotEqual(CoachGoal.Kind.strength, CoachGoal.Kind.hardSets)
    }

    /// Activity minutes are held, not judged — nothing about time in a gym says anyone got stronger.
    /// A set count IS judged: it is a countable rate against a target the wearer chose.
    func testOnlyTheSetCountIsQuantified() {
        XCTAssertFalse(CoachGoal.Kind.strength.isQuantified)
        XCTAssertTrue(CoachGoal.Kind.hardSets.isQuantified)
    }

    // MARK: - Feasibility

    /// With no lifting log there is no verdict — and the rationale says which piece is missing rather
    /// than reporting the goal as unreachable.
    func testWithoutALiftingLogThereIsNoVerdict() {
        let assessment = GoalFeasibility.assess(goal: goal(baseline: 10, target: 16, weeks: 8),
                                                evidence: GoalFeasibility.Evidence())
        XCTAssertEqual(assessment.verdict, .unknown)
        XCTAssertTrue(assessment.rationale.lowercased().contains("lifting log"))
    }

    /// An ordinary progression is supported.
    func testAnOrdinaryProgressionIsSupported() {
        let evidence = GoalFeasibility.Evidence(hardSetsPerWeek: 12)
        let assessment = GoalFeasibility.assess(goal: goal(baseline: 12, target: 15, weeks: 10),
                                                evidence: evidence)
        XCTAssertEqual(assessment.verdict, .supported)
    }

    /// A target well above the wearer's own average reads as ambitious — as a MULTIPLE of what they
    /// already do, because "ten more sets" means something different at eight than at thirty.
    func testAStepChangeInVolumeReadsAsAmbitious() {
        let evidence = GoalFeasibility.Evidence(hardSetsPerWeek: 8)
        let assessment = GoalFeasibility.assess(goal: goal(baseline: 8, target: 20, weeks: 10),
                                                evidence: evidence)
        XCTAssertEqual(assessment.verdict, .ambitious)
    }

    /// The same absolute jump from a bigger base is NOT ambitious — which is the whole point of using a
    /// multiple rather than a fixed number of sets.
    func testTheSameJumpFromABiggerBaseIsFine() {
        let evidence = GoalFeasibility.Evidence(hardSetsPerWeek: 30)
        let assessment = GoalFeasibility.assess(goal: goal(baseline: 30, target: 42, weeks: 10),
                                                evidence: evidence)
        XCTAssertEqual(assessment.verdict, .supported)
    }

    // MARK: - The rate gate

    /// A steep weekly ramp warns, reports the rate, and does NOT block: the goal is still saveable, and
    /// a deliberate overreach is the user's call.
    func testASteepRampWarnsWithoutBlocking() {
        let assessment = GoalSafetyGate.assess(goal: goal(baseline: 10, target: 30, weeks: 4),
                                               bodyWeightKg: 80)
        XCTAssertEqual(assessment.verdict, .veryAggressive)
        XCTAssertNotNil(assessment.warning)
        XCTAssertEqual(try XCTUnwrap(assessment.ratePerWeek), 5, accuracy: 1e-9)
    }

    /// A gentle build is fine and says nothing — silence is the correct output when there is nothing to
    /// flag.
    func testAGentleBuildIsSilent() {
        let assessment = GoalSafetyGate.assess(goal: goal(baseline: 20, target: 23, weeks: 4),
                                               bodyWeightKg: 80)
        XCTAssertEqual(assessment.verdict, .ok)
        XCTAssertNil(assessment.warning)
    }

    /// Scaling volume DOWN carries no progression risk and must never warn — a deload is not a hazard.
    func testCuttingVolumeNeverWarns() {
        let assessment = GoalSafetyGate.assess(goal: goal(baseline: 30, target: 12, weeks: 3),
                                               bodyWeightKg: 80)
        XCTAssertEqual(assessment.verdict, .ok)
        XCTAssertNil(assessment.warning)
    }

    /// From a standing start there is no percentage to take, so the rate gate stays quiet and leaves the
    /// judgement to feasibility — the same carve-out the running-volume check makes.
    func testFromAStandingStartTheRateGateStaysQuiet() {
        let assessment = GoalSafetyGate.assess(goal: goal(baseline: 0, target: 15, weeks: 5),
                                               bodyWeightKg: 80)
        XCTAssertEqual(assessment.verdict, .ok)
    }

    /// The threshold is the SAME number the routine gate uses, read from it rather than copied — one
    /// definition of "that is a step change in volume".
    func testTheJumpThresholdIsSharedWithTheRoutineGate() {
        XCTAssertEqual(GoalFeasibility.hardSetAmbitiousMultiple, StrengthPlanGate.setJumpFactor)
    }
}

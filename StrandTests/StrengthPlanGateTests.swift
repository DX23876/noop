import XCTest
import WhoopStore
@testable import Strand

/// Pins the deterministic check on a coach-drafted routine.
///
/// The governing rule, inherited from `GoalSafetyGate`: **it warns, it does not block.** Every test
/// here that expects a warning also expects the draft to remain perfectly sendable — the gate has no
/// veto, by design. A big jump in volume can be entirely deliberate (a first week back after a deload,
/// a planned overreach, someone returning from a layoff), and refusing those would be both
/// paternalistic and wrong.
///
/// The second rule the tests hold is that every threshold is relative to THIS USER'S OWN history. Ten
/// sets of chest means something different for someone averaging four than for someone averaging
/// eighteen, and NOOP has no evidence about what anyone's correct number is.
final class StrengthPlanGateTests: XCTestCase {

    private func template(_ id: String, _ primary: HevyMuscleGroup) -> HevyExerciseTemplate {
        HevyExerciseTemplate(id: id, title: id, type: "weight_reps", primaryMuscleGroup: primary,
                             secondaryMuscleGroups: [], equipment: .barbell, isCustom: false)
    }

    private var templates: [String: HevyExerciseTemplate] {
        ["T1": template("T1", .chest), "T2": template("T2", .quadriceps)]
    }

    private func proposal(_ templateId: String = "T1", sets: Int,
                          weightKg: Double? = nil,
                          title: String = "Bench Press") -> HevyRoutineProposal {
        HevyRoutineProposal(
            operation: .create, title: "Draft",
            exercises: [HevyRoutineDraftExercise(
                templateId: templateId, title: title,
                sets: (0..<sets).map { _ in
                    HevyRoutineDraftSet(type: .normal, weightKg: weightKg, reps: 5)
                })],
            rationale: "")
    }

    /// Four weeks of history — enough for the gate to run.
    private func history(chestSets: Int = 40, bestBenchE1RM: Double? = nil) -> StrengthPlanGate.History {
        StrengthPlanGate.History(
            setsByMuscle: [.chest: chestSets],
            weeks: 4,
            bestE1RMByTemplate: bestBenchE1RM.map { ["T1": $0] } ?? [:])
    }

    // MARK: - Volume

    /// Ten sets against an average of ten is ordinary. A gate that fires on this teaches people to
    /// ignore it, which costs more than it saves.
    func testAnOrdinaryWeekDrawsNoWarning() {
        let warnings = StrengthPlanGate.warnings(
            for: proposal(sets: 10), templates: templates, history: history(chestSets: 40))
        XCTAssertTrue(warnings.isEmpty, "10 sets against an average of 10 is not a step change")
    }

    /// The normal progression step — a set or two more than usual — is not a warning either. This is
    /// the case a naive "more than last week" check would get wrong every single week.
    func testAddingASetOrTwoIsNotAWarning() {
        let warnings = StrengthPlanGate.warnings(
            for: proposal(sets: 12), templates: templates, history: history(chestSets: 40))
        XCTAssertTrue(warnings.isEmpty, "12 against 10 is progression, not a jump")
    }

    /// A genuine step change is named, with both numbers, so the reader can judge it themselves.
    func testADoublingIsFlaggedWithBothNumbers() throws {
        let warnings = StrengthPlanGate.warnings(
            for: proposal(sets: 20), templates: templates, history: history(chestSets: 40))
        XCTAssertEqual(warnings.count, 1)
        let text = try XCTUnwrap(warnings.first)
        XCTAssertTrue(text.contains("20"), "the prescribed number is missing: \(text)")
        XCTAssertTrue(text.contains("10"), "the user's own average is missing: \(text)")
    }

    /// Small absolute counts are exempt from the ratio. Going from one set to three is 3×, and also
    /// completely unremarkable — without a floor the gate would fire on noise.
    func testASmallAbsoluteCountIsNotFlaggedEvenAtALargeMultiple() {
        let warnings = StrengthPlanGate.warnings(
            for: proposal(sets: 4), templates: templates,
            history: StrengthPlanGate.History(setsByMuscle: [.chest: 4], weeks: 4,
                                              bestE1RMByTemplate: [:]))
        XCTAssertTrue(warnings.isEmpty, "1/week → 4/week is a 4× jump and still trivial")
    }

    /// The frequency the user states multiplies the per-session sets. A routine of six sets run three
    /// times a week is eighteen, and judging it as six would miss the thing worth mentioning.
    func testWeeklyFrequencyMultipliesThePrescribedSets() {
        let single = StrengthPlanGate.warnings(
            for: proposal(sets: 7), templates: templates, history: history(chestSets: 40),
            weeklyFrequency: 1)
        XCTAssertTrue(single.isEmpty)

        let thrice = StrengthPlanGate.warnings(
            for: proposal(sets: 7), templates: templates, history: history(chestSets: 40),
            weeklyFrequency: 3)
        XCTAssertEqual(thrice.count, 1, "21 sets a week against an average of 10 is a step change")
    }

    /// Warmups are not volume. A routine padded with warmup sets must not be flagged for them.
    func testWarmupsDoNotCountTowardTheVolumeCheck() {
        let padded = HevyRoutineProposal(
            operation: .create, title: "Draft",
            exercises: [HevyRoutineDraftExercise(
                templateId: "T1", title: "Bench",
                sets: (0..<10).map { i in
                    HevyRoutineDraftSet(type: i < 8 ? .warmup : .normal, weightKg: 60, reps: 8)
                })],
            rationale: "")
        XCTAssertTrue(StrengthPlanGate.warnings(for: padded, templates: templates,
                                                history: history(chestSets: 40)).isEmpty)
    }

    // MARK: - Load

    /// A load above the user's own estimated maximum is worth a look — and the wording has to say the
    /// comparison is against an ESTIMATE, because it is: an Epley projection from their working sets,
    /// not a max they ever attempted.
    func testALoadAboveTheEstimatedMaxIsFlaggedAsAnEstimate() throws {
        let warnings = StrengthPlanGate.warnings(
            for: proposal(sets: 3, weightKg: 130), templates: templates,
            history: history(chestSets: 40, bestBenchE1RM: 120))
        XCTAssertEqual(warnings.count, 1)
        let text = try XCTUnwrap(warnings.first)
        XCTAssertTrue(text.lowercased().contains("estimated"),
                      "the caveat that this is a projection is missing: \(text)")
    }

    func testALoadBelowTheEstimatedMaxIsNotFlagged() {
        XCTAssertTrue(StrengthPlanGate.warnings(
            for: proposal(sets: 3, weightKg: 100), templates: templates,
            history: history(chestSets: 40, bestBenchE1RM: 120)).isEmpty)
    }

    /// With no e1RM history for a movement there is nothing to compare against, and the gate says
    /// nothing rather than inventing a ceiling.
    func testNoEstimateForAMovementMeansNoLoadWarning() {
        XCTAssertTrue(StrengthPlanGate.warnings(
            for: proposal(sets: 3, weightKg: 300), templates: templates,
            history: history(chestSets: 40, bestBenchE1RM: nil)).isEmpty)
    }

    // MARK: - Thin history

    /// With too little history the gate is SILENT, not cautious-by-default. Any "unusual" verdict drawn
    /// from a week and a half is a statement about the data's thinness dressed up as one about the
    /// plan — and a warning that fires on every new user is one nobody reads by their third week.
    func testAThinHistoryProducesNoWarningsAtAll() {
        let thin = StrengthPlanGate.History(setsByMuscle: [.chest: 4], weeks: 1,
                                            bestE1RMByTemplate: ["T1": 100])
        XCTAssertTrue(StrengthPlanGate.warnings(for: proposal(sets: 30, weightKg: 200),
                                                templates: templates, history: thin).isEmpty)
    }

    /// A muscle group the user has never trained has no average to compare against, so no jump can be
    /// measured. Silence, not a warning that every first leg day would trigger.
    func testAnUntrainedMuscleGroupDrawsNoVolumeWarning() {
        XCTAssertTrue(StrengthPlanGate.warnings(
            for: proposal("T2", sets: 20), templates: templates,
            history: history(chestSets: 40)).isEmpty)
    }

    /// An exercise missing from the catalogue cannot be attributed to a muscle, so it contributes to no
    /// tally — and, correctly, produces no warning rather than a wrong one.
    func testAnUnknownExerciseIsNotAttributedToAnyMuscle() {
        XCTAssertTrue(StrengthPlanGate.warnings(
            for: proposal("NOT-IN-CATALOGUE", sets: 30), templates: templates,
            history: history(chestSets: 40)).isEmpty)
    }

    // MARK: - Building the history

    /// The history comes from the user's own recent sessions, and stops at the window edge — an old
    /// training block must not set the bar for what counts as normal today.
    func testHistoryIsBuiltFromTheWindowOnly() throws {
        let now = Date()
        let nowTs = Int(now.timeIntervalSince1970)
        func session(daysAgo: Int, sets: Int) -> HevyWorkout {
            HevyWorkout(id: "w\(daysAgo)", title: "", routineId: nil, notes: nil,
                        startTs: nowTs - daysAgo * 86_400, endTs: nowTs - daysAgo * 86_400 + 3600,
                        updatedAtTs: nowTs, createdAtTs: nowTs,
                        exercises: [HevyExercise(index: 0, title: "Bench", templateId: "T1",
                                                 supersetId: nil, notes: nil,
                                                 sets: (0..<sets).map {
                            HevySet(index: $0, type: .normal, weightKg: 100, reps: 5,
                                    distanceM: nil, durationS: nil, rpe: nil, customMetric: nil)
                        })])
        }
        let built = StrengthPlanGate.history(
            from: [session(daysAgo: 3, sets: 5), session(daysAgo: 60, sets: 40)],
            templates: templates, windowDays: 28, now: now)

        XCTAssertEqual(built.setsByMuscle[.chest], 5, "the 60-day-old block is outside the window")
        let best = try XCTUnwrap(built.bestE1RMByTemplate["T1"])
        XCTAssertEqual(best, 100 * (1 + 5.0 / 30.0), accuracy: 1e-9)
    }
}

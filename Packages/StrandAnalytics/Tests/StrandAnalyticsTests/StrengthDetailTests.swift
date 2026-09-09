import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the session breakdown and the bodyweight pricing.
///
/// The breakdown itself is mostly transcription, and its tests say so: warmups stay VISIBLE but are not
/// counted, supersets group without merging, an unresolved exercise keeps its sets and loses only its
/// muscle. The bodyweight tests hold the boundary that matters — the new figure must never leak into
/// `volumeLoadKg`, and it must be absent rather than guessed when nobody has weighed themselves.
final class StrengthDetailTests: XCTestCase {

    private func set(_ index: Int, _ type: HevySetType = .normal,
                     kg: Double? = nil, reps: Int? = nil, rpe: Double? = nil) -> HevySet {
        HevySet(index: index, type: type, weightKg: kg, reps: reps,
                distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
    }

    private func exercise(_ index: Int, _ templateId: String?, _ sets: [HevySet],
                          superset: Int? = nil, title: String = "Move") -> HevyExercise {
        HevyExercise(index: index, title: title, templateId: templateId, supersetId: superset,
                     notes: nil, sets: sets)
    }

    private func workout(_ exercises: [HevyExercise], startTs: Int = 1_788_282_000) -> HevyWorkout {
        HevyWorkout(id: "w1", title: "Session", routineId: nil, notes: nil, startTs: startTs,
                    endTs: startTs + 3600, updatedAtTs: startTs, createdAtTs: startTs,
                    exercises: exercises)
    }

    private func template(_ id: String, type: String, primary: HevyMuscleGroup = .chest,
                          secondary: [HevyMuscleGroup] = []) -> HevyExerciseTemplate {
        HevyExerciseTemplate(id: id, title: id, type: type, primaryMuscleGroup: primary,
                             secondaryMuscleGroups: secondary, equipment: .none, isCustom: false)
    }

    private var catalogue: [String: HevyExerciseTemplate] {
        ["BP": template("BP", type: "weight_reps"),
         "PU": template("PU", type: "bodyweight_reps", primary: .lats),
         "WD": template("WD", type: "weighted_bodyweight", primary: .chest),
         "AP": template("AP", type: "bodyweight_assisted_reps", primary: .lats),
         "PL": template("PL", type: "duration", primary: .abdominals)]
    }

    // MARK: - The breakdown

    /// Warmups are RENDERED but not counted. The point of the detail view is to show what happened;
    /// hiding the ramp would make a session look like it started at its top set.
    func testWarmupsAreShownButNotCounted() {
        let session = workout([exercise(0, "BP", [set(0, .warmup, kg: 40, reps: 10),
                                                  set(1, kg: 100, reps: 5)])])
        let breakdown = StrengthDetail.breakdown(session, templates: catalogue)
        let block = breakdown.exercises[0]
        XCTAssertEqual(block.sets.count, 2)
        XCTAssertEqual(block.sets[0].isWorking, false)
        XCTAssertEqual(block.workingSetCount, 1)
        XCTAssertEqual(block.volumeLoadKg, 500)
        XCTAssertEqual(block.topSetKg, 100)
    }

    /// A superset groups its members and keeps them distinct — they are different movements, so their
    /// sets must not be merged into one block.
    func testSupersetsGroupWithoutMerging() {
        let session = workout([exercise(0, "BP", [set(0, kg: 60, reps: 10)], superset: 1, title: "A"),
                               exercise(1, "PU", [set(0, reps: 8)], superset: 1, title: "B"),
                               exercise(2, "PL", [set(0, reps: nil)], title: "C")])
        let groups = StrengthDetail.breakdown(session, templates: catalogue).groups
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].map(\.title), ["A", "B"])
        XCTAssertEqual(groups[1].map(\.title), ["C"])
    }

    /// An exercise the catalogue cannot resolve keeps every set, and loses only its muscle attribution.
    func testAnUnresolvedExerciseKeepsItsSets() {
        let session = workout([exercise(0, nil, [set(0, kg: 50, reps: 10)])])
        let block = StrengthDetail.breakdown(session, templates: catalogue).exercises[0]
        XCTAssertNil(block.primaryMuscle)
        XCTAssertEqual(block.workingSetCount, 1)
        XCTAssertEqual(block.volumeLoadKg, 500)
        XCTAssertEqual(block.kind, .other)
    }

    // MARK: - Bodyweight

    /// The three bodyweight shapes, priced from a MEASURED body weight.
    func testBodyweightShapesArePricedFromTheMeasuredWeight() throws {
        let session = workout([exercise(0, "PU", [set(0, reps: 10)]),
                               exercise(1, "WD", [set(0, kg: 20, reps: 5)]),
                               exercise(2, "AP", [set(0, kg: 30, reps: 8)])])
        let breakdown = StrengthDetail.breakdown(session, templates: catalogue,
                                                 bodyweightKgAt: { _ in 80 })
        XCTAssertEqual(breakdown.exercises[0].bodyweightVolumeKg, 80 * 10)
        XCTAssertEqual(breakdown.exercises[1].bodyweightVolumeKg, (80 + 20) * 5)
        XCTAssertEqual(breakdown.exercises[2].bodyweightVolumeKg, (80 - 30) * 8)
        XCTAssertEqual(breakdown.bodyweightVolumeKg, 800 + 500 + 400)
    }

    /// Bodyweight volume NEVER enters `volumeLoadKg`. That figure is the app's stable definition of
    /// tonnage and must keep meaning what it meant before body weight was available — otherwise every
    /// historical number on every screen quietly changed.
    func testBodyweightVolumeStaysOutOfVolumeLoad() {
        let session = workout([exercise(0, "PU", [set(0, reps: 10)])])
        let breakdown = StrengthDetail.breakdown(session, templates: catalogue,
                                                 bodyweightKgAt: { _ in 80 })
        XCTAssertEqual(breakdown.summary.volumeLoadKg, 0)
        XCTAssertEqual(breakdown.bodyweightVolumeKg, 800)
    }

    /// With no measured body weight the figure is ABSENT, and the sets it could not price are counted
    /// so the screen can say how much it left out. Nothing is estimated from height or age.
    func testWithoutAMeasuredWeightNothingIsInvented() {
        let session = workout([exercise(0, "PU", [set(0, reps: 10), set(1, reps: 8)])])
        let breakdown = StrengthDetail.breakdown(session, templates: catalogue)
        XCTAssertEqual(breakdown.bodyweightVolumeKg, 0)
        XCTAssertEqual(breakdown.unpricedBodyweightSetCount, 2)
        XCTAssertNil(breakdown.exercises[0].sets[0].bodyweightLoadKg)
    }

    /// Assistance greater than body weight is a logging slip, not a negative load.
    func testAssistanceCannotDriveTheLoadBelowZero() {
        let value = StrengthDetail.bodyweightLoad(
            for: set(0, kg: 200, reps: 5), kind: .assistedBodyweight, bodyweightKg: 80)
        XCTAssertEqual(value, 0)
    }

    /// A session priced at the body that performed it, not at today's. A year-old set must not be
    /// re-priced every time the wearer steps on a scale.
    func testEachSessionIsPricedAtItsOwnBodyWeight() {
        let older = workout([exercise(0, "PU", [set(0, reps: 10)])], startTs: 1_700_000_000)
        let newer = workout([exercise(0, "PU", [set(0, reps: 10)])], startTs: 1_780_000_000)
        let weightAt: (Int) -> Double? = { $0 < 1_750_000_000 ? 90 : 80 }
        XCTAssertEqual(StrengthDetail.breakdown(older, templates: catalogue,
                                                bodyweightKgAt: weightAt).bodyweightVolumeKg, 900)
        XCTAssertEqual(StrengthDetail.breakdown(newer, templates: catalogue,
                                                bodyweightKgAt: weightAt).bodyweightVolumeKg, 800)
    }

    /// Movement kinds come off Hevy's own token, and an unknown one carries no body weight — the
    /// direction that under-reports rather than invents.
    func testUnknownMovementTokensCarryNoBodyweight() {
        let odd = template("XX", type: "some_new_hevy_type")
        XCTAssertEqual(StrengthMovementKind.of(odd), .other)
        XCTAssertFalse(StrengthMovementKind.of(odd).carriesBodyweight)
        XCTAssertNil(StrengthDetail.bodyweightLoad(for: set(0, reps: 5), kind: .other, bodyweightKg: 80))
    }

    /// Density is measured on both sides, and absent for a session too short to divide by.
    func testDensityNeedsADurationToDivideBy() {
        let session = workout([exercise(0, "BP", [set(0, kg: 100, reps: 10)])])   // 1000 kg, 60 min
        let breakdown = StrengthDetail.breakdown(session, templates: catalogue)
        XCTAssertEqual(try XCTUnwrap(breakdown.densityKgPerMinute), 1000.0 / 60, accuracy: 1e-9)
    }
}

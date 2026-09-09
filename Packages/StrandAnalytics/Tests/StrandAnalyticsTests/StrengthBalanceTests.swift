import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the balance readings.
///
/// There is almost no arithmetic here to get wrong, which is the point: the tests are about what the
/// feature refuses to do. No target ratio anywhere, an undefined ratio when a side is empty rather than
/// a large number, and a "usual" band that comes from the wearer's own weeks or does not come at all.
final class StrengthBalanceTests: XCTestCase {

    private func workout(_ id: String, at ts: Int, _ pairs: [(String, Int)],
                         supersetId: Int? = nil) -> HevyWorkout {
        let exercises = pairs.enumerated().map { index, pair in
            HevyExercise(index: index, title: pair.0, templateId: pair.0, supersetId: supersetId,
                         notes: nil,
                         sets: (0..<pair.1).map {
                             HevySet(index: $0, type: .normal, weightKg: 50, reps: 8,
                                     distanceM: nil, durationS: nil, rpe: nil, customMetric: nil)
                         })
        }
        return HevyWorkout(id: id, title: "S", routineId: nil, notes: nil, startTs: ts,
                           endTs: ts + 3600, updatedAtTs: ts, createdAtTs: ts, exercises: exercises)
    }

    private func template(_ id: String, _ primary: HevyMuscleGroup) -> HevyExerciseTemplate {
        HevyExerciseTemplate(id: id, title: id, type: "weight_reps", primaryMuscleGroup: primary,
                             secondaryMuscleGroups: [], equipment: .barbell, isCustom: false)
    }

    private var catalogue: [String: HevyExerciseTemplate] {
        ["BENCH": template("BENCH", .chest), "OHP": template("OHP", .shoulders),
         "ROW": template("ROW", .lats), "CURL": template("CURL", .biceps),
         "SQUAT": template("SQUAT", .quadriceps), "RDL": template("RDL", .hamstrings)]
    }

    private static func ts(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int((f.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) + 43_200
    }

    /// Sets are added up on each side of the axis, and the ratio is the plain quotient.
    func testAxesAddUpTheSetsOnEachSide() throws {
        let readings = StrengthBalance.readings(setsByMuscle: [.chest: 6, .shoulders: 3, .triceps: 3,
                                                              .lats: 6, .biceps: 3])
        let pushPull = try XCTUnwrap(readings.first { $0.axis == .pushPull })
        XCTAssertEqual(pushPull.setsA, 12)
        XCTAssertEqual(pushPull.setsB, 9)
        XCTAssertEqual(try XCTUnwrap(pushPull.ratio), 12.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pushPull.shareA), 12.0 / 21.0, accuracy: 1e-9)
    }

    /// A side with no sets yields NO ratio. "Infinity : 1" is not a large imbalance, it is an
    /// undefined quantity, and the caller is expected to say "no pulling logged" instead.
    func testAnEmptySideYieldsNoRatio() throws {
        let readings = StrengthBalance.readings(setsByMuscle: [.chest: 10])
        let pushPull = try XCTUnwrap(readings.first { $0.axis == .pushPull })
        XCTAssertNil(pushPull.ratio)
        XCTAssertEqual(pushPull.setsA, 10)
        XCTAssertEqual(pushPull.setsB, 0)
    }

    /// An axis with nothing on either side draws nothing at all.
    func testAnEmptyAxisHasNoShare() throws {
        let readings = StrengthBalance.readings(setsByMuscle: [:])
        XCTAssertNil(try XCTUnwrap(readings.first).shareA)
    }

    /// The "usual" band is the wearer's own recent weeks — and needs at least three of them, exactly
    /// like every other typical range in this lane.
    func testTheUsualBandComesFromTheWearersOwnWeeks() throws {
        var workouts: [HevyWorkout] = []
        for week in 0..<4 {
            let day = Self.ts("2026-06-01") + week * 7 * 86_400
            workouts.append(workout("w\(week)", at: day, [("BENCH", 6), ("ROW", 6)]))
        }
        let bands = StrengthBalance.typicalRatios(workouts, templates: catalogue,
                                                  endingBefore: "2026-07-06")
        let pushPull = try XCTUnwrap(bands[.pushPull])
        XCTAssertEqual(pushPull.lowerBound, 1, accuracy: 1e-9)
        XCTAssertEqual(pushPull.upperBound, 1, accuracy: 1e-9)
    }

    /// Two weeks are not a usual. Below three the band is absent rather than drawn from what there is.
    func testTwoWeeksAreNotAUsual() {
        let workouts = [workout("a", at: Self.ts("2026-06-01"), [("BENCH", 6), ("ROW", 6)]),
                        workout("b", at: Self.ts("2026-06-08"), [("BENCH", 6), ("ROW", 6)])]
        XCTAssertTrue(StrengthBalance.typicalRatios(workouts, templates: catalogue,
                                                    endingBefore: "2026-06-22").isEmpty)
    }

    // MARK: - How a set reaches a side

    /// AN ANTAGONIST SUPERSET COUNTS ON BOTH SIDES, exactly as the same work performed separately.
    ///
    /// A superset is a statement about the ORDER things were performed in — `supersetId` groups
    /// exercises for the detail view — and says nothing about what a set trained. Bench and row
    /// alternated back to back are still four pushing sets and four pulling ones, and a reading that
    /// treated the pair as one unit, or cancelled one against the other, would report a perfectly
    /// balanced session as empty.
    func testAnAntagonistSupersetCountsOnBothSides() throws {
        let session = workout("ss", at: Self.ts("2026-06-01"), [("BENCH", 4), ("ROW", 4)], supersetId: 1)
        let tally = StrengthSession.hardSetsByMuscle([session], templates: catalogue).primary
        let pushPull = try XCTUnwrap(StrengthBalance.readings(setsByMuscle: tally)
            .first { $0.axis == .pushPull })
        XCTAssertEqual(pushPull.setsA, 4)
        XCTAssertEqual(pushPull.setsB, 4)
        XCTAssertEqual(try XCTUnwrap(pushPull.ratio), 1, accuracy: 1e-9)

        // And identical to the same two exercises performed as separate blocks.
        let apart = workout("apart", at: Self.ts("2026-06-01"), [("BENCH", 4), ("ROW", 4)])
        let apartTally = StrengthSession.hardSetsByMuscle([apart], templates: catalogue).primary
        XCTAssertEqual(apartTally, tally)
    }

    /// NO NEGATION ANYWHERE: a side is an explicit list of muscle groups, so a group in neither list
    /// counts on NEITHER side rather than falling to the opposite one.
    ///
    /// This is the rule the whole reading rests on. Were "pull" defined as "not push", every ab set,
    /// calf raise and forearm set in the week would silently land on the pulling side and the ratio
    /// would describe something nobody trained.
    func testAGroupInNeitherListCountsOnNeitherSide() throws {
        let templates = catalogue.merging([
            "CRUNCH": template("CRUNCH", .abdominals),
            "CALF": template("CALF", .calves),
        ]) { current, _ in current }
        let session = workout("a", at: Self.ts("2026-06-01"),
                              [("BENCH", 5), ("CRUNCH", 6), ("CALF", 4)])
        let tally = StrengthSession.hardSetsByMuscle([session], templates: templates).primary
        let pushPull = try XCTUnwrap(StrengthBalance.readings(setsByMuscle: tally)
            .first { $0.axis == .pushPull })
        XCTAssertEqual(pushPull.setsA, 5, "only the bench sets are pushing")
        XCTAssertEqual(pushPull.setsB, 0, "abs and calves are not pulling — they are not on this axis")
        XCTAssertEqual(pushPull.total, 5, "the fifteen sets performed are not all on this axis")
        XCTAssertNil(pushPull.ratio, "one empty side is an undefined ratio, not a large one")
    }

    /// A set counts once, on its exercise's PRIMARY muscle. A bench press involves the triceps, and
    /// that involvement must not add a second pushing set — the axis would then count the same work
    /// twice and every push:pull reading would drift with how many secondary muscles a template lists.
    func testSecondaryInvolvementNeverAddsASet() throws {
        let templates = ["BENCH": HevyExerciseTemplate(
            id: "BENCH", title: "BENCH", type: "weight_reps", primaryMuscleGroup: .chest,
            secondaryMuscleGroups: [.triceps, .shoulders], equipment: .barbell, isCustom: false)]
        let session = workout("a", at: Self.ts("2026-06-01"), [("BENCH", 4)])
        let tally = StrengthSession.hardSetsByMuscle([session], templates: templates)
        XCTAssertEqual(tally.primary[.chest], 4)
        XCTAssertEqual(tally.secondary[.triceps], 4, "the involvement is reported…")

        let pushPull = try XCTUnwrap(StrengthBalance.readings(setsByMuscle: tally.primary)
            .first { $0.axis == .pushPull })
        XCTAssertEqual(pushPull.setsA, 4, "…but the axis counts four sets, not eight")
    }

    /// Which side a set lands on follows its PRIMARY muscle, not the exercise's name or equipment. A
    /// triceps pushdown is pushing; a biceps curl is pulling; both are isolation work on a machine or
    /// a dumbbell, and nothing about the movement's name is consulted.
    func testTheSideFollowsThePrimaryMuscleAlone() throws {
        let session = workout("a", at: Self.ts("2026-06-01"), [("OHP", 3), ("CURL", 3)])
        let tally = StrengthSession.hardSetsByMuscle([session], templates: catalogue).primary
        let pushPull = try XCTUnwrap(StrengthBalance.readings(setsByMuscle: tally)
            .first { $0.axis == .pushPull })
        XCTAssertEqual(pushPull.setsA, 3, "shoulders are on the pushing side")
        XCTAssertEqual(pushPull.setsB, 3, "biceps are on the pulling side")
    }

    /// An exercise the catalogue cannot resolve reaches NO side, and is counted as unattributed
    /// instead — the balance must never quietly absorb work it could not identify.
    func testUnattributableWorkReachesNoSide() throws {
        let session = HevyWorkout(
            id: "a", title: "S", routineId: nil, notes: nil, startTs: Self.ts("2026-06-01"),
            endTs: Self.ts("2026-06-01") + 3600, updatedAtTs: 0, createdAtTs: 0,
            exercises: [HevyExercise(index: 0, title: "Mystery Machine", templateId: nil,
                                     supersetId: nil, notes: nil,
                                     sets: (0..<5).map {
                                         HevySet(index: $0, type: .normal, weightKg: 40, reps: 10,
                                                 distanceM: nil, durationS: nil, rpe: nil,
                                                 customMetric: nil)
                                     })])
        let tally = StrengthSession.hardSetsByMuscle([session], templates: catalogue)
        XCTAssertEqual(tally.unattributed, 5)
        XCTAssertTrue(StrengthBalance.readings(setsByMuscle: tally.primary).allSatisfy { $0.total == 0 })
    }

    /// THE DEADLIFT CASE, pinned by name because it is the one that surprises people.
    ///
    /// Hevy files the conventional deadlift under `lower_back`, a group that appears on no axis. Those
    /// sets therefore reach neither side — and the reading has to SAY so, or a week built around heavy
    /// pulling shows a push:pull ratio that never counted them.
    func testDeadliftSetsFallOffTheAxesAndAreReported() throws {
        let templates = catalogue.merging([
            "DL": template("DL", .lowerBack),
            "CRUNCH": template("CRUNCH", .abdominals),
        ]) { current, _ in current }
        let session = workout("a", at: Self.ts("2026-06-01"),
                              [("BENCH", 4), ("ROW", 4), ("DL", 5), ("CRUNCH", 3)])
        let tally = StrengthSession.hardSetsByMuscle([session], templates: templates).primary

        let pushPull = try XCTUnwrap(StrengthBalance.readings(setsByMuscle: tally)
            .first { $0.axis == .pushPull })
        XCTAssertEqual(pushPull.setsA, 4)
        XCTAssertEqual(pushPull.setsB, 4, "the deadlift is NOT counted as pulling")

        let off = StrengthBalance.setsOffAxis(setsByMuscle: tally)
        XCTAssertEqual(off.sets, 8, "five deadlift sets and three ab sets reach no axis")
        XCTAssertEqual(Set(off.groups), [.lowerBack, .abdominals])
    }

    /// A week whose every set sits on an axis reports nothing off-axis — the line only appears when
    /// there is something it would otherwise have hidden.
    func testAFullyCoveredWeekReportsNothingOffAxis() {
        let session = workout("a", at: Self.ts("2026-06-01"), [("BENCH", 4), ("ROW", 4), ("SQUAT", 4)])
        let tally = StrengthSession.hardSetsByMuscle([session], templates: catalogue).primary
        XCTAssertEqual(StrengthBalance.setsOffAxis(setsByMuscle: tally).sets, 0)
    }

    /// The untrained list names muscles, not Hevy's catch-all buckets — otherwise every reader's list
    /// is permanently three entries long and says nothing.
    func testTheUntrainedListLeavesOutTheCatchAllBuckets() {
        let untrained = StrengthBalance.untrainedGroups(setsByMuscle: [.chest: 4])
        XCTAssertFalse(untrained.contains(.chest))
        XCTAssertFalse(untrained.contains(.cardio))
        XCTAssertFalse(untrained.contains(.fullBody))
        XCTAssertFalse(untrained.contains(.other))
        XCTAssertTrue(untrained.contains(.hamstrings))
    }
}

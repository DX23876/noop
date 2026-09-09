import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Pins the records and the trend line.
///
/// The records are measured, so their tests are about BOOKKEEPING: warmups must not set them, a tie
/// must keep the earlier day, a rep band must not swallow a set from the next one. The trend's tests
/// are about RESTRAINT: it must not turn four points over a fortnight into a confident direction, and
/// one bad session must not reverse a good block — which is exactly what the per-cent change it
/// replaced did.
final class StrengthProgressTests: XCTestCase {

    private func set(_ index: Int, _ type: HevySetType = .normal,
                     kg: Double? = nil, reps: Int? = nil, rpe: Double? = nil) -> HevySet {
        HevySet(index: index, type: type, weightKg: kg, reps: reps,
                distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
    }

    private func workout(_ id: String, at ts: Int, _ sets: [HevySet],
                         templateId: String? = "BP") -> HevyWorkout {
        HevyWorkout(id: id, title: "Push", routineId: nil, notes: nil, startTs: ts, endTs: ts + 3600,
                    updatedAtTs: ts, createdAtTs: ts,
                    exercises: [HevyExercise(index: 0, title: "Bench", templateId: templateId,
                                             supersetId: nil, notes: nil, sets: sets)])
    }

    private var templates: [String: HevyExerciseTemplate] {
        ["BP": HevyExerciseTemplate(id: "BP", title: "Bench", type: "weight_reps",
                                    primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps],
                                    equipment: .barbell, isCustom: false)]
    }

    private static func ts(_ day: String) -> Int {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return Int((f.date(from: day) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970) + 43_200
    }

    // MARK: - Records

    /// A heavy WARMUP single is not a record. Ramping to 120 kg for one before working at 100 is
    /// ordinary practice, and counting it would put a number on the card the lifter never worked at.
    func testAWarmupNeverSetsARecord() {
        let workouts = [workout("a", at: Self.ts("2026-07-01"),
                                [set(0, .warmup, kg: 120, reps: 1), set(1, kg: 100, reps: 5)])]
        let records = StrengthProgress.records(templateId: "BP", workouts: workouts, templates: templates)
        XCTAssertEqual(records.heaviestSet?.value, 100)
    }

    /// A record keeps the day it was FIRST reached. Re-dating it to the latest repeat would erase how
    /// long it has stood, which is the only thing the date is there to say.
    func testATiedRecordKeepsTheEarlierDay() {
        let workouts = [
            workout("a", at: Self.ts("2026-07-01"), [set(0, kg: 100, reps: 3)]),
            workout("b", at: Self.ts("2026-07-15"), [set(0, kg: 100, reps: 3)]),
        ]
        let records = StrengthProgress.records(templateId: "BP", workouts: workouts, templates: templates)
        XCTAssertEqual(records.heaviestSet?.day, "2026-07-01")
    }

    /// Bands group by reps, and the heaviest set inside a band wins it. A 3-rep set must never be
    /// entered against the 4–6 band just because it was heavier.
    func testRepBandsKeepTheirOwnBests() {
        let workouts = [workout("a", at: Self.ts("2026-07-01"),
                                [set(0, kg: 120, reps: 2), set(1, kg: 100, reps: 5),
                                 set(2, kg: 80, reps: 10), set(3, kg: 50, reps: 20)])]
        let records = StrengthProgress.records(templateId: "BP", workouts: workouts, templates: templates)
        XCTAssertEqual(records.bestByRepBand[.oneToThree]?.value, 120)
        XCTAssertEqual(records.bestByRepBand[.fourToSix]?.value, 100)
        XCTAssertEqual(records.bestByRepBand[.sevenToTwelve]?.value, 80)
        XCTAssertEqual(records.bestByRepBand[.thirteenPlus]?.value, 50)
    }

    /// The e1RM record is bounded by the estimate's own domain: a set of twenty produces no estimate at
    /// all, so it cannot become the best one.
    func testAHighRepSetCannotSetAnEstimatedRecord() {
        let workouts = [workout("a", at: Self.ts("2026-07-01"), [set(0, kg: 60, reps: 20)])]
        let records = StrengthProgress.records(templateId: "BP", workouts: workouts, templates: templates)
        XCTAssertNil(records.bestE1RM)
        XCTAssertEqual(records.heaviestSet?.value, 60, "the measured set is still a record")
    }

    /// Session volume is a record of its own, and it is the SUM over the exercise's working sets.
    func testSessionVolumeIsARecordOfItsOwn() {
        let workouts = [
            workout("a", at: Self.ts("2026-07-01"), [set(0, kg: 100, reps: 5)]),               // 500
            workout("b", at: Self.ts("2026-07-08"), [set(0, kg: 80, reps: 5), set(1, kg: 80, reps: 5)]), // 800
        ]
        let records = StrengthProgress.records(templateId: "BP", workouts: workouts, templates: templates)
        XCTAssertEqual(records.bestSessionVolume?.value, 800)
        XCTAssertEqual(records.bestSessionVolume?.day, "2026-07-08")
    }

    // MARK: - The trend line

    private func points(_ values: [(String, Double)]) -> [ExercisePerformancePoint] {
        values.map { day, e1rm in
            ExercisePerformancePoint(day: day, startTs: Self.ts(day), workoutId: day,
                                     bestE1RMKg: e1rm, heaviestSetKg: e1rm, workingSetCount: 3,
                                     totalReps: 15, volumeLoadKg: e1rm * 15, meanRpe: nil, rpeSetCount: 0)
        }
    }

    /// A clean climb reads as a climb, in kilograms per week.
    func testASteadyClimbIsReportedInKilogramsPerWeek() throws {
        let trend = try XCTUnwrap(StrengthProgress.e1rmTrend(points([
            ("2026-06-01", 100), ("2026-06-08", 102), ("2026-06-15", 104), ("2026-06-22", 106),
        ])))
        XCTAssertEqual(trend.slopePerWeek, 2, accuracy: 1e-6)
        XCTAssertFalse(trend.directionIsUnclear)
        XCTAssertEqual(trend.changeOverSpan, 6, accuracy: 1e-6)
    }

    /// ONE bad last session must not reverse the verdict on a whole block.
    ///
    /// This is the test the old "first point vs last point" reading fails outright: with a final
    /// session at 96 it reported a 4 % DECLINE over four weeks of climbing.
    func testOneBadSessionDoesNotReverseTheTrend() throws {
        let series = points([
            ("2026-06-01", 100), ("2026-06-08", 103), ("2026-06-15", 106),
            ("2026-06-22", 109), ("2026-06-29", 96),
        ])
        let trend = try XCTUnwrap(StrengthProgress.e1rmTrend(series))
        XCTAssertGreaterThan(trend.slopePerWeek, 0, "a median of pairwise slopes shrugs off one outlier")

        let naive = (series.last!.bestE1RMKg! - series.first!.bestE1RMKg!) / series.first!.bestE1RMKg! * 100
        XCTAssertLessThan(naive, 0, "the reading this replaced would have called it a decline")
    }

    /// Noise gets no direction. When the middle half of the pairwise slopes straddles zero the caller
    /// is told the evidence does not agree — not handed a small number to render as progress.
    func testNoiseIsReportedAsNoDirection() throws {
        let trend = try XCTUnwrap(StrengthProgress.e1rmTrend(points([
            ("2026-06-01", 100), ("2026-06-08", 104), ("2026-06-15", 99),
            ("2026-06-22", 103), ("2026-06-29", 100),
        ])))
        XCTAssertTrue(trend.directionIsUnclear)
    }

    /// Below four points there is no line. Three points make a trend out of a good day and a bad one.
    func testThreePointsAreNotATrend() {
        XCTAssertNil(StrengthProgress.e1rmTrend(points([
            ("2026-06-01", 100), ("2026-06-08", 102), ("2026-06-15", 104),
        ])))
    }

    /// Sessions with no estimate are SKIPPED, not zero-filled. A bodyweight day is missing evidence
    /// about the bench press, not evidence of a 0 kg bench press.
    func testMissingEstimatesAreSkippedRatherThanZeroFilled() throws {
        var series = points([("2026-06-01", 100), ("2026-06-08", 102),
                             ("2026-06-15", 104), ("2026-06-22", 106)])
        series.insert(ExercisePerformancePoint(day: "2026-06-11", startTs: Self.ts("2026-06-11"),
                                               workoutId: "x", bestE1RMKg: nil, heaviestSetKg: nil,
                                               workingSetCount: 3, totalReps: 30, volumeLoadKg: 0,
                                               meanRpe: nil, rpeSetCount: 0), at: 2)
        let trend = try XCTUnwrap(StrengthProgress.e1rmTrend(series))
        XCTAssertEqual(trend.pointCount, 4)
        XCTAssertEqual(trend.slopePerWeek, 2, accuracy: 1e-6)
    }

    /// How long the heaviest set has stood — a fact about the record, not a verdict on the training.
    func testDaysSinceTheHeaviestSet() {
        let workouts = [workout("a", at: Self.ts("2026-06-01"), [set(0, kg: 100, reps: 3)])]
        let records = StrengthProgress.records(templateId: "BP", workouts: workouts, templates: templates)
        XCTAssertEqual(StrengthProgress.daysSinceHeaviestSet(records, today: "2026-07-01"), 30)
    }
}

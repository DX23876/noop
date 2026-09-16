import XCTest
@testable import StrandAnalytics
import WhoopStore

final class StrengthOverviewTests: XCTestCase {
    func testOverviewSeparatesCoverageAndBuildsRecordTimeline() {
        let template = HevyExerciseTemplate(id: "bench", title: "Bench press", type: "weight_reps",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps], equipment: .barbell, isCustom: false)
        let first = workout(id: "a", ts: 100, weight: 80, rpe: nil)
        let second = workout(id: "b", ts: 100 + 7 * 86_400, weight: 90, rpe: 8)
        let result = StrengthOverview.calculate(workouts: [second, first], templates: ["bench": template],
            from: 100, to: 100 + 14 * 86_400)

        XCTAssertEqual(result.sessionCount, 2)
        XCTAssertEqual(result.trainingDayCount, 2)
        XCTAssertEqual(result.workingSetCount, 4)
        XCTAssertEqual(result.ratedSetCount, 2)
        XCTAssertEqual(result.rpeCoverage, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.volumeLoadKg, 2_720, accuracy: 0.001)
        XCTAssertEqual(result.personalRecords.map(\.workoutId), ["b", "a"])
        XCTAssertEqual(result.sessionsPerWeek, 1, accuracy: 0.01)
    }

    func testLowerSessionDoesNotCreateAnotherRecord() {
        let template = HevyExerciseTemplate(id: "bench", title: "Bench press", type: "weight_reps",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [], equipment: .barbell, isCustom: false)
        let high = workout(id: "high", ts: 100, weight: 100, rpe: 10)
        let low = workout(id: "low", ts: 200, weight: 80, rpe: 10)
        let result = StrengthOverview.calculate(workouts: [low, high], templates: ["bench": template],
                                                from: 0, to: 1_000)
        XCTAssertEqual(result.personalRecords.map(\.workoutId), ["high"])
    }

    func testWeeklyConsistencyFollowsTheChosenWeekStart() throws {
        // 1970-01-04 was a Sunday and 1970-01-05 the Monday after it.
        let sunday = 3 * 86_400 + 12 * 3_600
        let monday = sunday + 86_400
        let workouts = [workout(id: "sun", ts: sunday, weight: 60, rpe: 7),
                        workout(id: "mon", ts: monday, weight: 60, rpe: 9)]

        let mondayStart = StrengthOverview.calculate(workouts: workouts, templates: [:], from: 0,
                                                     to: monday + 3_600, firstWeekday: 2)
        XCTAssertEqual(mondayStart.activeWeekCount, 2)
        XCTAssertEqual(mondayStart.observedWeekCount, 2)
        XCTAssertEqual(mondayStart.longestActiveWeekStreak, 2)
        XCTAssertEqual(try XCTUnwrap(mondayStart.averageRPE), 8, accuracy: 0.001)

        let sundayStart = StrengthOverview.calculate(workouts: workouts, templates: [:], from: 0,
                                                     to: monday + 3_600, firstWeekday: 1)
        XCTAssertEqual(sundayStart.activeWeekCount, 1)
        XCTAssertEqual(sundayStart.observedWeekCount, 1)
        XCTAssertEqual(sundayStart.weeklyConsistency, 1, accuracy: 0.001)
    }

    func testConsistencyStartsAtFirstSessionCountsGapsAndInventsNoEffort() {
        let monday = 4 * 86_400 + 12 * 3_600
        let workouts = [0, 1, 3].map { week in
            workout(id: "w\(week)", ts: monday + week * 7 * 86_400, weight: 60, rpe: nil)
        }
        let result = StrengthOverview.calculate(workouts: workouts, templates: [:], from: 0,
                                                to: monday + 4 * 7 * 86_400, firstWeekday: 2)
        XCTAssertEqual(result.activeWeekCount, 3)
        XCTAssertEqual(result.observedWeekCount, 5)
        XCTAssertEqual(result.longestActiveWeekStreak, 2)
        XCTAssertEqual(result.weeklyConsistency, 0.6, accuracy: 0.001)
        XCTAssertNil(result.averageRPE)
    }

    func testWeekIndexHonoursTimeZoneOffset() {
        // 23:30 UTC on Sunday 1970-01-04 is already Monday at UTC+1.
        let ts = 3 * 86_400 + 23 * 3_600 + 30 * 60
        XCTAssertEqual(StrengthOverview.weekIndex(ts, tzOffsetSeconds: 0, firstWeekday: 2), -1)
        XCTAssertEqual(StrengthOverview.weekIndex(ts, tzOffsetSeconds: 3_600, firstWeekday: 2), 0)
    }

    private func workout(id: String, ts: Int, weight: Double, rpe: Double?) -> HevyWorkout {
        let sets = [8, 8].enumerated().map { index, reps in
            HevySet(index: index, type: .normal, weightKg: weight, reps: reps,
                    distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
        }
        return HevyWorkout(id: id, title: "Push", routineId: nil, notes: nil,
                           startTs: ts, endTs: ts + 3_600, updatedAtTs: ts,
                           createdAtTs: ts, exercises: [.init(index: 0, title: "Bench press",
                               templateId: "bench", supersetId: nil, notes: nil, sets: sets)])
    }
}

import XCTest
@testable import StrandTraining

/// What a block came to, taken from the workout log rather than from anything stored about it.
final class BlockReportTests: XCTestCase {

    private let bench = TrainingExercise(id: "bench", title: "Barbell Bench Press", mode: .weightReps,
                                         primaryMuscleId: "chest", secondaryMuscleIds: ["triceps"],
                                         equipmentIds: ["barbell", "bench"], source: .noop)

    private var exercises: [String: TrainingExercise] { [bench.id: bench] }

    private func day(_ key: String) -> Int {
        Int(TrainingBlockState.date(key)?.timeIntervalSince1970 ?? 0) + 12 * 3_600
    }

    private func session(_ dayKey: String, sets: [(Double?, Int?)], rpe: Double? = nil)
        -> NativeWorkout {
        let logged = sets.enumerated().map { index, value -> NativeWorkoutSet in
            var set = NativeWorkoutSet(index: index, weightKg: value.0, reps: value.1)
            set.isCompleted = true
            return set
        }
        return NativeWorkout(id: UUID(), title: "Push", startedAt: day(dayKey),
                             endedAt: day(dayKey) + 3_600, plannedDay: dayKey, routineIds: [],
                             exercises: [NativeWorkoutExercise(exerciseId: bench.id, sets: logged)],
                             tracker: nil, sessionRPE: rpe)
    }

    private func run(from: String, to: String?) -> TrainingBlockRun {
        TrainingBlockRun(programId: UUID(), startedOn: from, endedOn: to, weeks: 4,
                         outcome: to == nil ? .running : .finished)
    }

    func testOnlyTheSessionsInsideTheBlocksOwnWindowCount() {
        let inside = session("2026-11-10", sets: [(100, 5), (100, 5)])
        let before = session("2026-11-01", sets: [(100, 5)])
        let after = session("2026-12-20", sets: [(100, 5)])
        let report = BlockReport.make(run: run(from: "2026-11-09", to: "2026-12-06"),
                                      workouts: [before, inside, after], exercises: exercises,
                                      sessionsPerWeek: 3, today: "2026-12-10")
        XCTAssertEqual(report.doneSessions, 1)
        XCTAssertEqual(report.workSets, 2)
        XCTAssertEqual(report.loadKg, 1_000)
        XCTAssertEqual(report.setsByRegion[.chest], 2)
        // The triceps come along at half credit, as everywhere else.
        XCTAssertEqual(report.setsByRegion[.arms], 1)
    }

    func testWhatThePlanAskedForComesFromThePlanAndNotFromTheLog() {
        let report = BlockReport.make(run: run(from: "2026-11-09", to: "2026-12-06"),
                                      workouts: [], exercises: exercises, sessionsPerWeek: 3,
                                      today: "2026-12-10")
        XCTAssertEqual(report.plannedSessions, 12)
        XCTAssertEqual(report.doneSessions, 0)

        // A plan that says nothing about a week leaves the figure out rather than inventing it from
        // the sessions that happened, which would compare the log with itself.
        let quiet = BlockReport.make(run: run(from: "2026-11-09", to: "2026-12-06"),
                                     workouts: [], exercises: exercises, sessionsPerWeek: nil,
                                     today: "2026-12-10")
        XCTAssertNil(quiet.plannedSessions)
    }

    func testASetWithNoWeightIsCountedAsUnpricedRatherThanLeftOutQuietly() {
        let report = BlockReport.make(run: run(from: "2026-11-09", to: nil),
                                      workouts: [session("2026-11-10", sets: [(nil, 10), (80, 5)])],
                                      exercises: exercises, sessionsPerWeek: nil,
                                      today: "2026-11-20")
        XCTAssertEqual(report.workSets, 2)
        XCTAssertEqual(report.unpricedWorkSets, 1)
        XCTAssertEqual(report.loadKg, 400)
    }

    func testTwoSessionsOnOneDayAreTwoSessionsAndOneDay() {
        let report = BlockReport.make(
            run: run(from: "2026-11-09", to: nil),
            workouts: [session("2026-11-10", sets: [(100, 5)]),
                       session("2026-11-10", sets: [(100, 5)])],
            exercises: exercises, sessionsPerWeek: nil, today: "2026-11-20")
        XCTAssertEqual(report.doneSessions, 2)
        XCTAssertEqual(report.daysTrained, 1)
    }

    func testTheEffortIsTheMeanOfWhatTheWearerActuallyGave() {
        let report = BlockReport.make(
            run: run(from: "2026-11-09", to: nil),
            workouts: [session("2026-11-10", sets: [(100, 5)], rpe: 8),
                       session("2026-11-12", sets: [(100, 5)], rpe: 6),
                       session("2026-11-13", sets: [(100, 5)])],
            exercises: exercises, sessionsPerWeek: nil, today: "2026-11-20")
        XCTAssertEqual(report.averageSessionRPE, 7)
    }

    func testARunningBlockIsMeasuredUpToTodayAndNotBeyondIt() {
        let report = BlockReport.make(run: run(from: "2026-11-09", to: nil),
                                      workouts: [session("2026-11-10", sets: [(100, 5)]),
                                                 session("2026-11-25", sets: [(100, 5)])],
                                      exercises: exercises, sessionsPerWeek: nil,
                                      today: "2026-11-20")
        XCTAssertEqual(report.doneSessions, 1)
    }

    func testTwoBlocksSideBySideSayWhichWasTheBiggerOne() {
        let first = BlockReport.make(run: run(from: "2026-09-01", to: "2026-09-28"),
                                     workouts: [session("2026-09-02", sets: [(100, 5)])],
                                     exercises: exercises, sessionsPerWeek: 3, today: "2026-11-20")
        let second = BlockReport.make(run: run(from: "2026-10-01", to: "2026-10-28"),
                                      workouts: [session("2026-10-02", sets: [(110, 5), (110, 5)])],
                                      exercises: exercises, sessionsPerWeek: 3, today: "2026-11-20")
        let delta = BlockReport.compare(previous: first, current: second)
        XCTAssertEqual(delta.sessions, 0)
        XCTAssertEqual(delta.workSets, 1)
        XCTAssertEqual(delta.loadKg, 600)
        XCTAssertEqual(delta.setsByRegion[.chest], 1)
    }
}

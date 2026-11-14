import XCTest
@testable import StrandTraining

/// What a plan amounts to in a week, and what stands out about it against the wearer's own history.
final class PlanReviewTests: XCTestCase {

    private let bench = TrainingExercise(id: "bench", title: "Barbell Bench Press", mode: .weightReps,
                                         primaryMuscleId: "chest", secondaryMuscleIds: ["triceps"],
                                         equipmentIds: ["barbell", "bench"], source: .noop)
    private let squat = TrainingExercise(id: "squat", title: "Back Squat", mode: .weightReps,
                                         primaryMuscleId: "quadriceps", secondaryMuscleIds: ["glutes"],
                                         equipmentIds: ["barbell"], source: .noop)

    private var exercises: [String: TrainingExercise] {
        [bench.id: bench, squat.id: squat]
    }

    private func routine(_ title: String, _ exerciseId: String, workSets: Int,
                         rest: Int = 120) -> TrainingRoutine {
        TrainingRoutine(title: title, exercises: [
            RoutineExercise(exerciseId: exerciseId,
                            sets: (0..<workSets).map { _ in RoutineSetPlan(repsMin: 8, repsMax: 10) },
                            restSeconds: rest)
        ])
    }

    func testWeeklySetsCountARoutineOnceForEachDayItIsScheduled() {
        let push = routine("Push", bench.id, workSets: 4)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [push.id], .thursday: [push.id]]
        let review = PlanReview.evaluate(program: program, routines: [push], exercises: exercises)

        // Four sets twice a week on the chest, and the triceps at half credit, as the muscle map counts.
        XCTAssertEqual(review.weeklySetsByRegion[.chest], 8)
        XCTAssertEqual(review.weeklySetsByRegion[.arms], 4)
        // Two sessions, not one routine: a plan whose target says three a week must not be read
        // back as one beside it.
        XCTAssertEqual(review.weeklySessionCount, 2)
        XCTAssertEqual(review.sessionMinutes[push.id], SessionEstimate.minutes(push))
    }

    func testARegionTheWeekNeverTouchesIsNamed() {
        let push = routine("Push", bench.id, workSets: 3)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [push.id]]
        let review = PlanReview.evaluate(program: program, routines: [push], exercises: exercises)
        XCTAssertTrue(review.findings.contains(.regionUntrained(.legs)))
        XCTAssertTrue(review.findings.contains(.regionUntrained(.back)))
        XCTAssertFalse(review.findings.contains(.regionUntrained(.chest)))
    }

    /// An empty plan says nothing about regions: every one of them is untrained, and listing six
    /// findings for a plan with no sessions in it is noise.
    func testAnEmptyPlanRaisesNoRegionFindings() {
        let review = PlanReview.evaluate(program: TrainingProgram(title: "Plan"), routines: [],
                                         exercises: exercises)
        XCTAssertTrue(review.findings.isEmpty)
        XCTAssertTrue(review.weeklySetsByRegion.isEmpty)
    }

    func testAStepUpIsMeasuredAgainstTheWearersOwnWeeksAndNotATextbook() {
        let push = routine("Push", bench.id, workSets: 8)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [push.id], .thursday: [push.id]]
        // Sixteen sets of chest a week against a recent average of six.
        let history = PlanHistory(setsByRegion: [.chest: 24], weeks: 4, trainedWeeks: 4)
        let review = PlanReview.evaluate(program: program, routines: [push], exercises: exercises,
                                         history: history)
        XCTAssertTrue(review.findings.contains { finding in
            if case .regionAboveUsual(let region, let weekly, let usual) = finding {
                return region == .chest && weekly == 16 && usual == 6
            }
            return false
        })

        // The same plan against someone who already trains that much says nothing.
        let used = PlanHistory(setsByRegion: [.chest: 60], weeks: 4, trainedWeeks: 4)
        let quiet = PlanReview.evaluate(program: program, routines: [push], exercises: exercises,
                                        history: used)
        XCTAssertFalse(quiet.findings.contains { if case .regionAboveUsual = $0 { return true }; return false })
    }

    /// Under two weeks of history the comparison stays silent: a warning drawn from one session is a
    /// statement about thin data, not about the plan.
    func testThinHistoryKeepsTheComparisonSilent() {
        let push = routine("Push", bench.id, workSets: 8)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [push.id], .thursday: [push.id]]
        let history = PlanHistory(setsByRegion: [.chest: 2], weeks: 1, trainedWeeks: 1)
        let review = PlanReview.evaluate(program: program, routines: [push], exercises: exercises,
                                         history: history)
        XCTAssertFalse(review.findings.contains { if case .regionAboveUsual = $0 { return true }; return false })
    }

    /// The window is always as long as it is, so it cannot be what the silence is judged on. One
    /// session three weeks ago is thin history, however long the window around it was.
    func testOneSessionInTheWindowIsStillThinHistory() {
        let now = 1_000_000
        let lonely = workout(bench.id, sets: 3, startedAt: now - 20 * 86_400)
        let history = PlanHistory.from(workouts: [lonely], exercises: exercises, windowDays: 28,
                                       now: now)
        XCTAssertEqual(history.weeks, 4, "the window is four weeks whatever is in it")
        XCTAssertEqual(history.trainedWeeks, 1, "and one of them holds a session")

        let push = routine("Push", bench.id, workSets: 8)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [push.id], .thursday: [push.id]]
        let review = PlanReview.evaluate(program: program, routines: [push], exercises: exercises,
                                         history: history)
        XCTAssertFalse(review.findings.contains { if case .regionAboveUsual = $0 { return true }; return false },
                       "sixteen sets against one logged session is not a finding about the plan")

        // Sessions in two different weeks are enough, and then the comparison does run.
        let second = workout(bench.id, sets: 3, startedAt: now - 3 * 86_400)
        let enough = PlanHistory.from(workouts: [lonely, second], exercises: exercises,
                                      windowDays: 28, now: now)
        XCTAssertEqual(enough.trainedWeeks, 2)
        let spoken = PlanReview.evaluate(program: program, routines: [push], exercises: exercises,
                                         history: enough)
        XCTAssertTrue(spoken.findings.contains { if case .regionAboveUsual = $0 { return true }; return false })
    }

    /// A completed session of `sets` working sets of one exercise.
    private func workout(_ exerciseId: String, sets: Int, startedAt: Int) -> NativeWorkout {
        var set = NativeWorkoutSet(index: 0, weightKg: 100, reps: 5)
        set.isCompleted = true
        return NativeWorkout(id: UUID(), title: "Session", startedAt: startedAt,
                             endedAt: startedAt + 3_600, plannedDay: "2026-11-14", routineIds: [],
                             exercises: [NativeWorkoutExercise(exerciseId: exerciseId,
                                                               sets: (0..<sets).map { _ in set })],
                             tracker: nil)
    }

    /// A small region stays quiet whatever the multiple: one set to three is three times and also
    /// completely unremarkable.
    func testAFewSetsNeverRaiseAMultiple() {
        let core = routine("Core", bench.id, workSets: 2)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [core.id]]
        let history = PlanHistory(setsByRegion: [.chest: 2], weeks: 4, trainedWeeks: 4)
        let review = PlanReview.evaluate(program: program, routines: [core], exercises: exercises,
                                         history: history)
        XCTAssertFalse(review.findings.contains { if case .regionAboveUsual = $0 { return true }; return false })
    }

    func testTwoLegDaysInARowAreMentioned() {
        let legs = routine("Legs", squat.id, workSets: 5)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [legs.id], .tuesday: [legs.id], .friday: [legs.id]]
        let review = PlanReview.evaluate(program: program, routines: [legs], exercises: exercises)
        XCTAssertTrue(review.findings.contains(.heavyDaysBackToBack(first: .monday, second: .tuesday)))
        XCTAssertFalse(review.findings.contains(.heavyDaysBackToBack(first: .thursday, second: .friday)))
    }

    func testASessionOverTheTimeAskedForIsNamedWithBothFigures() {
        let long = routine("Long", squat.id, workSets: 12, rest: 240)
        var program = TrainingProgram(title: "Plan")
        program.schedule = [.monday: [long.id]]
        let review = PlanReview.evaluate(program: program, routines: [long], exercises: exercises,
                                         askedMinutesPerSession: 30)
        XCTAssertTrue(review.findings.contains { finding in
            if case .sessionLongerThanAsked(let id, let minutes, let asked) = finding {
                return id == long.id && asked == 30 && minutes == SessionEstimate.minutes(long)
            }
            return false
        })
        // Without an answer about time there is nothing to compare against, and nothing is said.
        let quiet = PlanReview.evaluate(program: program, routines: [long], exercises: exercises)
        XCTAssertFalse(quiet.findings.contains { if case .sessionLongerThanAsked = $0 { return true }; return false })
    }

    func testHistoryComesFromTheSameMuscleProjectionThePlanIsMeasuredWith() {
        var set = NativeWorkoutSet(index: 0, weightKg: 100, reps: 5)
        set.isCompleted = true
        let workout = NativeWorkout(id: UUID(), title: "Push", startedAt: 1_000_000,
                                    endedAt: 1_003_600, plannedDay: "2026-11-14", routineIds: [],
                                    exercises: [NativeWorkoutExercise(exerciseId: bench.id,
                                                                       sets: [set, set, set, set])],
                                    tracker: nil)
        let history = PlanHistory.from(workouts: [workout], exercises: exercises,
                                       windowDays: 28, now: 1_000_000 + 86_400)
        XCTAssertEqual(history.weeks, 4)
        XCTAssertEqual(history.trainedWeeks, 1)
        XCTAssertEqual(history.setsByRegion[.chest], 4)
        XCTAssertEqual(history.weeklySets(.chest), 1)
        // A session outside the window does not count.
        let old = PlanHistory.from(workouts: [workout], exercises: exercises, windowDays: 28,
                                   now: 1_000_000 + 40 * 86_400)
        XCTAssertNil(old.setsByRegion[.chest])
    }
}

import XCTest
import StrandTraining
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The pure decisions behind the single active session: when a forgotten session is asked about, which
/// sports open the strength logger, how a session's heart rate is read from stored samples, and that the
/// draft no longer depends on which screen started it.
@MainActor
final class ActiveSessionControllerTests: XCTestCase {
    private func draft(startedAt: Int, updatedAt: Int, plannedEndTs: Int? = nil) -> WorkoutDraft {
        var draft = WorkoutDraft(title: "Push", startedAt: startedAt, plannedDay: "2026-09-16",
                                 routineIds: [], exercises: [])
        draft.updatedAt = updatedAt
        draft.plannedEndTs = plannedEndTs
        return draft
    }

    func testASessionUntouchedForMoreThanFourHoursIsAskedAboutNotReopened() {
        let start = 1_000_000
        let fresh = draft(startedAt: start, updatedAt: start + 600)
        XCTAssertFalse(ActiveSessionController.isStale(fresh, now: start + 600 + 4 * 3_600))
        XCTAssertTrue(ActiveSessionController.isStale(fresh, now: start + 600 + 4 * 3_600 + 1))
    }

    func testAForgottenSessionWithNoCompletedSetIsNotWorthAsking() {
        // The prompt exists to protect logged work. A draft that never completed a set has none, and
        // the engine would refuse to complete it, so asking would offer a Save that cannot succeed.
        var empty = draft(startedAt: 1_000_000, updatedAt: 1_000_000)
        empty.exercises = [NativeWorkoutExercise(exerciseId: "exdb:0001",
                                                 sets: [NativeWorkoutSet(index: 0, reps: 8)])]
        XCTAssertFalse(ActiveSessionController.holdsWorkWorthKeeping(empty))
        XCTAssertThrowsError(try NativeWorkoutEngine.complete(draft: empty, endTs: 1_001_000)) { error in
            XCTAssertEqual(error as? WorkoutMutationError, .noCompletedWork)
        }

        // One completed set is the whole difference: now there is something a Save would keep.
        var logged = empty
        logged.exercises = [NativeWorkoutExercise(exerciseId: "exdb:0001",
                                                  sets: [NativeWorkoutSet(index: 0, reps: 8,
                                                                          isCompleted: true)])]
        XCTAssertTrue(ActiveSessionController.holdsWorkWorthKeeping(logged))
        XCTAssertNoThrow(try NativeWorkoutEngine.complete(draft: logged, endTs: 1_001_000))
    }

    func testARetrospectiveEntryIsNeverTreatedAsForgotten() {
        let start = 1_000_000
        let past = draft(startedAt: start, updatedAt: start, plannedEndTs: start + 3_600)
        XCTAssertFalse(ActiveSessionController.isStale(past, now: start + 30 * 86_400))
    }

    func testSavingAForgottenSessionEndsItAtItsLastChange() {
        let start = 1_000_000
        let forgotten = draft(startedAt: start, updatedAt: start + 2_700)
        XCTAssertEqual(ActiveSessionController.lastActivity(of: forgotten), start + 2_700)
    }

    func testStrengthSportsFromEveryPickerOpenTheStrengthLogger() {
        for name in ["Strength", "Strength Training", "Bodybuilding", "Weightlifting", "strength training",
                     "Powerlifting", "CrossFit", "Calisthenics"] {
            XCTAssertTrue(ActiveSessionController.isStrengthSport(name), name)
        }
        for name in ["Walk", "Run", "Treadmill walk", "HIIT"] {
            XCTAssertFalse(ActiveSessionController.isStrengthSport(name), name)
        }
    }

    func testHeartRateExcludesPausesFromSamplesAndActiveTime() {
        let samples = (0..<600).map { HRSample(ts: 1_000 + $0, bpm: 120) }
        let pauses = [(1_100, 1_200)]
        let active = StrengthSessionHeartRate.activeSamples(samples, pauses: pauses)
        XCTAssertEqual(active.count, 500)
        XCTAssertFalse(active.contains { $0.ts >= 1_100 && $0.ts < 1_200 })
        XCTAssertEqual(StrengthSessionHeartRate.activeSeconds(start: 1_000, end: 1_600, pauses: pauses), 500)
        XCTAssertEqual(StrengthSessionHeartRate.coverage(sampleCount: 500, activeSeconds: 500), 1)
    }

    func testAnOpenPauseCountsUntilTheEndAndAWindowWithoutSamplesHasNoCoverage() {
        XCTAssertEqual(StrengthSessionHeartRate.activeSeconds(start: 0, end: 1_000, pauses: [(900, 1_000)]), 900)
        XCTAssertNil(StrengthSessionHeartRate.coverage(sampleCount: 0, activeSeconds: 900))
        XCTAssertEqual(StrengthSessionHeartRate.coverage(sampleCount: 2_000, activeSeconds: 900), 1)
    }

    func testTheSameRoutineBuildsTheSameDraftWhateverStartsIt() {
        let exercise = TrainingExercise(id: "noop:bench", title: "Bench", mode: .weightReps)
        let routine = TrainingRoutine(title: "Push", exercises: [
            RoutineExercise(exerciseId: exercise.id, sets: [
                RoutineSetPlan(phase: .work, targetWeightKg: 60, repsMin: 5, repsMax: 5)
            ])
        ])
        let context = TrainingStartContext(exercises: [exercise], plan: TrainingPlan(routines: [routine]))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = StrengthDraftBuilder.draft(routines: [routine], tracker: nil, context: context, date: date)
        let b = StrengthDraftBuilder.draft(routines: [routine], tracker: nil, context: context, date: date)
        XCTAssertEqual(a.title, "Push")
        XCTAssertEqual(a.exercises.map(\.exerciseId), b.exercises.map(\.exerciseId))
        XCTAssertEqual(a.exercises.first?.sets.map(\.weightKg), b.exercises.first?.sets.map(\.weightKg))
        XCTAssertNil(a.plannedEndTs)
    }

    func testARetrospectiveDraftCarriesItsPlannedEnd() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let draft = StrengthDraftBuilder.draft(routines: [], tracker: nil, context: TrainingStartContext(),
                                               date: date, pastDurationS: 3_000)
        XCTAssertEqual(draft.plannedEndTs, 1_800_003_000)
    }

    func testOnlyAStrengthRecordingStartedBesideTheDraftIsRetiredAsItsLegacyTwin() {
        XCTAssertTrue(ActiveSessionController.isLegacyTwin(recordingSport: "Strength Training",
                                                           recordingStart: 1_000_300, draftStart: 1_000_000))
        XCTAssertFalse(ActiveSessionController.isLegacyTwin(recordingSport: "Strength Training",
                                                            recordingStart: 1_000_601, draftStart: 1_000_000))
        XCTAssertFalse(ActiveSessionController.isLegacyTwin(recordingSport: "Walk",
                                                            recordingStart: 1_000_000, draftStart: 1_000_000))
    }

    func testALegacyStrengthRecordingIsHiddenOnlyBesideItsLinkedNativeSession() {
        func row(_ source: String, _ start: Int, _ end: Int, _ sport: String = "Strength Training") -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                       durationS: Double(end - start), energyKcal: nil, avgHr: 120, maxHr: 150,
                       strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        let native = row("native-training:my-whoop", 1_000, 4_600)
        let twin = row("manual", 1_030, 4_590)
        let walk = row("manual", 1_030, 4_590, "Walk")
        let unrelated = row("manual", 90_000, 93_600)
        let key = "native-training:my-whoop|1000|\(WorkoutSource.sportKey("Strength Training"))"
        let link = TrainingSessionLinkRow(componentKey: key, sessionId: "s", origin: "native-lifecycle", updatedAtTs: 0)
        let visible = Repository.hidingLegacyStrengthRecordings([native, twin, walk, unrelated], links: [link])
        XCTAssertEqual(visible.map(\.source), ["native-training:my-whoop", "manual", "manual"])
        XCTAssertFalse(visible.contains(twin))
        XCTAssertEqual(Repository.hidingLegacyStrengthRecordings([native, twin], links: []).count, 2)
    }

    /// #2278: an accidental start/stop lands as a zero-length row ("0m"). Half of zero overlaps nothing,
    /// so its twin used to stay visible and a delete of one copy left the other on screen.
    func testAZeroLengthStrengthRecordingIsStillRecognisedAsTheTwin() {
        func row(_ source: String, _ start: Int, _ end: Int) -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: end, sport: "Strength Training", source: source,
                       durationS: Double(end - start), energyKcal: nil, avgHr: nil, maxHr: nil,
                       strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        let native = row("native-training", 1_000, 1_000)
        XCTAssertTrue(Repository.isLegacyStrengthTwin(row("manual", 1_000, 1_000), of: native))
        XCTAssertTrue(Repository.isLegacyStrengthTwin(row("manual", 990, 1_040), of: native),
                      "a zero-length native inside the recording's span is its twin")
        XCTAssertFalse(Repository.isLegacyStrengthTwin(row("manual", 1_001, 1_001), of: native),
                       "a different instant is a different session")
        XCTAssertFalse(Repository.isLegacyStrengthTwin(row("manual", 2_000, 2_600), of: native))
        // The non-degenerate rule is unchanged: half of the shorter span must overlap.
        let long = row("native-training", 1_000, 2_000)
        XCTAssertTrue(Repository.isLegacyStrengthTwin(row("manual", 1_400, 2_400), of: long))
        XCTAssertFalse(Repository.isLegacyStrengthTwin(row("manual", 1_600, 2_600), of: long))
    }
}

import XCTest
import StrandTraining
@testable import Strand

/// The effort picker offers the same six described levels on both scales, and the logger never shows a
/// progression note for a target that was not actually derived from history.
final class WorkoutLoggerComponentsTests: XCTestCase {
    func testRPELevelsAreTenMinusRepsInReserve() {
        let rir = EffortChoice.choices(for: .rir).map(\.value)
        let rpe = EffortChoice.choices(for: .rpe).map(\.value)
        XCTAssertEqual(rir, [0, 0.5, 1, 2, 3, 4])
        XCTAssertEqual(rpe, rir.map { 10 - $0 })
        XCTAssertEqual(Set(EffortChoice.choices(for: .rpe).map(\.title)),
                       Set(EffortChoice.choices(for: .rir).map(\.title)))
    }

    func testAStoredRatingTakesItsNearestLevel() throws {
        XCTAssertEqual(EffortChoice.level(for: try XCTUnwrap(TrainingEffortRating(scale: .rpe, value: 8))), 3)
        XCTAssertEqual(EffortChoice.level(for: try XCTUnwrap(TrainingEffortRating(scale: .rir, value: 0))), 0)
        XCTAssertEqual(EffortChoice.level(for: try XCTUnwrap(TrainingEffortRating(scale: .rir, value: 5))), 5)
    }

    func testOnlyReasonsThatExplainATargetProduceText() {
        XCTAssertNil(ProgressionReasonText.text(.disabled))
        XCTAssertNil(ProgressionReasonText.text(.firstSession))
        for reason in ProgressionReason.allCases where reason != .disabled && reason != .firstSession {
            XCTAssertNotNil(ProgressionReasonText.text(reason), reason.rawValue)
        }
    }

    func testTheRoutineReasonIsKeptOnTheDraftExercise() {
        let exercise = TrainingExercise(id: "noop:bench", title: "Bench", mode: .weightReps)
        let routine = TrainingRoutine(title: "Push", exercises: [
            RoutineExercise(exerciseId: exercise.id, sets: [RoutineSetPlan(phase: .work, targetWeightKg: 60,
                                                                           repsMin: 5, repsMax: 5)])
        ], defaultProgression: .init(policy: .linear))
        let draft = StrengthDraftBuilder.draft(routines: [routine], tracker: nil,
                                               context: TrainingStartContext(exercises: [exercise]))
        XCTAssertEqual(draft.exercises.first?.progressionReason, .firstSession)
    }
}

import XCTest
import WhoopStore
@testable import Strand

/// The editor that completes a HealthKit strength envelope. It must add exercises to the session that
/// already exists — never log a second copy of it — and it must be re-openable, because a wearer who
/// mistypes a set count has no other way to correct it.
final class GenericStrengthDetailsTests: XCTestCase {
    private func session(start: Int = 1_000, end: Int = 4_600) -> UnifiedTrainingSession {
        let row = WorkoutRow(startTs: start, endTs: end, sport: "Functional strength training",
                             source: "apple-health", durationS: Double(end - start), energyKcal: 260,
                             avgHr: 118, maxHr: 157, strain: nil, distanceM: nil, zonesJSON: nil,
                             notes: nil, steps: nil)
        let component = TrainingSessionComponent(id: "apple-health|\(start)|functionalstrengthtraining",
                                                 row: row, metadata: nil)
        return UnifiedTrainingSession(id: "session|health", kind: .strength, row: row,
                                      components: [component], fusionOrigin: "automatic")
    }

    private func draft(title: String, sets: Int = 4, muscle: HevyMuscleGroup = .chest,
                       effort: String = "", usesRIR: Bool = true) -> GenericStrengthDetailsSheet.Draft {
        var draft = GenericStrengthDetailsSheet.Draft()
        draft.title = title
        draft.workSets = sets
        draft.muscle = muscle
        draft.effort = effort
        draft.usesRIR = usesRIR
        return draft
    }

    func testTheFormBecomesRatedWorkingSetsOnTheSessionsOwnWindow() throws {
        let entry = try GenericStrengthDetailsSheet.makeEntry(
            drafts: [draft(title: "Bench press", effort: "1")], session: session(),
            existingId: nil, now: 10)
        XCTAssertEqual(entry.workout.source, .manual)
        XCTAssertEqual(entry.workout.startTs, 1_000)
        XCTAssertEqual(entry.workout.endTs, 4_600)
        XCTAssertEqual(entry.workout.exercises.count, 1)
        XCTAssertEqual(entry.workout.exercises[0].workingSets.count, 4)
        // RIR 1 is one rep short of failure: the app prices proximity to failure on the RPE scale.
        XCTAssertEqual(entry.workout.exercises[0].workingSets.first?.rpe, 9)
        XCTAssertEqual(entry.templates.first?.primaryMuscleGroup, .chest)
    }

    /// Nothing is invented: a session the wearer has not rated carries unrated sets, which Strength Load
    /// prices with its neutral default rather than an imagined effort.
    func testAnUnratedFormProducesUnratedSets() throws {
        let entry = try GenericStrengthDetailsSheet.makeEntry(
            drafts: [draft(title: "Row", effort: "")], session: session(), existingId: nil, now: 10)
        XCTAssertNil(entry.workout.exercises[0].workingSets.first?.rpe)
        XCTAssertEqual(entry.workout.exercises[0].workingSets.count, 4)
    }

    func testSavingTwiceEditsOneEntryInsteadOfLoggingTheSessionAgain() throws {
        let first = try GenericStrengthDetailsSheet.makeEntry(
            drafts: [draft(title: "Bench press")], session: session(), existingId: nil, now: 10)
        let again = try GenericStrengthDetailsSheet.makeEntry(
            drafts: [draft(title: "Bench press", sets: 5)], session: session(), existingId: nil, now: 20)
        XCTAssertEqual(first.workout.id, again.workout.id)

        let edited = try GenericStrengthDetailsSheet.makeEntry(
            drafts: [draft(title: "Bench press")], session: session(),
            existingId: "manual-legacy-id", now: 30)
        XCTAssertEqual(edited.workout.id, "manual-legacy-id")
    }

    /// A typed effort outside its scale is a mistake to report, not a value to discard silently — the
    /// wearer would otherwise believe the session was rated.
    func testAnEffortOutsideItsScaleIsRefused() {
        XCTAssertThrowsError(try GenericStrengthDetailsSheet.rating(
            for: draft(title: "Bench press", effort: "9", usesRIR: true))) { error in
            XCTAssertEqual(error as? GenericStrengthDetailsSheet.DraftError,
                           .effortOutOfRange(exercise: "Bench press"))
        }
        XCTAssertThrowsError(try GenericStrengthDetailsSheet.rating(
            for: draft(title: "Bench press", effort: "3", usesRIR: false)))
    }

    func testAFormWithoutAnExerciseNameIsRefused() {
        XCTAssertThrowsError(try GenericStrengthDetailsSheet.makeEntry(
            drafts: [draft(title: "   ")], session: session(), existingId: nil, now: 10)) { error in
            XCTAssertEqual(error as? GenericStrengthDetailsSheet.DraftError, .noExercise)
        }
    }

    func testReopeningTheEditorRestoresWhatWasSaved() throws {
        let entry = try GenericStrengthDetailsSheet.makeEntry(
            drafts: [draft(title: "Bench press", sets: 4, muscle: .chest, effort: "1")],
            session: session(), existingId: nil, now: 10)
        let catalogue = Dictionary(uniqueKeysWithValues: entry.templates.map { ($0.id, $0) })
        let restored = GenericStrengthDetailsSheet.drafts(from: entry.workout, templates: catalogue)
        XCTAssertEqual(restored.map(\.title), ["Bench press"])
        XCTAssertEqual(restored.first?.workSets, 4)
        XCTAssertEqual(restored.first?.muscle, .chest)
        // Offered back on the RPE scale it was stored on, and it must parse to the same rating in any
        // locale — the field is typed by a human, so "9" and "9,0" both have to survive the round trip.
        let reopened = try XCTUnwrap(restored.first)
        XCTAssertFalse(reopened.usesRIR)
        XCTAssertEqual(try GenericStrengthDetailsSheet.rating(for: reopened), 9)
    }

    func testReopeningAnEmptyEntryOffersAFreshForm() {
        XCTAssertTrue(GenericStrengthDetailsSheet.drafts(from: nil, templates: [:]).isEmpty)
    }
}

import XCTest
@testable import WhoopStore

/// Pins the wearer's recovery answers.
///
/// These rows are the only ground truth this app has about how fast training load fades, so the two
/// things worth holding are that an answer survives a round trip intact, and that answering twice does
/// not turn one opinion into two data points.
final class MuscleRecoveryStoreTests: XCTestCase {

    func testAnAnswerSurvivesARoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveMuscleRecoveryFeedback(
            .init(muscleGroup: .quadriceps, ts: 1_800_000_000, feeling: 2))

        let rows = try await store.muscleRecoveryFeedback()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.muscleGroup, .quadriceps)
        XCTAssertEqual(rows.first?.ts, 1_800_000_000)
        XCTAssertEqual(rows.first?.feeling, 2)
    }

    /// A double tap is one opinion. Two rows would weight that evening twice in the fit.
    func testAnsweringTwiceAtTheSameMomentReplacesRatherThanDuplicates() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveMuscleRecoveryFeedback(
            .init(muscleGroup: .chest, ts: 1_800_000_000, feeling: 0))
        try await store.saveMuscleRecoveryFeedback(
            .init(muscleGroup: .chest, ts: 1_800_000_000, feeling: 3))

        let rows = try await store.muscleRecoveryFeedback()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.feeling, 3, "the later answer wins")
    }

    /// Different muscles at the same moment are different answers, not a conflict.
    func testTwoMusclesCanBeAnsweredAtTheSameMoment() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.saveMuscleRecoveryFeedback(
            .init(muscleGroup: .chest, ts: 1_800_000_000, feeling: 1))
        try await store.saveMuscleRecoveryFeedback(
            .init(muscleGroup: .triceps, ts: 1_800_000_000, feeling: 2))
        let rows = try await store.muscleRecoveryFeedback()
        XCTAssertEqual(rows.count, 2)
    }

    /// Answers come back oldest first, which is the order the recovery fit walks them in.
    func testAnswersComeBackOldestFirstAndHonourTheCutoff() async throws {
        let store = try await WhoopStore.inMemory()
        for ts in [1_800_000_300, 1_800_000_100, 1_800_000_200] {
            try await store.saveMuscleRecoveryFeedback(
                .init(muscleGroup: .lats, ts: ts, feeling: 1))
        }
        let all = try await store.muscleRecoveryFeedback()
        XCTAssertEqual(all.map(\.ts), [1_800_000_100, 1_800_000_200, 1_800_000_300])

        let recent = try await store.muscleRecoveryFeedback(since: 1_800_000_200)
        XCTAssertEqual(recent.map(\.ts), [1_800_000_200, 1_800_000_300])
    }
}

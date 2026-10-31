import XCTest
import GRDB
@testable import WhoopStore

final class ActivitySuggestionAnswerStoreTests: XCTestCase {
    private func answer(_ track: ActivitySuggestionAnswer.Track = .heartRate, start: Int = 1_000, end: Int = 2_000,
                        kind: ActivitySuggestionAnswer.Answer = .sport, sport: String? = "Strength Training",
                        shownAt: Int? = 2_600, answeredAt: Int = 3_000,
                        workout: ActivitySuggestionAnswer.WorkoutKey? = nil) -> ActivitySuggestionAnswer {
        ActivitySuggestionAnswer(track: track, candidateStartTs: start, candidateEndTs: end, answer: kind,
                                 sport: sport, origin: .today, shownKind: "Strength Training", shownScore: 0.42,
                                 modelVersion: "activity-v1", startWeightVersion: "start-v1",
                                 shownAtTs: shownAt, answeredAtTs: answeredAt, workout: workout)
    }

    func testAnswerRoundTripKeepsWhatWasShownAndTheSavedWorkout() async throws {
        let store = try await WhoopStore.inMemory()
        let saved = answer(workout: .init(deviceId: "manual", startTs: 1_000, sport: "Strength Training"))
        let stored = try await store.recordActivitySuggestionAnswer(saved)
        XCTAssertTrue(stored)
        let rows = try await store.activitySuggestionAnswers(from: 0, to: 5_000)
        XCTAssertEqual(rows, [saved])
        XCTAssertEqual(rows.first?.answerDelaySeconds, 400)
    }

    func testASecondAnswerReplacesTheFirstAndUndoReopensTheSuggestion() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.recordActivitySuggestionAnswer(answer())
        let corrected = answer(kind: .everyday, sport: nil, answeredAt: 3_500)
        try await store.recordActivitySuggestionAnswer(corrected)
        var rows = try await store.activitySuggestionAnswers(from: 0, to: 5_000)
        XCTAssertEqual(rows, [corrected])

        let removed = try await store.deleteActivitySuggestionAnswer(track: .heartRate, candidateStartTs: 1_000)
        XCTAssertTrue(removed)
        rows = try await store.activitySuggestionAnswers(from: 0, to: 5_000)
        XCTAssertTrue(rows.isEmpty)
        let removedAgain = try await store.deleteActivitySuggestionAnswer(track: .heartRate, candidateStartTs: 1_000)
        XCTAssertFalse(removedAgain)
    }

    func testTheTwoTracksKeepSeparateAnswersForTheSameStart() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.recordActivitySuggestionAnswer(answer(.walk, kind: .walk, sport: nil))
        try await store.recordActivitySuggestionAnswer(answer(.heartRate, kind: .housework, sport: nil))
        let rows = try await store.activitySuggestionAnswers(from: 0, to: 5_000)
        XCTAssertEqual(rows.map(\.answer), [.housework, .walk])
    }

    func testOnlyAnAnswerOfSportCarriesASport() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.recordActivitySuggestionAnswer(answer(kind: .everyday, sport: "Running"))
        let rows = try await store.activitySuggestionAnswers(from: 0, to: 5_000)
        XCTAssertNil(rows.first?.sport)
    }

    func testRowsThatCannotBeARealAnswerAreRefused() async throws {
        let store = try await WhoopStore.inMemory()
        let emptySpan = try await store.recordActivitySuggestionAnswer(answer(start: 2_000, end: 2_000))
        let noSport = try await store.recordActivitySuggestionAnswer(answer(sport: "  "))
        var badScore = answer()
        badScore.shownScore = .nan
        let nanScore = try await store.recordActivitySuggestionAnswer(badScore)
        XCTAssertEqual([emptySpan, noSport, nanScore], [false, false, false])
        let rows = try await store.activitySuggestionAnswers(from: 0, to: 5_000)
        XCTAssertTrue(rows.isEmpty)
    }

    func testTheRangeReadReturnsOverlappingSpansOnly() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.recordActivitySuggestionAnswer(answer(start: 1_000, end: 2_000))
        try await store.recordActivitySuggestionAnswer(answer(start: 5_000, end: 6_000))
        let rows = try await store.activitySuggestionAnswers(from: 1_900, to: 5_000)
        XCTAssertEqual(rows.map(\.candidateStartTs), [1_000])
    }

    func testAValueFromANewerBuildIsSkippedNotMisread() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.recordActivitySuggestionAnswer(answer())
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE activitySuggestionAnswer SET answer = 'commute'")
        }
        let rows = try await store.activitySuggestionAnswers(from: 0, to: 5_000)
        XCTAssertTrue(rows.isEmpty)
    }

    func testTheAnswersTravelInTheBackupSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.recordActivitySuggestionAnswer(answer())
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("answers-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await store.writeBackupSnapshot(to: path)
        let copy = try DatabaseQueue(path: path)
        let count = try await copy.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activitySuggestionAnswer")
        }
        XCTAssertEqual(count, 1)
    }
}

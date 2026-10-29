import XCTest
import StrandCore
import StrandTraining
import WhoopStore
import WhoopProtocol

final class SessionRatingRemindersTests: XCTestCase {
    func testOneClockBoundsPlanningAndLateDelivery() {
        XCTAssertEqual(SessionRatingReminders.fireTime(startTs: 100, endTs: 200, now: 201), 2_000)
        XCTAssertNil(SessionRatingReminders.fireTime(startTs: 100, endTs: 200, now: 2_000))
        XCTAssertEqual(SessionRatingReminders.fireTime(startTs: 100, endTs: 200, now: 2_000, forDelivery: true), 2_000)
        XCTAssertNil(SessionRatingReminders.fireTime(startTs: 100, endTs: 200, now: 2_901, forDelivery: true))
        XCTAssertNil(SessionRatingReminders.fireTime(startTs: 100, endTs: 200, now: 199))
        XCTAssertNil(SessionRatingReminders.fireTime(startTs: 200, endTs: 200, now: 201))
        XCTAssertNil(SessionRatingReminders.fireTime(startTs: 100, endTs: Int.max, now: Int.max))
    }

    func testDeliveryRechecksTheCanonicalRatingAndDeletedWorkout() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap", registeredWhoopIds: [])
        var draft = WorkoutDraft(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, title: "Synthetic strength", startedAt: 6_000, plannedDay: "1970-01-01")
        var set = NativeWorkoutSet(index: 0, weightKg: 20, reps: 8); set.isCompleted = true
        draft.exercises = [.init(exerciseId: "squat", sets: [set])]
        let workout = try NativeWorkoutEngine.complete(draft: draft, endTs: 9_000, sessionRPE: nil)
        try await store.completeNativeWorkout(workout)
        func candidates(_ prompt: SessionRatingPrompt = .whenUseful, now: Int = 10_000, delivery: Bool = false) async -> [SessionRatingReminders.Candidate] {
            await SessionRatingReminders.candidates(reader: reader, prompt: prompt, maxHR: 190,
                dismissed: [], now: now, forDelivery: delivery)
        }
        let pending = await candidates()
        XCTAssertEqual(pending.count, 1)
        let candidate = try XCTUnwrap(pending.first)
        XCTAssertEqual(candidate.fireTs, 10_800)
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/training/rating-reminders.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pending)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try data.write(to: file) }
        let pinned = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSArray
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSArray, pinned)
        let disabled = await candidates(.off)
        XCTAssertTrue(disabled.isEmpty)
        try await store.upsertTrainingSessionRating(.init(id: "other-session", sessionId: "unrelated",
            workoutStartTs: 6_000, ratedAtTs: 10_000, rpe: 4, sport: "Run", source: "imported"))
        let unrelated = await candidates(now: 10_800, delivery: true)
        XCTAssertEqual(unrelated, pending, "a canonical rating cannot suppress an unrelated session at the same second")
        try await store.upsertTrainingSessionRating(.init(id: "answer", sessionId: candidate.sessionId,
            workoutStartTs: 6_000, ratedAtTs: 10_800, rpe: 8, sport: candidate.sport, source: TrainingSessionRating.manualSource))
        let rated = await candidates(now: 10_800, delivery: true)
        XCTAssertTrue(rated.isEmpty)
        _ = try await store.deleteTrainingSessionRating(id: "answer")
        try await store.deleteNativeWorkout(id: workout.id)
        let deleted = await candidates(now: 10_800, delivery: true)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testThePolicyChoiceAndSourceSpecificHeartRateAreShared() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap", registeredWhoopIds: [])
        let easy = await SessionRatingReminders.isWorthAsking(reader: reader, startTs: 100, endTs: 700,
            sport: "Walking", source: "", averageHR: 80, restingHR: 60, maxHR: 190, prompt: .whenUseful)
        XCTAssertFalse(easy)
        for (id, bpm) in [("strap", 190), ("gym", 80)] {
            try await store.insert(Streams(hr: (0..<120).map { HRSample(ts: 100 + $0 * 5, bpm: bpm) }), deviceId: id)
        }
        let sourceSpecific = await SessionRatingReminders.isWorthAsking(reader: reader, startTs: 100, endTs: 700,
            sport: "Walking", source: "native-training:gym", averageHR: nil, restingHR: 60, maxHR: 190, prompt: .whenUseful)
        XCTAssertFalse(sourceSpecific, "the gym recording must not borrow the active strap's high heart rate")
        let always = await SessionRatingReminders.isWorthAsking(reader: reader, startTs: 100, endTs: 700,
            sport: "Walking", source: "", averageHR: 80, restingHR: 60, maxHR: 190, prompt: .always)
        XCTAssertTrue(always)
        let off = await SessionRatingReminders.isWorthAsking(reader: reader, startTs: 100, endTs: 700,
            sport: "Strength Training", source: "", averageHR: nil, restingHR: nil, maxHR: nil, prompt: .off)
        XCTAssertFalse(off)
    }
}

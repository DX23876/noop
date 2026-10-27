import XCTest
@testable import NoopCore
import StrandCore
import StrandAnalytics
import StrandTraining
import WhoopProtocol
import WhoopStore

final class CoreTrainingSessionTests: XCTestCase {
    private let start = 1_793_016_000
    private var now: Int { start + 5_400 }
    private var zones: HRZoneSet { HRZones.zones(bpmEdges: [100, 120, 140, 160, 180, 200], maxHR: 200) }

    private func fixture() async throws -> StoreReader {
        let store = try await WhoopStore.inMemory()
        let bench = HevyExerciseTemplate(id: "bench", title: "Bench press", type: "weight_reps",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps], equipment: .barbell, isCustom: false)
        let pullup = HevyExerciseTemplate(id: "pullup", title: "Pull-up", type: "bodyweight_reps",
            primaryMuscleGroup: .lats, secondaryMuscleGroups: [.biceps], equipment: .none, isCustom: false)
        _ = try await store.upsertHevyExerciseTemplates([bench, pullup])
        func set(_ index: Int, _ type: HevySetType, _ kg: Double?, _ reps: Int, _ rpe: Double?) -> HevySet {
            .init(index: index, type: type, weightKg: kg, reps: reps, distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
        }
        let workout = HevyWorkout(id: "qa-push", title: "Push and pull", routineId: nil, notes: "Synthetic session note",
            startTs: start, endTs: start + 3_600, updatedAtTs: start, createdAtTs: start,
            exercises: [HevyExercise(index: 0, title: "Bench press", templateId: "bench", supersetId: 1,
                notes: "Synthetic exercise note", sets: [set(0, .warmup, 20, 10, nil), set(1, .normal, 80, 8, 8)]),
                HevyExercise(index: 1, title: "Pull-up", templateId: "pullup", supersetId: 1, notes: nil,
                    sets: [set(0, .normal, nil, 10, nil)])], source: .hevyCSV)
        _ = try await store.upsertStrengthWorkouts([workout])
        _ = try await store.upsertWorkouts([WorkoutRow(startTs: start, endTs: start + 3_600,
            sport: "Strength Training", source: "gym-noop", durationS: 3_600, energyKcal: 300,
            avgHr: 135, maxHr: 140, strain: 5, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)], deviceId: "gym-noop")
        let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "weight", value: 80)], deviceId: "apple-health")
        try await store.insert(Streams(hr: (0..<60).map { HRSample(ts: start + $0 * 60, bpm: $0 < 30 ? 130 : 140) }), deviceId: "gym")
        try await store.insert(Streams(hr: (0..<60).map { HRSample(ts: start + $0 * 60, bpm: 190) }), deviceId: "active")
        return StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: ["gym"])
    }

    func testFullTranscriptKeepsWarmupsSupersetsWeightCoverageAndRecordingStrap() async throws {
        let reader = try await fixture()
        let result = try XCTUnwrap(awaitValue: await CoreTrainingSession.read(reader: reader, id: "qa-push", zoneSet: zones, dismissed: [], now: now))
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].count, 2)
        XCTAssertEqual(result.groups[0][0].sets.map(\.isWorking), [false, true])
        XCTAssertEqual(result.summary?.workingSets, 2)
        XCTAssertEqual(result.summary?.volumeSets, 1)
        XCTAssertEqual(result.summary?.volumeKg, 640)
        XCTAssertEqual(result.summary?.bodyweightVolumeKg, 800)
        XCTAssertNil(result.summary?.densityKgPerMinute, "partial volume does not describe the whole session's density")
        XCTAssertEqual(result.groups[0][0].sets[1].e1rmKg ?? 0, 106.66666666666666, accuracy: 1e-10)
        XCTAssertNil(result.groups[0][1].sets[0].e1rmKg)
        XCTAssertEqual(result.heartRate.count, 60)
        XCTAssertTrue(result.heartRate.allSatisfy { (130...140).contains($0.bpm) })
        XCTAssertEqual(result.zoneMinutes, [0, 30, 30, 0, 0])
        XCTAssertNil(result.rating, "set RPE 8 never becomes a whole-session rating")
        try contract(result, name: "session-strength")
    }

    func testWholeSessionRatingEditsReopenAndRemovalKeepsTheWorkout() async throws {
        let reader = try await fixture()
        let saved = await CoreTrainingSession.rate(reader: reader, id: "qa-push", rpe: 7.5, remove: false, dismissed: [], now: now)
        XCTAssertTrue(saved)
        var result = try XCTUnwrap(awaitValue: await CoreTrainingSession.read(reader: reader, id: "qa-push", zoneSet: zones, dismissed: [], now: now))
        XCTAssertEqual(result.rating?.rpe, 7.5)
        XCTAssertEqual(result.rating?.loadAU, 450)
        XCTAssertEqual(result.rating?.timing, "about30Minutes")
        XCTAssertEqual(result.summary?.meanRPE, 8, "whole-session RPE does not rewrite set-level observation")
        let edited = await CoreTrainingSession.rate(reader: reader, id: result.canonicalId ?? result.id,
            rpe: 9, remove: false, dismissed: [], now: now + 3_600)
        XCTAssertTrue(edited)
        let rows = await SessionRPEEntry.read(store: reader.store, from: 0, to: Int.max)
        XCTAssertEqual(rows.count, 1)
        result = try XCTUnwrap(awaitValue: await CoreTrainingSession.read(reader: reader, id: "qa-push", zoneSet: zones, dismissed: [], now: now))
        XCTAssertEqual(result.rating?.rpe, 9)
        XCTAssertEqual(result.rating?.loadAU, 540)
        try contract(result, name: "session-rated")
        let removed = await CoreTrainingSession.rate(reader: reader, id: "qa-push", rpe: nil, remove: true, dismissed: [], now: now)
        XCTAssertTrue(removed)
        let remaining = await CoreTrainingSession.read(reader: reader, id: "qa-push", zoneSet: zones, dismissed: [], now: now)
        XCTAssertNotNil(remaining)
        XCTAssertNil(remaining?.rating)
        let invalid = await CoreTrainingSession.rate(reader: reader, id: "unknown", rpe: 5, remove: false, dismissed: [], now: now)
        XCTAssertFalse(invalid)
    }

    func testNativeTranscriptRetainsEachSideAndTimedDistanceFields() async throws {
        let store = try await WhoopStore.inMemory()
        let definitions = [TrainingExercise(id: "qa-sides", title: "Split exercise", mode: .repetitions,
            primaryMuscleId: "quadriceps", isUnilateral: true),
            TrainingExercise(id: "qa-time", title: "Carry", mode: .distanceDuration, primaryMuscleId: "forearms")]
        try await store.upsertTrainingExercises(definitions, nowTs: now)
        let workout = NativeWorkout(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, title: "Synthetic native session",
            startedAt: start, endedAt: start + 600, plannedDay: "2026-10-26", routineIds: [],
            exercises: [NativeWorkoutExercise(exerciseId: "qa-sides", sets: [.init(index: 0, leftReps: 10, rightReps: 12, isCompleted: true)]),
                NativeWorkoutExercise(exerciseId: "qa-time", sets: [.init(index: 0, durationS: 75, distanceM: 120, isCompleted: true)])], tracker: nil)
        try await store.upsertNativeWorkouts([workout])
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])
        let result = try XCTUnwrap(awaitValue: await CoreTrainingSession.read(reader: reader, id: "noop-native:\(workout.id.uuidString)", zoneSet: zones, dismissed: [], now: now))
        let sets = result.groups.flatMap { $0 }.flatMap(\.sets)
        XCTAssertEqual(sets[0].leftReps, 10)
        XCTAssertEqual(sets[0].rightReps, 12)
        XCTAssertEqual(sets[1].durationS, 75)
        XCTAssertEqual(sets[1].distanceM, 120)
        XCTAssertTrue(result.heartRate.isEmpty)
        XCTAssertNil(result.zoneMinutes)
        try contract(result, name: "session-native")
    }

    func testFinishingFromAndroidKeepsTheExplicitWholeSessionRating() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])
        let created = await CoreTrainingLibrary.create(store: store, title: "Synthetic timed exercise", mode: "duration",
            primary: "abdominals", equipment: "", instruction: "", unilateral: false)
        let exerciseId = try XCTUnwrap(created)
        _ = await CoreTraining.startDraft(reader: reader, routineIds: [], dismissedWorkoutSpans: [])
        let draft = await CoreTraining.changeDraft(store: store, args: ["change": "addExercise", "exerciseId": exerciseId])
        let exercise = try XCTUnwrap(draft?.exercises.first)
        let set = try XCTUnwrap(exercise.sets.first)
        _ = await CoreTraining.changeDraft(store: store, args: ["change": "set", "exercise": exercise.id.uuidString,
            "set": set.id.uuidString, "durationS": 75, "done": true])
        let finished = await CoreTraining.finishDraft(store: store, sessionRPE: 7.5)
        XCTAssertNotNil(finished)
        let ratings = await SessionRPEEntry.read(store: store, from: 0, to: Int.max)
        XCTAssertEqual(ratings.count, 1)
        XCTAssertEqual(ratings.first?.rpe, 7.5, "finishing in Kotlin must persist the same rating read by Training Load")
        let invalid = await SessionRPEEntry.record(store: store, rpe: .nan, startTs: 1,
            sport: "Synthetic", sessionId: nil, ratedAtTs: 2)
        XCTAssertFalse(invalid)
    }

    func testCardioDetailOpensItsCanonicalIdWithoutInferringAHeartRateTrace() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "active", registeredWhoopIds: [])
        _ = try await store.upsertWorkouts([WorkoutRow(startTs: start, endTs: start + 1_800,
            sport: "Running", source: "manual", durationS: 1_800, energyKcal: 200, avgHr: 140,
            maxHr: 170, strain: nil, distanceM: 5_000, zonesJSON: nil, notes: "Synthetic cardio note", steps: nil)], deviceId: "active")
        let report = await CoreTrainingReports.cardio(reader: reader, maxHR: 200, sex: "male", now: now)
        let id = try XCTUnwrap(report.sessions.first?.id)
        XCTAssertFalse(id.isEmpty)
        let detail = try XCTUnwrap(awaitValue: await CoreTrainingSession.read(reader: reader, id: id,
            zoneSet: zones, dismissed: [], now: now))
        XCTAssertEqual(detail.kind, "endurance")
        XCTAssertEqual(detail.durationS, 1_800)
        XCTAssertEqual(detail.distanceM, 5_000)
        XCTAssertEqual(detail.avgHr, 140)
        XCTAssertNil(detail.summary)
        XCTAssertTrue(detail.groups.isEmpty)
        XCTAssertTrue(detail.heartRate.isEmpty, "a recorded average does not supply a curve")
        XCTAssertNil(detail.zoneMinutes, "an average does not supply time in each zone")
        try contract(detail, name: "session-cardio")
    }

    func testRatingTimingUsesTheSameRoundedDelayAsApple() {
        func entry(_ delay: Int?) -> SessionRPEEntry {
            .init(id: "test", sessionId: nil, startTs: start, rpe: 7.5, sport: "Run",
                ratedAtTs: delay.map { start + 3_600 + $0 })
        }
        XCTAssertEqual(entry(nil).timing(durationS: 3_600), .unknown)
        XCTAssertEqual(entry(19 * 60).timing(durationS: 3_600), .immediately)
        XCTAssertEqual(entry(20 * 60).timing(durationS: 3_600), .about30Minutes)
        XCTAssertEqual(entry(45 * 60).timing(durationS: 3_600), .about30Minutes)
        XCTAssertEqual(entry(46 * 60).timing(durationS: 3_600), .later)
        XCTAssertNil(entry(30).load(durationS: nil))
        XCTAssertNil(entry(30).load(durationS: 0))
        XCTAssertEqual(entry(30).load(durationS: 75), 9.375)
    }

    private func contract(_ value: CoreTrainingSession.Output, name: String) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/training/\(name).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try data.write(to: file) }
        func shape(_ value: Any) -> String {
            if let o = value as? [String: Any] { return "{" + o.keys.sorted().map { "\($0):\(shape(o[$0]!))" }.joined(separator: ",") + "}" }
            if let a = value as? [Any] { return "[" + Set(a.map(shape)).sorted().joined(separator: ",") + "]" }
            return value is NSNumber ? "number" : "string"
        }
        XCTAssertEqual(shape(try JSONSerialization.jsonObject(with: data)), shape(try JSONSerialization.jsonObject(with: Data(contentsOf: file))))
    }
}

private func XCTUnwrap<T>(awaitValue value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

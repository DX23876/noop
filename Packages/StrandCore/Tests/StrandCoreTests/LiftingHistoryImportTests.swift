import XCTest
import StrandCore
import WhoopStore

final class LiftingHistoryImportTests: XCTestCase {
    private let zone = TimeZone(identifier: "Europe/Berlin")!
    private func csv(title: String = "Push day", weight: Int = 80) -> Data {
        Data("""
        title,start_time,end_time,exercise_title,set_type,weight_kg,reps,rpe
        \(title),2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,warmup,20,10,
        \(title),2026-06-01 18:00:00,2026-06-01 19:00:00,Bench Press,normal,\(weight),8,8
        \(title),2026-06-01 18:00:00,2026-06-01 19:00:00,Pull-up,normal,,10,
        """.utf8)
    }

    func testFullTranscriptAndListProjectionSurviveReimportAndRename() async throws {
        let store = try await WhoopStore.inMemory()
        let result = try await LiftingHistoryImport.run(data: csv(), store: store, zone: zone)
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.sessions[0].volumeLoadKg, 640)
        let start = Int(result.sessions[0].start.timeIntervalSince1970)
        XCTAssertEqual(start, 1_780_329_600, "18:00 Berlin is 16:00 UTC in June")
        _ = try await LiftingHistoryImport.run(data: csv(), store: store, zone: zone)
        var rows = try await store.strengthWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].exercises.count, 2)
        XCTAssertEqual(rows[0].exercises[0].sets.map(\.type), [.warmup, .normal])
        XCTAssertEqual(rows[0].exercises[0].sets[1].rpe, 8)
        XCTAssertNil(rows[0].exercises[1].sets[0].weightKg)
        _ = try await LiftingHistoryImport.run(data: csv(title: "Renamed", weight: 90), store: store, zone: zone)
        rows = try await store.strengthWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Renamed")
        XCTAssertEqual(rows[0].exercises[0].sets[1].weightKg, 90)
        let mirrors = try await store.workouts(deviceId: "lifting", from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(mirrors.count, 1)
        XCTAssertNil(mirrors[0].strain)
        XCTAssertNil(mirrors[0].avgHr)
        XCTAssertNil(mirrors[0].energyKcal)
        XCTAssertEqual(mirrors[0].durationS, 3_600)
    }

    func testLiftosaurKeepsCompleteSetsAndAbsoluteTimes() async throws {
        let store = try await WhoopStore.inMemory()
        let data = Data(#"{"history":[{"startTime":1748772000000,"endTime":1748775600000,"dayName":"Day 1","entries":[{"sets":[{"weight":80,"completedReps":5},{"weight":80,"completedReps":5}]}]}]}"#.utf8)
        let result = try await LiftingHistoryImport.run(data: data, store: store, zone: zone)
        XCTAssertEqual(result.sessionCount, 1)
        let stored = try await store.strengthWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(stored[0].source, .liftosaur)
        XCTAssertEqual(stored[0].startTs, 1_748_772_000)
        XCTAssertEqual(stored[0].exercises[0].sets.count, 2)
        XCTAssertEqual(stored[0].exercises[0].sets[1].weightKg, 80)
    }

    func testInvalidFileWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        do {
            _ = try await LiftingHistoryImport.run(data: Data("bad input".utf8), store: store, zone: zone)
            XCTFail("must reject empty import")
        } catch LiftingHistoryImport.ImportError.noWorkouts {}
        let rows = try await store.strengthWorkouts(from: 0, to: Int.max)
        XCTAssertTrue(rows.isEmpty)
    }
}

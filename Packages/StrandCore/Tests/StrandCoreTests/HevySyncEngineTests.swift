import XCTest
import StrandCore
import WhoopStore

final class HevySyncEngineTests: XCTestCase {
    private enum Failure: Error { case interrupted }
    private actor Fetcher: HevyReadFetching {
        let bodies: [String: [Data]]
        let failPage: Int?
        private(set) var requests: [(String, [String: String])] = []
        init(_ bodies: [String: [Data]], failPage: Int? = nil) { self.bodies = bodies; self.failPage = failPage }
        func get(path: String, query: [String: String]) async throws -> Data {
            requests.append((path, query))
            let page = Int(query["page"] ?? "1")!
            if page == failPage { throw Failure.interrupted }
            if let pages = bodies[path], page <= pages.count { return pages[page - 1] }
            let key = path == "/workouts/events" ? "events" : String(path.dropFirst())
            return Data("{\"page_count\":1,\"\(key)\":[]}".utf8)
        }
        func paths() -> [String] { requests.map(\.0) }
    }
    private func page(_ key: String, _ items: [String], count: Int = 1) -> Data {
        Data("{\"page_count\":\(count),\"\(key)\":[\(items.joined(separator: ","))]}".utf8)
    }
    private let template = #"{"id":"T1","title":"Bench Press","type":"weight_reps","primary_muscle_group":"chest","equipment":"barbell"}"#
    private func workout(_ id: String, day: Int = 1, updated: Int = 1) -> String {
        """
        {"id":"\(id)","title":"Synthetic Hevy","start_time":"2026-09-0\(day)T17:00:00Z",
         "end_time":"2026-09-0\(day)T18:00:00Z","updated_at":"2026-09-0\(updated)T18:00:00Z",
         "exercises":[{"index":0,"title":"Bench Press","exercise_template_id":"T1","sets":[{"index":0,"type":"normal","weight_kg":80,"reps":8}]}]}
        """
    }
    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        _ = try await HevySyncEngine(fetcher: Fetcher([
            "/exercise_templates": [page("exercise_templates", [template])],
            "/workouts": [page("workouts", [workout("w1")])]]), store: store).run()
        return store
    }

    func testInterruptedBackfillCannotSkipTheOlderPagesOnRetry() async throws {
        let store = try await WhoopStore.inMemory()
        let pages = [page("workouts", [workout("w1")], count: 2), page("workouts", [workout("w2", day: 2)])]
        do {
            _ = try await HevySyncEngine(fetcher: Fetcher([
                "/exercise_templates": [page("exercise_templates", [template])], "/workouts": pages], failPage: 2), store: store).run()
            XCTFail("the second page must fail")
        } catch Failure.interrupted {}
        let incomplete = try await store.cursor("hevy:backfillComplete")
        XCTAssertNil(incomplete)
        let retry = Fetcher(["/workouts": pages])
        let summary = try await HevySyncEngine(fetcher: retry, store: store).run()
        XCTAssertTrue(summary.wasBackfill)
        let stored = try await store.hevyWorkoutCount()
        XCTAssertEqual(stored, 2)
        let next = Fetcher([:])
        _ = try await HevySyncEngine(fetcher: next, store: store).run()
        let paths = await next.paths()
        XCTAssertTrue(paths.contains("/workouts/events"))
        XCTAssertFalse(paths.contains("/workouts"))
    }

    func testPagingGrowthAndTheFinalEventPassDoNotMissOrDoubleCountSessions() async throws {
        let store = try await WhoopStore.inMemory()
        let changed = "{\"type\":\"updated\",\"workout\":\(workout("w4", day: 4, updated: 4))}"
        let unknownDeletion = #"{"type":"deleted","id":"never-local","deleted_at":"2026-09-05T18:00:00Z"}"#
        let fetcher = Fetcher([
            "/exercise_templates": [page("exercise_templates", [template])],
            "/workouts": [page("workouts", [workout("w1")], count: 2),
                page("workouts", [workout("w1"), workout("w2", day: 2)], count: 3),
                page("workouts", [workout("w3", day: 3)], count: 3)],
            "/workouts/events": [page("events", [changed, unknownDeletion])]])
        let result = try await HevySyncEngine(fetcher: fetcher, store: store).run()
        let count = try await store.hevyWorkoutCount()
        XCTAssertEqual(count, 4)
        XCTAssertEqual(result.fetchedWorkouts, 4, "page overlap must not inflate the processed-session count")
        XCTAssertEqual(result.deletedWorkouts, 0, "a remote deletion is not evidence of a local row being removed")
    }

    func testNewestEditWinsAndItsOldProjectionIsRemoved() async throws {
        let store = try await seeded()
        let newer = "{\"type\":\"updated\",\"workout\":\(workout("w1", day: 3, updated: 4))}"
        let older = "{\"type\":\"updated\",\"workout\":\(workout("w1", day: 2, updated: 2))}"
        _ = try await HevySyncEngine(fetcher: Fetcher(["/workouts/events": [page("events", [newer, older])]]), store: store).run()
        let rows = try await store.workouts(deviceId: "hevy", from: 0, to: Int.max, limit: 100)
        let logs = try await store.hevyWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(rows[0].startTs, logs[0].startTs)
        XCTAssertEqual(logs[0].startTs, 1_788_454_800)
        XCTAssertNil(rows[0].strain)
        let metadata = try await store.workoutSourceMetadata(from: 0, to: Int.max)
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata[0].startTs, rows[0].startTs)
        let deletion = #"{"type":"deleted","id":"w1","deleted_at":"2026-09-05T18:00:00Z"}"#
        _ = try await HevySyncEngine(fetcher: Fetcher(["/workouts/events": [page("events", [deletion])]]), store: store).run()
        let after = try await store.workouts(deviceId: "hevy", from: 0, to: Int.max, limit: 100)
        XCTAssertTrue(after.isEmpty)
    }

    func testFailedEventPageOrMalformedSetCannotAdvanceTheFrontier() async throws {
        let store = try await seeded()
        let frontier = try await store.cursor("hevy:syncFrontier")
        let original = try await store.hevyWorkouts(from: 0, to: Int.max)
        let changed = "{\"type\":\"updated\",\"workout\":\(workout("w1", day: 3, updated: 4))}"
        do {
            _ = try await HevySyncEngine(fetcher: Fetcher(["/workouts/events": [page("events", [changed], count: 2)]], failPage: 2), store: store).run()
            XCTFail("the second page must fail")
        } catch Failure.interrupted {}
        var rows = try await store.hevyWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(rows, original)
        let malformed = changed.replacingOccurrences(of: "\"weight_kg\":80,\"reps\":8", with: "\"weight_kg\":null,\"reps\":null")
        let result = try await HevySyncEngine(fetcher: Fetcher(["/workouts/events": [page("events", [malformed])]]), store: store).run()
        XCTAssertGreaterThan(result.skipped, 0)
        rows = try await store.hevyWorkouts(from: 0, to: Int.max)
        XCTAssertEqual(rows, original)
        let after = try await store.cursor("hevy:syncFrontier")
        XCTAssertEqual(after, frontier)
    }
}

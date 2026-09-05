import XCTest
import WhoopStore
@testable import Strand

/// Pins the Hevy sync's behaviour against a scripted API, with no network.
///
/// Two properties carry most of the weight here.
///
/// **It must not re-fetch the world.** Hevy caps list pages at ten items, so a full backfill of a real
/// training history is dozens of requests. Steady state has to be the `events?since=` feed, and a run
/// with nothing new has to be one request that writes nothing.
///
/// **It must not invalidate an analysis day.** A logged set changes no NOOP score — Charge, Effort and
/// Rest come from heart rate, HRV and sleep. Marking days here would trigger a 21-day re-score after
/// every gym session, which is the exact behaviour this app has spent a lot of effort removing. The
/// test for it is at the bottom, and it is deliberately strict.
final class HevySyncCoordinatorTests: XCTestCase {

    // MARK: - A scripted API

    /// Answers by path prefix and records what was asked, so a test can assert on the REQUESTS as well
    /// as on the resulting rows — "it did not ask for the whole history" is the property, and only the
    /// request log can show it.
    private actor FakeFetcher: HevyFetching {
        var responses: [String: [Data]] = [:]      // path → one body per page
        private(set) var requested: [String] = []

        init(_ responses: [String: [Data]]) { self.responses = responses }

        func get(path: String, query: [String: String]) async throws -> Data {
            let page = Int(query["page"] ?? "1") ?? 1
            requested.append(path)
            guard let pages = responses[path], page - 1 < pages.count else {
                return Data(#"{"page":1,"page_count":1}"#.utf8)
            }
            return pages[page - 1]
        }
        func post(path: String, body: Data) async throws -> Data { Data("{}".utf8) }
        func put(path: String, body: Data) async throws -> Data { Data("{}".utf8) }

        func paths() -> [String] { requested }
        func count(of path: String) -> Int { requested.filter { $0 == path }.count }
    }

    // MARK: - Fixtures

    private func workoutJSON(id: String, start: String, updated: String,
                             templateId: String = "T1") -> String {
        """
        { "id": "\(id)", "title": "Push Day", "start_time": "\(start)",
          "end_time": "\(start)", "updated_at": "\(updated)", "created_at": "\(start)",
          "exercises": [ { "index": 0, "title": "Bench", "exercise_template_id": "\(templateId)",
            "sets": [ { "index": 0, "type": "warmup", "weight_kg": 40, "reps": 10 },
                      { "index": 1, "type": "normal", "weight_kg": 100, "reps": 5 } ] } ] }
        """
    }

    private func page(_ key: String, _ objects: [String], pageCount: Int = 1) -> Data {
        Data("""
        {"page":1,"page_count":\(pageCount),"\(key)":[\(objects.joined(separator: ","))]}
        """.utf8)
    }

    private var catalogue: Data {
        page("exercise_templates", ["""
        { "id": "T1", "title": "Bench Press (Barbell)", "type": "weight_reps",
          "primary_muscle_group": "chest", "secondary_muscle_groups": ["triceps"],
          "equipment": "barbell", "is_custom": false }
        """])
    }

    override func setUp() {
        super.setUp()
        HevySyncState.reset()
    }
    override func tearDown() {
        HevySyncState.reset()
        super.tearDown()
    }

    // MARK: - The first run

    func testAFirstRunBackfillsTheHistoryAndTheCatalogue() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
                workoutJSON(id: "w2", start: "2026-09-03T17:00:00Z", updated: "2026-09-03T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        let summary = try await HevySyncCoordinator(fetcher: fetcher, store: store).run()

        XCTAssertTrue(summary.wasBackfill)
        XCTAssertEqual(summary.fetchedWorkouts, 2)
        XCTAssertEqual(summary.templates, 1)
        let stored = try await store.hevyWorkoutCount()
        XCTAssertEqual(stored, 2)
        // It went down the whole-history path, not the incremental one.
        let askedEvents = await fetcher.count(of: "/workouts/events")
        XCTAssertEqual(askedEvents, 0)
    }

    /// Every synced session also appears in the shared workout table, so the Workouts list, Today and
    /// the coach's existing tools see it without learning about a second workout model.
    func testEachSessionIsMirroredAsAWorkoutRowWithNoStrain() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: fetcher, store: store).run()

        let rows = try await store.workouts(deviceId: HevySource.id, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sport, HevySource.sport)
        XCTAssertNil(row.strain, "lifting volume must never arrive as cardiovascular strain")
        XCTAssertNil(row.avgHr, "HR is filled read-side from the strap trace, not invented here")
        XCTAssertEqual(row.notes?.contains("2 working sets"), false,
                       "the warmup is not a working set")
        XCTAssertEqual(row.notes?.contains("1 working set"), true)
    }

    // MARK: - Steady state

    /// THE cost property. Once anything is stored, a run asks the incremental feed and NEVER the full
    /// list — the difference between one request and sixty on every launch.
    func testASecondRunUsesTheIncrementalFeedAndNotTheFullList() async throws {
        let store = try await WhoopStore.inMemory()
        let first = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: first, store: store).run()

        let second = FakeFetcher(["/workouts/events": [page("events", [])]])
        let summary = try await HevySyncCoordinator(fetcher: second, store: store).run()

        XCTAssertFalse(summary.wasBackfill)
        XCTAssertEqual(summary.fetchedWorkouts, 0)
        let askedWorkouts = await second.count(of: "/workouts")
        XCTAssertEqual(askedWorkouts, 0, "a steady-state run must not walk the history again")
        let askedCatalogue = await second.count(of: "/exercise_templates")
        XCTAssertEqual(askedCatalogue, 0, "the catalogue was refreshed under a week ago")
    }

    /// The cursor is the newest stored `updated_at`, and it is what the next run asks from.
    func testTheCursorFollowsTheNewestStoredUpdate() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
                workoutJSON(id: "w2", start: "2026-09-03T17:00:00Z", updated: "2026-09-04T09:30:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: fetcher, store: store).run()
        let cursor = try await store.hevyNewestUpdatedAt()
        XCTAssertEqual(cursor, 1_788_514_200)   // 2026-09-04T09:30:00Z
    }

    /// An edit delivered through the feed replaces the session rather than adding a second one.
    func testAnEditFromTheFeedUpdatesInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        let first = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: first, store: store).run()

        let edited = """
        { "type": "updated", "workout": { "id": "w1", "title": "Push Day (edited)",
          "start_time": "2026-09-01T17:00:00Z", "end_time": "2026-09-01T18:30:00Z",
          "updated_at": "2026-09-02T08:00:00Z", "created_at": "2026-09-01T17:00:00Z",
          "exercises": [ { "index": 0, "title": "Bench", "exercise_template_id": "T1",
            "sets": [ { "index": 0, "type": "normal", "weight_kg": 105, "reps": 5 } ] } ] } }
        """
        let second = FakeFetcher(["/workouts/events": [page("events", [edited])]])
        let summary = try await HevySyncCoordinator(fetcher: second, store: store).run()

        XCTAssertEqual(summary.fetchedWorkouts, 1)
        let count = try await store.hevyWorkoutCount()
        XCTAssertEqual(count, 1, "an edit is not a second session")
        let stored = try await store.hevyWorkouts(from: 0, to: 2_000_000_000)
        XCTAssertEqual(stored.first?.title, "Push Day (edited)")
        XCTAssertEqual(stored.first?.exercises.first?.sets.count, 1, "the dropped warmup is gone")
    }

    /// A delete removes the session, its sets AND its mirrored `WorkoutRow`. Leaving the mirror behind
    /// would keep showing a session the user removed in Hevy, with no way to get rid of it.
    func testADeleteRemovesTheSessionAndItsMirroredRow() async throws {
        let store = try await WhoopStore.inMemory()
        let first = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
                workoutJSON(id: "w2", start: "2026-09-03T17:00:00Z", updated: "2026-09-03T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: first, store: store).run()

        let second = FakeFetcher(["/workouts/events": [page("events", [
            #"{"type":"deleted","id":"w1","deleted_at":"2026-09-05T10:00:00Z"}"#,
        ])]])
        let summary = try await HevySyncCoordinator(fetcher: second, store: store).run()

        XCTAssertEqual(summary.deletedWorkouts, 1)
        let count = try await store.hevyWorkoutCount()
        XCTAssertEqual(count, 1)
        let rows = try await store.workouts(deviceId: HevySource.id, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(rows.count, 1, "the mirrored row for the deleted session must go too")
        XCTAssertEqual(rows.first?.startTs, 1_788_454_800)   // w2 survived
    }

    /// A session edited and then deleted arrives as BOTH events on one page. The final state has to
    /// match Hevy regardless of which order the page listed them in.
    func testAnEditFollowedByADeleteEndsUpDeleted() async throws {
        let store = try await WhoopStore.inMemory()
        let first = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: first, store: store).run()

        let second = FakeFetcher(["/workouts/events": [page("events", [
            #"{"type":"deleted","id":"w1","deleted_at":"2026-09-05T10:00:00Z"}"#,
            """
            { "type": "updated", "workout": { "id": "w1", "title": "Push",
              "start_time": "2026-09-01T17:00:00Z", "updated_at": "2026-09-05T09:00:00Z" } }
            """,
        ])]])
        _ = try await HevySyncCoordinator(fetcher: second, store: store).run()

        let count = try await store.hevyWorkoutCount()
        XCTAssertEqual(count, 0, "the delete is the later truth and must win")
    }

    // MARK: - Idempotence

    /// Running the same incremental page twice converges. Hevy's `since` is inclusive by its own
    /// wording, so a boundary-second workout genuinely IS re-delivered on the next run.
    func testReplayingTheSamePageTwiceChangesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        let backfill = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: backfill, store: store).run()

        let repeated = """
        { "type": "updated", "workout": \(workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z",
                                                      updated: "2026-09-01T18:00:00Z")) }
        """
        for _ in 0..<2 {
            let f = FakeFetcher(["/workouts/events": [page("events", [repeated])]])
            _ = try await HevySyncCoordinator(fetcher: f, store: store).run()
        }

        let count = try await store.hevyWorkoutCount()
        XCTAssertEqual(count, 1)
        let rows = try await store.workouts(deviceId: HevySource.id, from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(rows.count, 1)
        let stored = try await store.hevyWorkouts(from: 0, to: 2_000_000_000)
        XCTAssertEqual(stored.first?.exercises.first?.sets.count, 2)
    }

    // MARK: - The catalogue

    /// A workout naming an exercise the catalogue lacks triggers ONE targeted re-pull, rather than
    /// leaving its sets permanently unattributable to a muscle group.
    func testAnUnknownExerciseTriggersACatalogueRefresh() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z",
                            updated: "2026-09-01T18:00:00Z", templateId: "CUSTOM99"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: fetcher, store: store).run()

        let asked = await fetcher.count(of: "/exercise_templates")
        XCTAssertEqual(asked, 2, "once up front, once because the session named an unknown movement")
    }

    // MARK: - The property this whole lane is judged on

    /// A Hevy sync must NOT mark any analysis day as changed.
    ///
    /// A logged set adds no heart rate, no HRV and no sleep, so it moves no score. Marking days here
    /// would make every gym session cost a 21-day re-derivation — the failure this app spent
    /// considerable effort eliminating, reintroduced through a new door. The `analysisInputRevision`
    /// table staying empty for these days is the check.
    func testASyncDoesNotInvalidateAnyAnalysisDay() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = FakeFetcher([
            "/exercise_templates": [catalogue],
            "/workouts": [page("workouts", [
                workoutJSON(id: "w1", start: "2026-09-01T17:00:00Z", updated: "2026-09-01T18:00:00Z"),
            ])],
            "/routines": [page("routines", [])],
        ])
        _ = try await HevySyncCoordinator(fetcher: fetcher, store: store).run()

        // The window the session falls in, probed exactly as `IntelligenceEngine` probes it.
        let start = 1_788_282_000
        for deviceId in [HevySource.id, "my-whoop", "my-whoop-noop"] {
            let revision = try await store.analysisInputRevision(deviceId: deviceId,
                                                                 from: start - 86_400,
                                                                 to: start + 86_400)
            XCTAssertEqual(revision.inputRevision, 0,
                           "\(deviceId): a logged set changes no score and must not force a re-score")
        }
    }
}

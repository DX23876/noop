// Tests the OURA_CLOUD_IMPORT-gated Oura import lane; compiled only when the flag is set
// (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if OURA_CLOUD_IMPORT
import XCTest
import WhoopStore
@testable import StrandImport
@testable import Strand

/// A fetcher that serves canned page bodies per endpoint (and can fail chosen endpoints, like a scope 401).
private final class StubFetcher: OuraPageFetching {
    var pages: [String: [Data]] = [:]
    var capturedQueries: [String: [String: String]] = [:]
    var callCounts: [String: Int] = [:]
    var failEndpoints: Set<String> = []
    var failAfterCall: [String: Int] = [:]   // endpoint → allow this many calls, then throw (mimics a mid-run suspend)
    func fetchAllRaw(endpoint: String, query: [String: String]) async throws -> [Data] {
        capturedQueries[endpoint] = query
        callCounts[endpoint, default: 0] += 1
        if failEndpoints.contains(endpoint) { throw OuraError.badResponse(401, "token is not authorized") }
        if let limit = failAfterCall[endpoint], (callCounts[endpoint] ?? 0) > limit {
            throw OuraError.badResponse(500, "simulated interruption")
        }
        return pages[endpoint] ?? []
    }
}

final class OuraSyncCoordinatorTests: XCTestCase {
    func testBackfillFetchesParsesAndWrites() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubFetcher()
        fetcher.pages["daily_readiness"] = [#"{"data":[{"day":"2026-01-02","score":80,"contributors":{"resting_heart_rate":50}}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.pages["daily_activity"] = [#"{"data":[{"day":"2026-01-02","steps":9000}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.pages["sleep"] = [#"{"data":[{"id":"s1","day":"2026-01-02","bedtime_start":"2026-01-01T23:00:00+00:00","bedtime_end":"2026-01-02T06:00:00+00:00","total_sleep_duration":24000,"lowest_heart_rate":48,"sleep_phase_5_min":"1234"}],"next_token":null}"#.data(using: .utf8)!]

        var progress: [String] = []
        let coord = OuraSyncCoordinator(fetcher: fetcher, store: store)
        let summary = try await coord.runFullImport(today: "2026-02-01") { progress.append($0.endpoint) }

        XCTAssertEqual(summary.days, 1)
        XCTAssertEqual(summary.sleeps, 1)
        XCTAssertTrue(summary.rawPages >= 3)
        XCTAssertTrue(progress.contains("sleep"))

        // Coalesce: daily_readiness's contributors.resting_heart_rate (50) is a 0-100 readiness SCORE, not
        // bpm, so it must NOT become restingHr — sleep's lowest_heart_rate (48) is the real resting HR.
        let days = try await store.dailyMetrics(deviceId: "oura-api", from: "2026-01-01", to: "2026-01-03")
        XCTAssertEqual(days.first?.restingHr, 48)
        XCTAssertEqual(days.first?.steps, 9000)
        XCTAssertEqual(days.first?.totalSleepMin, 400)
    }

    func testEndpointDateParamsAreWiredCorrectly() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubFetcher()
        // A daily page sets the heartrate window floor (2026-01-02); today 2026-02-01 → exactly two
        // 30-day windows. Heartrate has a hard ≤30-day range cap upstream, so windowing is load-bearing.
        fetcher.pages["daily_readiness"] = [#"{"data":[{"day":"2026-01-02","score":80}],"next_token":null}"#.data(using: .utf8)!]
        let coord = OuraSyncCoordinator(fetcher: fetcher, store: store)
        _ = try await coord.runFullImport(today: "2026-02-01")

        // Windowed, full ISO-'Z' datetimes (bare dates parse upstream but a +00:00 offset 422s), ≤30d each.
        XCTAssertEqual(fetcher.callCounts["heartrate"], 2)
        XCTAssertEqual(fetcher.capturedQueries["heartrate"]?["start_datetime"], "2026-02-01T00:00:00Z")
        XCTAssertEqual(fetcher.capturedQueries["heartrate"]?["end_datetime"], "2026-02-02T00:00:00Z")
        XCTAssertNil(fetcher.capturedQueries["heartrate"]?["start_date"])

        XCTAssertEqual(fetcher.capturedQueries["personal_info"], [:])
        XCTAssertEqual(fetcher.capturedQueries["ring_configuration"], [:])

        XCTAssertNotNil(fetcher.capturedQueries["daily_readiness"]?["start_date"])
        XCTAssertNotNil(fetcher.capturedQueries["daily_readiness"]?["end_date"])
    }

    func testHeartRateWindowPersistsBeforeAnInterruptionSoProgressSurvives() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubFetcher()
        // A daily day in early Jan floors the HR windows; today mid-March → several 30-day windows.
        fetcher.pages["daily_readiness"] = [#"{"data":[{"day":"2026-01-02","score":80}],"next_token":null}"#.data(using: .utf8)!]
        // Each heartrate window returns one sample, but the fetcher dies AFTER the first window —
        // exactly the screen-lock/suspend failure that used to lose the entire series.
        fetcher.pages["heartrate"] = [#"{"data":[{"bpm":58,"timestamp":"2026-01-05T12:00:00.000Z"}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.failAfterCall["heartrate"] = 1

        let coord = OuraSyncCoordinator(fetcher: fetcher, store: store)
        let summary = try await coord.runFullImport(today: "2026-03-15")

        XCTAssertTrue(summary.skippedEndpoints.contains("heartrate"))   // interruption reported honestly
        XCTAssertEqual(summary.days, 1)                                 // light data landed before HR began
        XCTAssertGreaterThan(summary.hrSamples, 0)                      // window 1's HR was durably saved BEFORE the failure
        // Ground truth in the store, not just the summary: the first window's sample is really persisted.
        let hr = try await store.hrSamples(deviceId: "oura-api", from: 0, to: Int.max, limit: 1000)
        XCTAssertFalse(hr.isEmpty)
    }

    func testFailingEndpointIsSkippedNotFatal() async throws {
        let store = try await WhoopStore.inMemory()
        let fetcher = StubFetcher()
        fetcher.pages["daily_readiness"] = [#"{"data":[{"day":"2026-01-02","score":80,"contributors":{"resting_heart_rate":50}}],"next_token":null}"#.data(using: .utf8)!]
        fetcher.failEndpoints = ["daily_spo2"]   // the live failure mode: scope 401 on one endpoint
        let coord = OuraSyncCoordinator(fetcher: fetcher, store: store)
        let summary = try await coord.runFullImport(today: "2026-02-01")
        XCTAssertEqual(summary.days, 1)                              // the rest of the backfill still lands
        XCTAssertEqual(summary.skippedEndpoints, ["daily_spo2"])     // and the skip is reported honestly
    }
}
#endif // OURA_CLOUD_IMPORT

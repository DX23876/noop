import XCTest
import WhoopProtocol
@testable import WhoopStore

final class ActivityCandidateStoreTests: XCTestCase {
    private func row(_ start: Int, track: String = "walk", device: String = "my-whoop") -> ActivityCandidateRow {
        ActivityCandidateRow(deviceId: device, track: track, startTs: start, endTs: start + 1_200,
                             ruleVersion: "activity-v1", avgBpm: 104, peakBpm: 118, load: 42, cadence: 105,
                             locomotionShare: 0.9, kinds: ["walk"])
    }

    func testTheRecentWindowIsReplacedAndOlderDaysAreKeptUntilTheyAgeOut() async throws {
        let store = try await WhoopStore.inMemory()
        let now = 100 * 86_400
        try await store.replaceActivityCandidates(deviceId: "my-whoop", from: now - 14 * 86_400, to: now,
                                                  rows: [row(now - 10 * 86_400), row(now - 2 * 86_400)])
        try await store.replaceActivityCandidates(deviceId: "my-whoop", from: now - 3 * 86_400, to: now,
                                                  rows: [row(now - 86_400, track: "heartRate")])
        var rows = try await store.activityCandidates(deviceId: "my-whoop", from: 0, to: now)
        XCTAssertEqual(rows.map(\.startTs), [now - 10 * 86_400, now - 86_400])
        XCTAssertEqual(rows.last?.track, "heartRate")
        XCTAssertEqual(rows.first?.kinds, ["walk"])

        let later = now + 25 * 86_400
        try await store.replaceActivityCandidates(deviceId: "my-whoop", from: later - 3 * 86_400, to: later, rows: [])
        rows = try await store.activityCandidates(deviceId: "my-whoop", from: 0, to: later)
        XCTAssertEqual(rows.map(\.startTs), [now - 86_400], "rows older than the keep window are dropped")
    }

    func testAnotherStrapsRowsAreLeftAlone() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityCandidates(deviceId: "whoop-b", from: 0, to: 10_000, rows: [row(1_000, device: "whoop-b")])
        try await store.replaceActivityCandidates(deviceId: "my-whoop", from: 0, to: 10_000, rows: [row(2_000)])
        let other = try await store.activityCandidates(deviceId: "whoop-b", from: 0, to: 10_000)
        XCTAssertEqual(other.count, 1)
    }

    func testStepMinutesSumTheStrapsClassAndCountTheCounterRise() async throws {
        let store = try await WhoopStore.inMemory()
        let samples = (0..<120).map { i in
            StepSample(ts: 600 + i, counter: 1_000 + (i < 60 ? i * 2 : 120 + (i - 60)),
                       activityClass: i < 40 ? 1 : (i < 60 ? 2 : nil))
        }
        try await store.insert(Streams(steps: samples), deviceId: "my-whoop")
        let minutes = try await store.stepMinutes(deviceId: "my-whoop", from: 0, to: 10_000)
        XCTAssertEqual(minutes, [
            StepMinute(ts: 600, steps: 118, walkSeconds: 40, runSeconds: 20, classSeconds: 60),
            StepMinute(ts: 660, steps: 59, walkSeconds: 0, runSeconds: 0, classSeconds: 0),
        ])
    }
}

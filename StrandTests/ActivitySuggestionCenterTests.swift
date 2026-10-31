import XCTest
import WhoopStore
import StrandAnalytics
import StrandCore
@testable import Strand

/// The app side of activity detection: a confirmation is stored under its own source with the answer that
/// points at it, "Not training" writes only an answer, a hand-logged session over a suggestion answers it,
/// and Undo opens it again and removes the session it saved.
@MainActor
final class ActivitySuggestionCenterTests: XCTestCase {
    private let deviceId = "my-whoop"

    private func setUp(_ store: WhoopStore, start: Int) async throws -> Repository {
        try await store.replaceActivityCandidates(deviceId: deviceId, from: start - 86_400, to: start + 86_400, rows: [
            ActivityCandidateRow(deviceId: deviceId, track: "heartRate", startTs: start, endTs: start + 1_800,
                                 ruleVersion: ActivityCandidates.ruleVersion, avgBpm: 132, peakBpm: 150, load: 110,
                                 cadence: nil, locomotionShare: 0.1, kinds: ["strength", "cycle", "other"]),
            ActivityCandidateRow(deviceId: deviceId, track: "walk", startTs: start + 7_200, endTs: start + 9_000,
                                 ruleVersion: ActivityCandidates.ruleVersion, avgBpm: 104, peakBpm: 115, load: 30,
                                 cadence: 108, locomotionShare: 0.95, kinds: ["walk"]),
        ])
        let repo = Repository(deviceId: deviceId)
        repo.setStoreForTesting(store)
        ActivitySuggestionCenter.shared.attach(repo)
        return repo
    }

    private func withDetection(_ body: () async throws -> Void) async throws {
        let d = UserDefaults.standard
        let keys = [ActivitySuggestions.enabledKey, ActivitySuggestions.notificationsKey]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        defer { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.set(true, forKey: ActivitySuggestions.enabledKey)
        d.set(false, forKey: ActivitySuggestions.notificationsKey)
        try await body()
    }

    func testConfirmNotTrainingAndUndo() async throws {
        try await withDetection {
            let store = try await WhoopStore.inMemory()
            let start = Int(Date().timeIntervalSince1970) - 6 * 3_600
            _ = try await setUp(store, start: start)
            let center = ActivitySuggestionCenter.shared
            await center.reload()
            XCTAssertEqual(center.toAsk.map(\.track), [.walk, .heartRate])

            let lift = try XCTUnwrap(center.toAsk.first { $0.track == .heartRate })
            await center.confirm(lift, row: ActivitySuggestionCenter.prefill(lift), origin: .today)
            let rows = try await store.workouts(deviceId: deviceId, from: start - 1, to: start + 1, limit: 10)
            XCTAssertEqual(rows.map(\.source), [WorkoutSource.confirmedSuggestionSource])
            XCTAssertEqual(rows.first?.sport, "Strength Training")
            var answers = try await store.activitySuggestionAnswers(from: start - 1, to: start + 86_400)
            XCTAssertEqual(answers.first?.answer, .sport)
            XCTAssertEqual(answers.first?.workout?.startTs, start)

            let walk = try XCTUnwrap(center.toAsk.first)
            await center.answer(walk, .everyday, origin: .notification)
            XCTAssertTrue(center.toAsk.isEmpty)
            let walkRows = try await store.workouts(deviceId: deviceId, from: start + 7_000, to: start + 9_000, limit: 10)
            XCTAssertTrue(walkRows.isEmpty, "Not training never writes a workout")

            let confirmed = try XCTUnwrap(center.inbox.first { $0.track == .heartRate })
            await center.undo(confirmed)
            answers = try await store.activitySuggestionAnswers(from: start - 1, to: start + 86_400)
            XCTAssertEqual(answers.map(\.answer), [.everyday])
            let afterUndo = try await store.workouts(deviceId: deviceId, from: start - 1, to: start + 1, limit: 10)
            XCTAssertTrue(afterUndo.isEmpty, "Undo removes the session the confirmation saved")
            XCTAssertEqual(center.toAsk.map(\.track), [.heartRate])
        }
    }

    func testAHandLoggedSessionOverASuggestionAnswersIt() async throws {
        try await withDetection {
            let store = try await WhoopStore.inMemory()
            let start = Int(Date().timeIntervalSince1970) - 6 * 3_600
            let repo = try await setUp(store, start: start)
            let center = ActivitySuggestionCenter.shared
            await center.reload()
            let manual = WorkoutRow(startTs: start + 7_100, endTs: start + 9_100, sport: "Walking", source: "manual",
                                    durationS: 2_000, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                    distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
            await center.noteLogged(manual)
            _ = repo
            let answers = try await store.activitySuggestionAnswers(from: start - 1, to: start + 86_400)
            XCTAssertEqual(answers.map(\.answer), [.walk])
            XCTAssertEqual(answers.first?.origin, .sheet)
        }
    }
}

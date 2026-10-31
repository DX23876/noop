import XCTest
import StrandAnalytics
@testable import StrandCore
import WhoopStore

final class ActivitySuggestionsTests: XCTestCase {
    typealias S = ActivitySuggestions

    private func candidate(_ start: Int, minutes: Int = 30, track: String = "heartRate", load: Double = 100,
                           kinds: [String] = ["strength", "cycle", "other"]) -> ActivityCandidateRow {
        ActivityCandidateRow(deviceId: "my-whoop", track: track, startTs: start, endTs: start + minutes * 60,
                             ruleVersion: ActivityCandidates.ruleVersion, avgBpm: 128, peakBpm: 150, load: load,
                             cadence: nil, locomotionShare: nil, kinds: kinds)
    }
    private func workout(_ start: Int, _ end: Int, source: String = "manual") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: "Strength Training", source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testOneResolverGivesEveryStateAndAnAnswerCountsEverywhere() {
        let rows = [candidate(10_000), candidate(20_000), candidate(30_000), candidate(40_000, track: "walk", kinds: ["walk"])]
        let suggestion = S.resolve(candidates: [rows[1]], answers: [], workouts: [], settings: .init())[0]
        let answered = S.answer(suggestion, .everyday, sport: nil, origin: .notification, shownAt: 21_000,
                                now: 22_000, workout: nil)
        let all = S.resolve(candidates: rows, answers: [answered], workouts: [workout(30_100, 31_700)],
                            settings: .init())
        XCTAssertEqual(all.map(\.state), [.open, .answered(.everyday), .logged, .open])
        XCTAssertEqual(answered.origin, .notification)
        XCTAssertEqual(answered.answerDelaySeconds, 1_000)
        XCTAssertEqual(answered.shownKind, "strength")
    }

    func testALegacyDetectedRowDoesNotCountAsLoggedButAConfirmedOneDoes() {
        let all = S.resolve(candidates: [candidate(10_000), candidate(20_000)], answers: [],
                            workouts: [workout(10_000, 11_800, source: "my-whoop-noop"),
                                       workout(20_000, 21_800, source: WorkoutSource.confirmedSuggestionSource)],
                            settings: .init())
        XCTAssertEqual(all.map(\.state), [.open, .logged])
    }

    func testTheLevelGatesHeartRateSpansAndTheWalkSwitchHidesWalks() {
        let rows = [candidate(10_000, load: 70), candidate(20_000, track: "walk", load: 20, kinds: ["walk"])]
        let balanced = S.resolve(candidates: rows, answers: [], workouts: [], settings: .init(level: .balanced))
        XCTAssertEqual(balanced.map(\.asks), [false, true])
        let more = S.resolve(candidates: rows, answers: [], workouts: [], settings: .init(level: .more))
        XCTAssertEqual(more.map(\.asks), [true, true])
        let noWalks = S.resolve(candidates: rows, answers: [], workouts: [], settings: .init(walks: false))
        XCTAssertEqual(noWalks.map(\.track), [.heartRate])
    }

    func testOnlySettledOpenSuggestionsAboveTheLevelAreAskedNewestFirst() {
        let rows = [candidate(10_000), candidate(20_000), candidate(30_000, load: 40), candidate(40_000)]
        let all = S.resolve(candidates: rows, answers: [], workouts: [], settings: .init())
        let now = 40_000 + 30 * 60 + 5 * 60   // the last one ended five minutes ago
        XCTAssertEqual(S.toAsk(all, now: now).map(\.start), [20_000, 10_000])
        XCTAssertEqual(S.toAsk(all, now: now, snoozed: ["heartRate:20000"]).map(\.start), [10_000])
    }

    func testTheInboxListsOpenFirstThenTheRestAndTheSheetOffersTheDaysOpenOnes() {
        let rows = [candidate(10_000), candidate(20_000), candidate(30_000, load: 40)]
        let a = S.answer(S.resolve(candidates: [rows[0]], answers: [], workouts: [], settings: .init())[0],
                         .sport, sport: "Strength Training", origin: .today, shownAt: nil, now: 50_000, workout: nil)
        let all = S.resolve(candidates: rows, answers: [a], workouts: [], settings: .init())
        XCTAssertEqual(S.inbox(all, now: 60_000).map(\.start), [30_000, 20_000, 10_000])
        XCTAssertEqual(S.forSheet(all, dayStart: 0, dayEnd: 86_400).map(\.start), [20_000, 30_000],
                       "the sheet offers spans below the level too, never answered ones")
    }

    func testALegacyDismissedSpanStaysForgotten() {
        let all = S.resolve(candidates: [candidate(10_000)], answers: [], workouts: [],
                            legacyDismissed: [10_500 ..< 11_000], settings: .init())
        XCTAssertTrue(all.isEmpty)
    }
}

import XCTest
import StrandAnalytics
@testable import StrandCore
import WhoopStore
import WhoopProtocol

final class ActivitySuggestionsTests: XCTestCase {
    typealias S = ActivitySuggestions

    private func candidate(_ start: Int, minutes: Int = 30, track: String = "heartRate", load: Double = 100,
                           kinds: [String] = ["strength", "cycle", "other"],
                           share: Double? = nil) -> ActivityCandidateRow {
        ActivityCandidateRow(deviceId: "my-whoop", track: track, startTs: start, endTs: start + minutes * 60,
                             ruleVersion: ActivityCandidates.ruleVersion, avgBpm: 128, peakBpm: 150, load: load,
                             cadence: nil, locomotionShare: share, kinds: kinds)
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

    func testAnAnswerStandsWhenANewRuleMovesTheStartOrJoinsTwoSpans() {
        // Answered under the old rule as two walks; the new rule reads one walk that starts earlier.
        let old = [candidate(10_600, minutes: 20, track: "walk", kinds: ["walk"]),
                   candidate(12_400, minutes: 20, track: "walk", kinds: ["walk"])]
        let second = S.resolve(candidates: [old[1]], answers: [], workouts: [], settings: .init())[0]
        let answered = S.answer(second, .everyday, sport: nil, origin: .today, shownAt: nil, now: 20_000, workout: nil)
        let joined = candidate(10_000, minutes: 60, track: "walk", kinds: ["walk"])
        XCTAssertEqual(S.resolve(candidates: [joined], answers: [answered], workouts: [], settings: .init()).map(\.state),
                       [.answered(.everyday)])
        // The same stretch on the other track, or a later walk, is another question.
        let other = candidate(10_000, minutes: 60)
        let later = candidate(20_000, minutes: 60, track: "walk", kinds: ["walk"])
        XCTAssertEqual(S.resolve(candidates: [other, later], answers: [answered], workouts: [], settings: .init()).map(\.state),
                       [.open, .open])
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

    /// 2026-11-04: a notification at 07:27:50 for a walk that went on until 07:29, because a span computed
    /// mid-walk ends where its data ended and the wait ran on the clock.
    func testTheWaitIsMeasuredOnTheDataNotOnTheClock() {
        let end = 10_000 + 30 * 60
        let later = end + 3 * 3_600
        func resolve(through: Int?) -> [S.Suggestion] {
            S.resolve(candidates: [candidate(10_000, track: "walk", kinds: ["walk"])], answers: [], workouts: [],
                      settings: .init(), dataThrough: through)
        }
        XCTAssertTrue(S.toAsk(resolve(through: end), now: later).isEmpty, "the data stops where the span stops")
        XCTAssertTrue(S.inbox(resolve(through: end), now: later).isEmpty)
        XCTAssertTrue(S.toAsk(resolve(through: end + S.settleSeconds - 60), now: later).isEmpty)
        XCTAssertEqual(S.toAsk(resolve(through: end + S.settleSeconds), now: later).map(\.start), [10_000])
        XCTAssertTrue(S.toAsk(resolve(through: end + S.settleSeconds), now: end + 60).isEmpty, "nor ahead of the clock")
        XCTAssertEqual(S.toAsk(resolve(through: nil), now: later).map(\.start), [10_000], "before the first refresh")
    }

    func testAMixedWayIsAskedBelowTheLoadExceptAtOnlyClear() {
        let rows = [candidate(10_000, load: 35, kinds: ["walk", "strength", "other"], share: 0.6),
                    candidate(20_000, load: 35, share: 0.5), candidate(30_000, load: 35)]
        func asks(_ level: ActivityCandidates.Level) -> [Bool] {
            S.resolve(candidates: rows, answers: [], workouts: [], settings: .init(level: level)).map(\.asks)
        }
        XCTAssertEqual(asks(.more), [true, false, false], "more than half, and an unknown share is not")
        XCTAssertEqual(asks(.balanced), [true, false, false])
        XCTAssertEqual(asks(.onlyClear), [false, false, false])
    }

    func testARefreshRecordsTheNewestMinuteItSawForThatDevice() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let store = try await WhoopStore.inMemory()
        let now = 1_793_900_000
        let steps = (0..<120).map { StepSample(ts: now - 7_200 + $0, counter: $0, activityClass: 1) }
        try await store.insert(Streams(steps: steps), deviceId: "my-whoop")
        try await S.refresh(store: store, deviceId: "my-whoop", computedId: "my-whoop-noop", hrMax: 180, now: now,
                            calendar: calendar)
        let expected = ((now - 7_200 + 119) / 60) * 60
        let seen = await S.dataThrough(store: store, deviceId: "my-whoop")
        let other = await S.dataThrough(store: store, deviceId: "whoop-b")
        XCTAssertEqual(seen, expected)
        XCTAssertNil(other)
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

    /// Two weeks back from 2026-10-31 cross the end of summer time in Berlin: the refresh must still reach today.
    func testTheRefreshReachesTodayAcrossAClockChange() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let store = try await WhoopStore.inMemory()
        let todayStart = Int(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31))!.timeIntervalSince1970)
        let lift = todayStart + 15 * 3_600
        var hr: [HRSample] = []
        for t in stride(from: lift - 3_600, to: lift + 50 * 60, by: 1) {
            hr.append(HRSample(ts: t, bpm: t >= lift ? 140 : 62))
        }
        try await store.insert(Streams(hr: hr), deviceId: "my-whoop")
        try await store.upsertDailyMetrics([DailyMetric(day: "2026-10-31", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)], deviceId: "my-whoop")
        let found = try await S.refresh(store: store, deviceId: "my-whoop", computedId: "my-whoop-noop", hrMax: 185,
                                        now: lift + 2 * 3_600, calendar: calendar)
        XCTAssertEqual(found.map(\.start), [lift])
        XCTAssertEqual(found.first?.durationMinutes, 50)
    }

    func testALegacyDismissedSpanStaysForgotten() {
        let all = S.resolve(candidates: [candidate(10_000)], answers: [], workouts: [],
                            legacyDismissed: [10_500 ..< 11_000], settings: .init())
        XCTAssertTrue(all.isEmpty)
    }
}

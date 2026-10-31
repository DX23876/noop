import XCTest
@testable import StrandAnalytics

final class ActivityDetectionScoreTests: XCTestCase {
    typealias S = ActivityDetectionScore
    private func span(_ startMin: Int, _ endMin: Int) -> S.Span { S.Span(start: startMin * 60, end: endMin * 60) }
    private func label(_ startMin: Int, _ endMin: Int, _ kind: S.Kind) -> S.Label { S.Label(span: span(startMin, endMin), kind: kind) }

    func testOverlapNeedsThirtyPercentOfTheUnion() {
        XCTAssertEqual(S.iou(span(0, 60), span(0, 60)), 1)
        XCTAssertEqual(S.iou(span(0, 60), span(60, 120)), 0)
        XCTAssertEqual(S.iou(span(0, 60), span(30, 90)), 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(S.match(candidates: [span(0, 100)], labels: [label(70, 100, .walk)]), [0])
        XCTAssertEqual(S.match(candidates: [span(0, 100)], labels: [label(71, 100, .walk)]), [nil])
    }

    func testOneLongSuggestionFindsOnlyOneOfTheTwoEntriesItSpans() {
        let labels = [label(0, 40, .walk), label(50, 90, .strength)]
        XCTAssertEqual(S.match(candidates: [span(0, 90)], labels: labels), [0])
        let s = S.summarize(candidates: [span(0, 90)], labels: labels, wornAwakeDays: 1)
        XCTAssertEqual(s.hits, [.walk: 1])
        XCTAssertEqual(s.entries, [.walk: 1, .strength: 1])
    }

    func testEachEntryIsFoundOnceAndTheBestOverlapWins() {
        let labels = [label(0, 60, .walk)]
        let matched = S.match(candidates: [span(0, 30), span(5, 60)], labels: labels)
        XCTAssertEqual(matched, [nil, 0])
    }

    func testTheResultDoesNotDependOnInputOrder() {
        let labels = [label(0, 30, .walk), label(100, 160, .strength), label(300, 340, .cycle)]
        let cands = [span(2, 31), span(95, 150), span(200, 230), span(301, 345)]
        let forward = S.summarize(candidates: cands, labels: labels, wornAwakeDays: 2)
        let backward = S.summarize(candidates: cands.reversed(), labels: labels.reversed(), wornAwakeDays: 2)
        XCTAssertEqual(forward, backward)
    }

    func testSummaryRecoversSeveralInjectedPatterns() {
        // Three days: a walk found exactly, a strength session found 5 min late, one housework span with
        // no entry, and a cycle ride nobody suggested.
        let labels = [label(600, 640, .walk), label(2_000, 2_060, .strength), label(3_500, 3_560, .cycle)]
        let cands = [span(600, 640), span(2_005, 2_060), span(2_500, 2_530)]
        let s = S.summarize(candidates: cands, labels: labels, wornAwakeDays: 3)
        XCTAssertEqual(s.hits, [.walk: 1, .strength: 1])
        XCTAssertEqual(s.entries[.cycle], 1)
        XCTAssertEqual(s.suggestions, 3)
        XCTAssertEqual(s.unlabelled, 1)
        XCTAssertEqual(s.unlabelledPerWornDay!, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(s.meanStartErrorS, 150)
        XCTAssertEqual(s.meanEndErrorS, 0)
    }

    func testNoWornDaysGivesNoRateRatherThanAnInfiniteOne() {
        XCTAssertNil(S.summarize(candidates: [span(0, 20)], labels: [], wornAwakeDays: 0).unlabelledPerWornDay)
    }

    func testAWalkLoggedTwiceIsOneEntry() {
        let twice = [label(0, 40, .walk), label(2, 45, .walk), label(100, 130, .strength)]
        XCTAssertEqual(S.uniqueLabels(twice), [label(0, 45, .walk), label(100, 130, .strength)])
    }

    func testPiecesOfOneSessionJoinButDifferentKindsDoNot() {
        let pieces = [label(0, 8, .strength), label(20, 22, .strength), label(23, 40, .strength)]
        XCTAssertEqual(S.uniqueLabels(pieces), [label(0, 8, .strength), label(20, 40, .strength)])
        let near = [label(0, 30, .walk), label(35, 60, .strength)]
        XCTAssertEqual(S.uniqueLabels(near), near)
    }

    func testSportNamesFoldOntoKinds() {
        XCTAssertEqual(S.Kind.of(sport: "Walking"), .walk)
        XCTAssertEqual(S.Kind.of(sport: "Treadmill walk"), .walk)
        XCTAssertEqual(S.Kind.of(sport: "Running"), .run)
        XCTAssertEqual(S.Kind.of(sport: "Indoor cycle"), .cycle)
        XCTAssertEqual(S.Kind.of(sport: "Strength Training"), .strength)
        XCTAssertEqual(S.Kind.of(sport: "Bodybuilding"), .strength)
        XCTAssertEqual(S.Kind.of(sport: "Functional strength training"), .strength)
        XCTAssertEqual(S.Kind.of(sport: "Yoga"), .other)
    }

    func testShadowLineNamesTheResultWithoutTimestamps() {
        XCTAssertEqual(S.shadowLine(day: "2026-10-31", track: "dayBout", ruleVersion: "v0", span: span(0, 42),
                                    avgBpm: 118, matchedKind: .strength),
                       "activityShadow day=2026-10-31 track=dayBout rule=v0 durMin=42 avgBpm=118 result=matched kind=strength")
        XCTAssertTrue(S.shadowLine(day: "2026-10-31", track: "dayBout", ruleVersion: "v0", span: span(0, 20),
                                   avgBpm: 101, matchedKind: nil).hasSuffix("result=unlabelled"))
    }
}

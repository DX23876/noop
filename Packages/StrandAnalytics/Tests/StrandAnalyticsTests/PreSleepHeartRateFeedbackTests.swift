import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class PreSleepHeartRateFeedbackTests: XCTestCase {
    private func samples(_ start: Int, bpm: Int, count: Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0 * 60, bpm: bpm) }
    }

    func testEligibleFeedbackSeparatesObservationComparisonUncertaintyAndUnsupportedRecommendation() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let history = [60.0, 61.0, 62.0, 63.0].enumerated().map {
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-0\($0.offset + 1)", meanBpm: $0.element)
        }
        let journal = JournalEntry(day: "2026-08-05", question: "Late meal", answeredYes: true, notes: nil)
        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true,
            sessions: [sleep],
            hr: samples(8_800, bpm: 70, count: 12) + samples(10_000, bpm: 55, count: 12),
            history: history,
            journalEntries: [journal],
            day: "2026-08-05",
            minimumValidSamples: 10,
            preSleepWindowSeconds: 1_800
        )

        XCTAssertEqual(feedback.eligibility, .eligible)
        XCTAssertEqual(feedback.observation?.windowStartTs, 8_200)
        XCTAssertEqual(feedback.observation?.windowEndTs, 10_000)
        XCTAssertEqual(feedback.observation?.meanBpm, 70)
        XCTAssertEqual(feedback.observation?.validSamples, 12)
        XCTAssertEqual(feedback.comparison?.baselineBpm, 61.5)
        XCTAssertEqual(feedback.comparison?.deltaBpm, 8.5)
        XCTAssertEqual(feedback.comparison?.baselineStatus, .provisional)
        XCTAssertEqual(feedback.uncertainty, [.provisionalBaseline])
        XCTAssertEqual(feedback.inference, .notEstablished)
        XCTAssertEqual(feedback.recommendation, .unsupported)
        XCTAssertEqual(feedback.journalContext, [
            PreSleepHeartRateFeedback.JournalFact(day: "2026-08-05", question: "Late meal",
                                                   answeredYes: true, numericValue: nil)
        ])
    }

    func testBaselineUsesOnlySortedPriorNights() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let history = [
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-01", meanBpm: 60),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-04", meanBpm: 63),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-02", meanBpm: 61),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-03", meanBpm: 62),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-05", meanBpm: 90),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-06", meanBpm: 100),
        ]

        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: history, journalEntries: [], day: "2026-08-05",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800
        )

        XCTAssertEqual(feedback.comparison?.baselineBpm, 61.5)
        XCTAssertEqual(feedback.comparison?.baselineNights, 4)
    }

    func testRecentImplausibleHistoryDoesNotRefreshMatureStaleBaseline() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        var history = (1...14).map {
            PreSleepHeartRateFeedback.HistoricalReading(
                day: String(format: "2024-02-%02d", $0), meanBpm: 60
            )
        }
        history += [
            .init(day: "2024-02-28", meanBpm: .nan),
            .init(day: "2024-02-28", meanBpm: 70),
            .init(day: "2024-02-29", meanBpm: PreSleepHeartRateFeedback.baselineCfg.maxVal + 1),
        ]

        let journal = JournalEntry(day: "2024-03-01", question: "Late meal",
                                   answeredYes: true, notes: nil)
        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: history, journalEntries: [journal], day: "2024-03-01",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800
        )

        XCTAssertEqual(feedback.eligibility, .staleBaseline(daysSinceUpdate: 16))
        XCTAssertEqual(feedback.observation?.meanBpm, 70)
        XCTAssertNil(feedback.comparison)
        XCTAssertEqual(feedback.uncertainty, [.staleBaseline(daysSinceUpdate: 16)])
        XCTAssertEqual(feedback.journalContext, [
            .init(day: "2024-03-01", question: "Late meal", answeredYes: true, numericValue: nil)
        ])
    }

    func testBaselineAtExactStaleDaysBoundaryRemainsTrustedAcrossYearBoundary() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let history = (1...13).map {
            PreSleepHeartRateFeedback.HistoricalReading(
                day: String(format: "2023-01-%02d", $0), meanBpm: 60
            )
        } + [.init(day: "2023-12-18", meanBpm: 60)]

        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: history, journalEntries: [], day: "2024-01-01",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800
        )

        XCTAssertEqual(feedback.eligibility, .eligible)
        XCTAssertEqual(feedback.comparison?.baselineStatus, .trusted)
        XCTAssertTrue(feedback.uncertainty.isEmpty)
    }

    func testBaselineOneDayPastStaleBoundaryIsExplicitlyStaleAcrossLeapDay() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let history = (1...13).map {
            PreSleepHeartRateFeedback.HistoricalReading(
                day: String(format: "2024-01-%02d", $0), meanBpm: 60
            )
        } + [.init(day: "2024-02-15", meanBpm: 60)]

        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: history, journalEntries: [], day: "2024-03-01",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800
        )

        XCTAssertEqual(feedback.eligibility, .staleBaseline(daysSinceUpdate: 15))
        XCTAssertNotNil(feedback.observation)
        XCTAssertNil(feedback.comparison)
        XCTAssertEqual(feedback.uncertainty, [.staleBaseline(daysSinceUpdate: 15)])
    }

    func testRepeatedPriorDayCannotSatisfyMinimumBaselineNights() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let history = [60.0, 61.0, 62.0, 63.0].map {
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-04", meanBpm: $0)
        }

        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: history, journalEntries: [], day: "2026-08-05",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800
        )

        XCTAssertEqual(feedback.eligibility, .insufficientBaseline(validNights: 1, required: 4))
        XCTAssertNil(feedback.comparison)
    }

    func testNoncanonicalAndImpossibleDaysCannotSatisfyMinimumBaselineNights() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let history = [
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-01", meanBpm: 60),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-02", meanBpm: 61),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-04Z", meanBpm: 62),
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-02-31", meanBpm: 63),
        ]

        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: history, journalEntries: [], day: "2026-08-05",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800
        )

        XCTAssertEqual(feedback.eligibility, .insufficientBaseline(validNights: 2, required: 4))
        XCTAssertNil(feedback.comparison)
    }

    func testInvalidEvaluationDaysCannotProduceFeedback() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let cases = [
            (day: "2026-08-05Z", historyDays: ["2026-08-02", "2026-08-03", "2026-08-04", "2026-08-05"]),
            (day: "2026-02-31", historyDays: ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"]),
        ]

        for testCase in cases {
            let history = testCase.historyDays.map {
                PreSleepHeartRateFeedback.HistoricalReading(day: $0, meanBpm: 60)
            }
            let journal = JournalEntry(day: testCase.day, question: "Late meal", answeredYes: true, notes: nil)
            let feedback = PreSleepHeartRateFeedback.evaluate(
                enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
                history: history, journalEntries: [journal], day: testCase.day,
                minimumValidSamples: 10, preSleepWindowSeconds: 1_800
            )

            XCTAssertEqual(feedback.eligibility, .invalidDay)
            XCTAssertNil(feedback.observation)
            XCTAssertNil(feedback.comparison)
            XCTAssertTrue(feedback.uncertainty.isEmpty)
            XCTAssertTrue(feedback.journalContext.isEmpty)
        }
    }

    func testExtremeSleepSessionDurationFailsClosedWithoutTrapping() {
        let sleep = SleepSession(start: Int.min, end: Int.max, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let otherSleep = SleepSession(start: Int.min, end: Int.max - 1, efficiency: 0.9,
                                      stages: [], restingHR: nil, avgHRV: nil)

        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep, otherSleep], hr: [], history: [], journalEntries: [],
            day: "2026-08-05", minimumValidSamples: 1, preSleepWindowSeconds: 1
        )

        XCTAssertEqual(feedback.eligibility, .missingPrimarySleep)
        XCTAssertNil(feedback.observation)
    }

    func testExtremePreSleepWindowFailsClosedWithoutTrapping() {
        let sleep = SleepSession(start: Int.min + 1, end: Int.min + 2, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)

        let feedback = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: [], history: [], journalEntries: [],
            day: "2026-08-05", minimumValidSamples: 1, preSleepWindowSeconds: Int.max
        )

        XCTAssertEqual(feedback.eligibility, .invalidWindow)
        XCTAssertNil(feedback.observation)
    }

    func testOptOutAndLapseFailClosedWithoutCreatingFeedbackOrPunishment() {
        let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                 stages: [], restingHR: nil, avgHRV: nil)
        let disabled = PreSleepHeartRateFeedback.evaluate(enabled: false, sessions: [sleep],
                                                           hr: samples(8_800, bpm: 70, count: 12),
                                                           history: [], journalEntries: [], day: "2026-08-05",
                                                           minimumValidSamples: 10, preSleepWindowSeconds: 1_800)
        XCTAssertEqual(disabled.eligibility, .disabled)
        XCTAssertNil(disabled.observation)
        XCTAssertNil(disabled.comparison)

        let lapsed = PreSleepHeartRateFeedback.evaluate(enabled: true, sessions: [sleep], hr: [],
                                                         history: [], journalEntries: [], day: "2026-08-05",
                                                         minimumValidSamples: 10, preSleepWindowSeconds: 1_800)
        XCTAssertEqual(lapsed.eligibility, .insufficientPreSleepSamples(valid: 0, required: 10))
        XCTAssertEqual(lapsed.recommendation, .unsupported)

        let building = PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 70, count: 12),
            history: [.init(day: "2026-08-04", meanBpm: 60)], journalEntries: [], day: "2026-08-05",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800
        )
        XCTAssertEqual(building.eligibility, .insufficientBaseline(validNights: 1, required: 4))
        XCTAssertEqual(building.observation?.validSamples, 12)
        XCTAssertNil(building.comparison)
        XCTAssertEqual(building.uncertainty, [.noPersonalComparison])
    }
}

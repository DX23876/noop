import XCTest
import StrandAnalytics
@testable import Strand

/// `Repository.needsSelfHeal`: which edited nights the per-pass self-heal may skip. A skip is only safe
/// where the day's fingerprint vouches for every raw row the re-stage would read.
final class SelfHealSkipTests: XCTestCase {
    private let tz = 2 * 3_600                       // Europe/Berlin, summer
    private let dayStart = 1_791_324_000             // 2026-10-07 00:00 local (UTC+2)

    private func night(startHoursBefore: Int, endHoursAfter: Int) -> (start: Int, end: Int) {
        (dayStart - startHoursBefore * 3_600, dayStart + endHoursAfter * 3_600)
    }

    func testDayKeyIsTheLocalEndDay() {
        XCTAssertEqual(AnalyticsEngine.dayString(dayStart + 6 * 3_600, offsetSec: tz), "2026-10-07")
    }

    func testChangedDayIsHealed() {
        let n = night(startHoursBefore: 1, endHoursAfter: 6)
        XCTAssertTrue(Repository.needsSelfHeal(effectiveStartTs: n.start, endTs: n.end,
                                               unchangedDays: [], tzOffsetSeconds: tz))
        XCTAssertTrue(Repository.needsSelfHeal(effectiveStartTs: n.start, endTs: n.end,
                                               unchangedDays: ["2026-10-06"], tzOffsetSeconds: tz))
    }

    func testUnchangedDayInsideTheScanWindowIsSkipped() {
        let n = night(startHoursBefore: 1, endHoursAfter: 6)
        XCTAssertFalse(Repository.needsSelfHeal(effectiveStartTs: n.start, endTs: n.end,
                                                unchangedDays: ["2026-10-07"], tzOffsetSeconds: tz))
    }

    func testNightReachingBeforeTheScanWindowIsHealedEvenWhenUnchanged() {
        let edge = night(startHoursBefore: 30, endHoursAfter: 6)
        XCTAssertFalse(Repository.needsSelfHeal(effectiveStartTs: edge.start, endTs: edge.end,
                                                unchangedDays: ["2026-10-07"], tzOffsetSeconds: tz),
                       "exactly the lookback is still covered by the day's read window")
        XCTAssertTrue(Repository.needsSelfHeal(effectiveStartTs: edge.start - 1, endTs: edge.end,
                                               unchangedDays: ["2026-10-07"], tzOffsetSeconds: tz))
    }

    func testNightEndingJustBeforeMidnightBelongsToThePreviousDay() {
        let end = dayStart - 1
        XCTAssertTrue(Repository.needsSelfHeal(effectiveStartTs: end - 3_600, endTs: end,
                                               unchangedDays: ["2026-10-07"], tzOffsetSeconds: tz))
        XCTAssertFalse(Repository.needsSelfHeal(effectiveStartTs: end - 3_600, endTs: end,
                                                unchangedDays: ["2026-10-06"], tzOffsetSeconds: tz))
    }

    func testStagerSignatureNamesBothToggles() {
        let signatures = Set([false, true].flatMap { v2 in
            [false, true].map { Repository.selfHealStagerSignature(sleepV2: v2, motionAwareWake: $0) }
        })
        XCTAssertEqual(signatures.count, 4)
    }
}

import XCTest
@testable import StrandAnalytics

/// The reported defect: the automatic wake time lands far too early, recovery is wrong, and the coach
/// plans on it anyway. These pin the three verdicts and their boundaries.
final class SleepWindowSettlednessTests: XCTestCase {

    /// 07:00 local on an arbitrary day, with a UTC+2 wearer.
    private let offset = 7200
    private let wake = 1_700_000_000
    private var habitualWake: Int { ((wake + 7200) % 86_400 + 86_400) % 86_400 }

    // MARK: - awaitingSync (the actual cause)

    /// Raw data stops at the recorded wake and has done for an hour: the strap has not finished
    /// offloading, and the "wake" is where the sync ended rather than where the wearer woke.
    func testTruncatedWindowThatHasSatForAWhileIsAwaitingSync() {
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: wake, lastHrSampleTs: wake + 30,
                                           nowTs: wake + 3600, habitualWakeSec: habitualWake,
                                           offsetSec: offset),
            .awaitingSync)
    }

    /// The same shape moments after waking is NOT a problem — a sync may simply be in flight. Firing
    /// here would withhold the brief from everyone every morning.
    func testFreshlyTruncatedWindowIsStillSettled() {
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: wake, lastHrSampleTs: wake + 30,
                                           nowTs: wake + 300, habitualWakeSec: habitualWake,
                                           offsetSec: offset),
            .settled)
    }

    /// A truncated night usually ALSO looks early against the habit. The objective reading has to win,
    /// or the wearer is sent to hand-correct a wake time that the next sync will fix by itself.
    func testTruncationOutranksTheHabitSuspicion() {
        let veryEarly = wake - 3 * 3600
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: veryEarly, lastHrSampleTs: veryEarly + 10,
                                           nowTs: veryEarly + 4 * 3600, habitualWakeSec: habitualWake,
                                           offsetSec: offset),
            .awaitingSync)
    }

    // MARK: - wakeLooksEarly

    /// Readings continue for hours past the recorded wake: the strap was on the wrist and recording
    /// while the wearer was supposedly already up.
    func testDataContinuingLongPastWakeLooksEarly() {
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: wake, lastHrSampleTs: wake + 3 * 3600,
                                           nowTs: wake + 4 * 3600, habitualWakeSec: habitualWake,
                                           offsetSec: offset),
            .wakeLooksEarly)
    }

    /// Two hours before the learned habit, with the data shape giving nothing away.
    func testWakeFarBeforeTheLearnedHabitLooksEarly() {
        let early = wake - 2 * 3600
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: early, lastHrSampleTs: nil,
                                           nowTs: early + 3600, habitualWakeSec: habitualWake,
                                           offsetSec: offset),
            .wakeLooksEarly)
    }

    /// An ordinary early morning is not a defect. Half an hour before the habit stays settled.
    func testAModestlyEarlyMorningIsSettled() {
        let early = wake - 1800
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: early, lastHrSampleTs: nil,
                                           nowTs: early + 3600, habitualWakeSec: habitualWake,
                                           offsetSec: offset),
            .settled)
    }

    /// Waking LATE is a lie-in, never a truncated recording.
    func testALieInIsSettled() {
        let late = wake + 3 * 3600
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: late, lastHrSampleTs: nil,
                                           nowTs: late + 3600, habitualWakeSec: habitualWake,
                                           offsetSec: offset),
            .settled)
    }

    /// The habit comparison runs on the clock face: a 00:30 wake against a 23:45 habit is 45 minutes
    /// apart, not 23 hours, so a near-midnight sleeper is not permanently flagged.
    func testHabitComparisonWrapsAroundMidnight() {
        // Habit 23:45; actual wake 00:30 — 45 min LATER, so not early.
        XCTAssertFalse(SleepWindowSettledness.wakeIsEarlierThanHabit(
            sessionEndTs: 30 * 60 - 7200, habitualWakeSec: 23 * 3600 + 45 * 60, offsetSec: 7200))
        // Habit 00:30; actual wake 22:30 — 2 h EARLIER across the boundary.
        XCTAssertTrue(SleepWindowSettledness.wakeIsEarlierThanHabit(
            sessionEndTs: 22 * 3600 + 30 * 60 - 7200, habitualWakeSec: 30 * 60, offsetSec: 7200))
    }

    // MARK: - Missing inputs

    /// Cold start: no learned habit and no coverage edge means nothing is known, and "unknown" must
    /// read as settled rather than withholding the brief from a new user indefinitely.
    func testNoHabitAndNoCoverageIsSettled() {
        XCTAssertEqual(
            SleepWindowSettledness.verdict(sessionEndTs: wake, lastHrSampleTs: nil,
                                           nowTs: wake + 4 * 3600, habitualWakeSec: nil,
                                           offsetSec: offset),
            .settled)
    }

    /// Boundaries, so a threshold tweak is a deliberate act rather than an accident.
    func testThresholdBoundaries() {
        let s = SleepWindowSettledness.self
        // Exactly at the stale-truncation threshold fires; a second under does not.
        XCTAssertEqual(s.verdict(sessionEndTs: wake, lastHrSampleTs: wake,
                                 nowTs: wake + s.staleTruncationSeconds,
                                 habitualWakeSec: nil, offsetSec: offset), .awaitingSync)
        XCTAssertEqual(s.verdict(sessionEndTs: wake, lastHrSampleTs: wake,
                                 nowTs: wake + s.staleTruncationSeconds - 1,
                                 habitualWakeSec: nil, offsetSec: offset), .settled)
        // Exactly at the overrun threshold fires.
        XCTAssertEqual(s.verdict(sessionEndTs: wake, lastHrSampleTs: wake + s.dataOverrunSeconds,
                                 nowTs: wake + 4 * 3600, habitualWakeSec: nil, offsetSec: offset),
                       .wakeLooksEarly)
    }
}

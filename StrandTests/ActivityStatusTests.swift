import XCTest
@testable import Strand

/// Pins docs/fork/feature-spec.md §1 (`ActivityStatus`): the four-state manual override, the
/// duration→validUntil mapping, and the silent auto-fallback to `.active` once `validUntil` passes. Pure
/// value-type logic + a UserDefaults-backed store, both database-free.
final class ActivityStatusTests: XCTestCase {

    private func date(_ offsetSeconds: TimeInterval, from base: Date = Date()) -> Date {
        base.addingTimeInterval(offsetSeconds)
    }

    // MARK: - resolved(now:) — the silent fallback

    func testExpiredExceptionStateFallsBackToActive() {
        let now = Date()
        let status = ActivityStatus(state: .sick, validUntil: date(-60, from: now), setAt: date(-3600, from: now))
        XCTAssertEqual(status.resolved(now: now), .active)
    }

    func testFutureValidUntilStaysUnchanged() {
        let now = Date()
        let status = ActivityStatus(state: .injured, validUntil: date(60, from: now), setAt: now)
        XCTAssertEqual(status.resolved(now: now), status)
    }

    func testNilValidUntilNeverFallsBack() {
        // "Bis geändert" — no automatic reset even far in the future.
        let farFuture = date(3600 * 24 * 365)
        let status = ActivityStatus(state: .onBreak, validUntil: nil, setAt: Date())
        XCTAssertEqual(status.resolved(now: farFuture), status)
    }

    func testActiveStateIsAlwaysANoOp() {
        let now = Date()
        let status = ActivityStatus(state: .active, validUntil: date(-60, from: now), setAt: now)
        XCTAssertEqual(status.resolved(now: now), status)
    }

    func testExactValidUntilMomentFallsBack() {
        let now = Date()
        let status = ActivityStatus(state: .sick, validUntil: now, setAt: date(-60, from: now))
        XCTAssertEqual(status.resolved(now: now), .active)
    }

    // MARK: - Duration.validUntil(from:)

    func testDurationTodayIsStartOfNextDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 14, minute: 30))!
        let expected = cal.date(from: DateComponents(year: 2026, month: 7, day: 24, hour: 0, minute: 0))!
        XCTAssertEqual(ActivityStatus.Duration.today.validUntil(from: now, calendar: cal), expected)
    }

    func testDurationThreeDaysAddsThreeDays() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let expected = cal.date(byAdding: .day, value: 3, to: now)
        XCTAssertEqual(ActivityStatus.Duration.threeDays.validUntil(from: now, calendar: cal), expected)
    }

    func testDurationThisWeekIsEndOfCurrentWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let expected = cal.dateInterval(of: .weekOfYear, for: now)?.end
        XCTAssertEqual(ActivityStatus.Duration.thisWeek.validUntil(from: now, calendar: cal), expected)
    }

    func testDurationCustomReturnsExactDate() {
        let chosen = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ActivityStatus.Duration.custom(chosen).validUntil(from: Date()), chosen)
    }

    func testDurationUntilChangedReturnsNil() {
        XCTAssertNil(ActivityStatus.Duration.untilChanged.validUntil(from: Date()))
    }

    // MARK: - suppressesTrainingSuggestions

    func testActiveDoesNotSuppress() {
        XCTAssertFalse(ActivityStatus.active.suppressesTrainingSuggestions)
    }

    func testExceptionStatesSuppress() {
        for state: ActivityStatus.State in [.sick, .injured, .onBreak] {
            let status = ActivityStatus(state: state, validUntil: nil, setAt: Date())
            XCTAssertTrue(status.suppressesTrainingSuggestions, "\(state) should suppress training suggestions")
        }
    }

    // MARK: - ActivityStatusStore persistence

    private func isolatedDefaults() -> UserDefaults {
        let name = "activitystatus.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testStoreRoundTrip() {
        let d = isolatedDefaults()
        let now = Date()
        let status = ActivityStatus(state: .injured, validUntil: date(3600, from: now), setAt: now)
        ActivityStatusStore.save(status, to: d)
        XCTAssertEqual(ActivityStatusStore.load(from: d, now: now), status)
    }

    func testStoreWithNoSavedValueReturnsActive() {
        let d = isolatedDefaults()
        XCTAssertEqual(ActivityStatusStore.load(from: d), .active)
    }

    // MARK: Today's "Unwell" chip (2026-11-20)

    func testUnwellSetsSickForTodayOnly() {
        let now = Date(timeIntervalSince1970: 1_763_630_000)
        guard let set = ActivityStatus.settingSick(from: .active, now: now) else {
            return XCTFail("answering the warning sets the status")
        }
        XCTAssertEqual(set.state, .sick)
        XCTAssertEqual(set.validUntil, ActivityStatus.Duration.today.validUntil(from: now))
        // Tomorrow it is gone by itself: one tap says what today was, not how long the illness runs.
        XCTAssertEqual(set.resolved(now: Calendar.current.date(byAdding: .day, value: 1, to: now)!), .active)
    }

    func testUnwellNeverShortensAStatusTheWearerSet() {
        let now = Date(timeIntervalSince1970: 1_763_630_000)
        for state in [ActivityStatus.State.sick, .injured, .onBreak] {
            let chosen = ActivityStatus(state: state, validUntil: date(3 * 86_400, from: now), setAt: now)
            XCTAssertNil(ActivityStatus.settingSick(from: chosen, now: now),
                         "a deliberate \(state) for three days outranks one tap on a chip")
        }
    }

    func testDecodeReadsWhatLoadReturnsAndWritesNothing() {
        let d = isolatedDefaults()
        let now = Date()
        let expired = ActivityStatus(state: .sick, validUntil: date(-60, from: now), setAt: date(-3600, from: now))
        ActivityStatusStore.save(expired, to: d)
        // The screen observes the bytes; it must read the same status `load` would return.
        XCTAssertEqual(ActivityStatusStore.decode(d.data(forKey: ActivityStatusStore.key), now: now), .active)
        // And observing must not rewrite the store: the stored bytes are still the expired status.
        let stillStored = try? JSONDecoder().decode(ActivityStatus.self, from: d.data(forKey: ActivityStatusStore.key) ?? Data())
        XCTAssertEqual(stillStored, expired)
    }

    func testStoreLoadAppliesAndPersistsFallback() {
        let d = isolatedDefaults()
        let now = Date()
        let expired = ActivityStatus(state: .sick, validUntil: date(-60, from: now), setAt: date(-3600, from: now))
        ActivityStatusStore.save(expired, to: d)

        XCTAssertEqual(ActivityStatusStore.load(from: d, now: now), .active)

        // A second load, with no explicit re-save, must still read back .active — proving the first
        // load's fallback was written through, not just returned transiently.
        XCTAssertEqual(ActivityStatusStore.load(from: d, now: date(3600 * 24, from: now)), .active)
    }
}

import XCTest
import StrandAnalytics
@testable import Strand

/// Pins the per-day body mass the analysis pass scores each day with.
///
/// Reported from a real device, and proven by the pass's own field-level diff:
///
///     reuse semantic diff (first miss, day=2026-09-04): weight: 211.0 → 209.55
///
/// One morning weigh-in, synced in from Apple Health, re-derived three weeks of sleep staging. The
/// route was `applyHealthWeight` → `profile.weightKg` → the PASS-GLOBAL `semanticSignature` → all 21
/// days missing at once. Weight reaches exactly two persisted values — the day's `activeKcalEst` and
/// the kcal of already-detected workouts — and none of the staging, HRV, Rest, Charge or Effort that
/// was being recomputed for it.
///
/// The fix resolves weight PER DAY from the weigh-in history, so a new measurement moves only the day
/// it was taken on. That rests entirely on the resolver being causal, which is what these tests hold.
final class WeightByDayTests: XCTestCase {

    private let fallback = 80.0

    /// Day keys the way the scan loop derives them: newest first, one calendar day apart.
    private func days(_ keys: String...) -> [String] { keys }

    /// An observation on `day`, stamped the way the production call site stamps one (noon, via
    /// `WeightSeries.date(forDay:)`), so these tests cannot pass on a timestamp convention the app
    /// does not use.
    private func obs(_ day: String, _ kg: Double,
                     source: CausalWeightObservation.Source = .health) throws -> CausalWeightObservation {
        let date = try XCTUnwrap(WeightSeries.date(forDay: day), "unparseable day key \(day)")
        return CausalWeightObservation(timestamp: Int(date.timeIntervalSince1970),
                                       weightKg: kg, source: source)
    }

    // MARK: - The regression

    /// THE test. A weigh-in today must not change what any earlier day was scored with — that is the
    /// whole difference between re-deriving one day and re-deriving twenty-one.
    ///
    /// It holds because `CausalWeightResolver` only consults observations at or before the instant it
    /// is asked about. Nothing in this file's own code enforces that, which is exactly why it is
    /// pinned here: a later "just use the newest reading, it's simpler" would compile, would look
    /// harmless, and would silently restore the bug.
    func testANewWeighInDoesNotMoveAnyEarlierDay() throws {
        let window = days("2026-09-04", "2026-09-03", "2026-09-02", "2026-09-01")
        let before = try IntelligenceEngine.weightByDay(
            days: window, observations: [obs("2026-09-01", 95.0)], fallbackKg: fallback)
        let after = try IntelligenceEngine.weightByDay(
            days: window,
            observations: [obs("2026-09-01", 95.0), obs("2026-09-04", 93.5)],
            fallbackKg: fallback)

        for day in ["2026-09-03", "2026-09-02", "2026-09-01"] {
            XCTAssertEqual(try XCTUnwrap(after[day]), try XCTUnwrap(before[day]), accuracy: 1e-9,
                           "a later weigh-in rewrote \(day) — the resolver is not causal")
        }
        XCTAssertNotEqual(try XCTUnwrap(after["2026-09-04"]),
                          try XCTUnwrap(before["2026-09-04"]),
                          "the day the measurement was taken on must move — otherwise it is ignored")
    }

    /// The other half of the same property: a day's OWN weigh-in counts for it. Excluding it would
    /// make this morning's measurement reach the wearer's numbers a day late, which is the behaviour
    /// they asked to keep.
    func testADaysOwnWeighInCountsForThatDay() throws {
        let out = try IntelligenceEngine.weightByDay(
            days: days("2026-09-04"), observations: [obs("2026-09-04", 93.5)], fallbackKg: fallback)
        XCTAssertEqual(try XCTUnwrap(out["2026-09-04"]), 93.5, accuracy: 1e-9)
    }

    // MARK: - Falling back

    /// No weigh-in history at all: every day gets the profile value, so the pass behaves exactly as it
    /// did before this change. A wearer who never weighs in must not be made worse off — and for them
    /// nothing invalidates either, because with no Health readings `applyHealthWeight` never fires.
    func testWithoutObservationsEveryDayTakesTheProfileWeight() {
        let window = days("2026-09-04", "2026-09-03", "2026-09-02")
        let out = IntelligenceEngine.weightByDay(days: window, observations: [], fallbackKg: fallback)
        XCTAssertEqual(out.count, window.count)
        for day in window { XCTAssertEqual(out[day], fallback) }
    }

    /// A day BEFORE the first weigh-in has nothing to resolve from and takes the profile value rather
    /// than borrowing a reading from its future.
    func testADayEarlierThanEveryObservationFallsBack() throws {
        let out = try IntelligenceEngine.weightByDay(
            days: days("2026-09-04", "2026-09-01"),
            observations: [obs("2026-09-03", 95.0)], fallbackKg: fallback)
        XCTAssertEqual(try XCTUnwrap(out["2026-09-01"]), fallback, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(out["2026-09-04"]), 95.0, accuracy: 1e-9)
    }

    /// Beyond the resolver's carry horizon the last reading stops standing in, and the day falls back
    /// instead of being scored against a year-old weight.
    func testAnObservationBeyondTheCarryHorizonIsNotUsed() throws {
        let out = try IntelligenceEngine.weightByDay(
            days: days("2026-09-04"), observations: [obs("2025-01-01", 95.0)], fallbackKg: fallback)
        XCTAssertEqual(try XCTUnwrap(out["2026-09-04"]), fallback, accuracy: 1e-9,
                       "a reading this old is not evidence about today")
    }

    // MARK: - Shape

    /// Every requested day gets an entry, so the signature builder never has to decide what a missing
    /// key means. A day silently absent here would fall back inside the closure instead, and the two
    /// fallbacks could drift.
    func testEveryRequestedDayIsPresent() throws {
        let window = days("2026-09-04", "2026-09-03", "2026-09-02", "2026-09-01")
        let out = try IntelligenceEngine.weightByDay(
            days: window, observations: [obs("2026-09-02", 95.0)], fallbackKg: fallback)
        XCTAssertEqual(Set(out.keys), Set(window))
    }

    /// An unparseable key cannot resolve and must not crash the pass; it takes the fallback like any
    /// other day the history does not reach.
    func testAnUnparseableDayKeyFallsBack() {
        let out = IntelligenceEngine.weightByDay(days: days("not-a-day"), observations: [],
                                                 fallbackKg: fallback)
        XCTAssertEqual(out["not-a-day"], fallback)
    }

    /// Days genuinely differ once the history moves between them — the point of resolving per day at
    /// all. Without this the change would be inert: one value for the window, just computed the long
    /// way round.
    func testDaysDifferWhenTheHistoryMovesBetweenThem() throws {
        let out = try IntelligenceEngine.weightByDay(
            days: days("2026-09-04", "2026-09-01"),
            observations: [obs("2026-09-01", 95.0), obs("2026-09-04", 90.0)],
            fallbackKg: fallback)
        XCTAssertNotEqual(try XCTUnwrap(out["2026-09-04"]), try XCTUnwrap(out["2026-09-01"]))
    }
}

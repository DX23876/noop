import XCTest
@testable import Strand

/// Pins the max-HR override's effective-from resolution.
///
/// Measured twice in one afternoon on a real device, for two taps on the Settings stepper:
///
///     reuse semantic diff (first miss, day=2026-09-05): hrmax: 203 → 195   → 21 days, 681 s
///     reuse semantic diff (first miss, day=2026-09-05): hrmax: 195 → 196   → 21 days, 259 s
///
/// Re-scoring was not wrong — max HR feeds Effort and, through the z2+ gate, which workouts are
/// detected at all. Applying it BACKWARDS was: last month's nights were lived at last month's value,
/// and re-scoring them against a number set today rewrites history with information that did not exist
/// then. A value now takes effect from the day it is set, which is both the more honest answer and the
/// thing that stops the re-derivation — an untouched day keeps a matching fingerprint.
final class HrmaxByDayTests: XCTestCase {

    private let fallback = 190

    private func days(_ keys: String...) -> [String] { keys }

    // MARK: - The regression

    /// THE test. Setting a value today must not change what ANY earlier day resolves to. That is the
    /// whole difference between re-scoring one day and re-scoring twenty-one.
    func testAValueSetTodayDoesNotMoveAnyEarlierDay() {
        let window = days("2026-09-05", "2026-09-04", "2026-09-03", "2026-09-02")
        let before = IntelligenceEngine.hrmaxByDay(
            days: window, journal: [(day: "2026-09-02", value: 203)], fallback: fallback)
        let after = IntelligenceEngine.hrmaxByDay(
            days: window,
            journal: [(day: "2026-09-02", value: 203), (day: "2026-09-05", value: 195)],
            fallback: fallback)

        for day in ["2026-09-04", "2026-09-03", "2026-09-02"] {
            XCTAssertEqual(after[day], before[day],
                           "setting a value today rewrote \(day) — the change is not forward-only")
        }
        XCTAssertEqual(after["2026-09-05"], 195, "the day it was set on must take the new value")
    }

    /// Forward, not just "not backward": the entry's own day and everything after it take the new value.
    func testTheValueAppliesFromItsOwnDayOnward() {
        let out = IntelligenceEngine.hrmaxByDay(
            days: days("2026-09-06", "2026-09-05", "2026-09-04"),
            journal: [(day: "2026-09-01", value: 203), (day: "2026-09-05", value: 195)],
            fallback: fallback)
        XCTAssertEqual(out["2026-09-04"], 203)
        XCTAssertEqual(out["2026-09-05"], 195)
        XCTAssertEqual(out["2026-09-06"], 195)
    }

    /// Several taps in one day are ONE value, the last. Matches the store's own (deviceId, day, key)
    /// uniqueness, and it is why nudging the stepper repeatedly cannot cost more than one day's re-score.
    func testSeveralEntriesOnOneDayResolveToTheLast() {
        let out = IntelligenceEngine.hrmaxByDay(
            days: days("2026-09-05"),
            journal: [(day: "2026-09-05", value: 203), (day: "2026-09-05", value: 195),
                      (day: "2026-09-05", value: 196)],
            fallback: fallback)
        XCTAssertEqual(out["2026-09-05"], 196)
    }

    // MARK: - Falling back

    /// An empty journal leaves every day on the passed-in value, so a fresh install behaves exactly as
    /// it did before this existed.
    func testAnEmptyJournalLeavesEveryDayOnTheFallback() {
        let window = days("2026-09-05", "2026-09-04")
        let out = IntelligenceEngine.hrmaxByDay(days: window, journal: [], fallback: fallback)
        XCTAssertEqual(out.count, window.count)
        for day in window { XCTAssertEqual(out[day], fallback) }
    }

    /// A day earlier than every entry takes the fallback — never a value from its own future, which is
    /// the failure mode this whole change is about.
    func testADayBeforeEveryEntryTakesTheFallbackNotALaterValue() {
        let out = IntelligenceEngine.hrmaxByDay(
            days: days("2026-08-01"), journal: [(day: "2026-09-05", value: 195)],
            fallback: fallback)
        XCTAssertEqual(out["2026-08-01"], fallback)
    }

    /// Zero is a real value — "automatic", i.e. derive from age — not a missing one. Treating it as
    /// absent would silently re-pin such a day to whatever the profile says now.
    func testZeroIsCarriedAsAValueNotTreatedAsAbsent() {
        let out = IntelligenceEngine.hrmaxByDay(
            days: days("2026-09-05"), journal: [(day: "2026-09-01", value: 0)], fallback: fallback)
        XCTAssertEqual(out["2026-09-05"], 0)
    }

    // MARK: - The changeover must be free

    /// THE acceptance property, and the one worth the most: with a single seed entry carrying the
    /// install's current value, every day resolves to that value — so the per-day signature is
    /// byte-identical to the pass-global string it replaces, stored fingerprints still match, and
    /// shipping this costs no re-derivation at all. (The weight fix had to pay for one; this must not.)
    ///
    /// Asserted on the assembled STRING, not just the resolved number, because the signature is compared
    /// as raw text: moving `hrmax` to the end of the field order would resolve identically and still
    /// invalidate all twenty-one days.
    func testASeededJournalReproducesTheLegacySignatureByteForByte() {
        let window = (0..<21).map { String(format: "2026-09-%02d", 21 - $0) }
        let current = 203
        let resolved = IntelligenceEngine.hrmaxByDay(
            days: window, journal: [(day: window.last!, value: current)], fallback: current)

        let head = "height=4640607293656334336|age=35|sex=male"
        let tail = "stepTicks=4609434218613702656|tz=7200|deepHrv=1"
        let legacy = "\(head)|hrmax=\(current)|\(tail)"
        for day in window {
            let perDay = "\(head)|hrmax=\(resolved[day] ?? current)|\(tail)"
            XCTAssertEqual(perDay, legacy, "day \(day) no longer reproduces the pass-global signature")
        }
    }

    /// And the diff stays readable for the one case that DOES still invalidate a day — today, after a
    /// genuine change. It has to name the field, or the log says only "semanticSignature".
    func testAnHrmaxOnlyDifferenceIsReportedAsHrmaxAlone() {
        let base = "height=4640607293656334336|age=35|sex=male"
        XCTAssertEqual(
            IntelligenceEngine.semanticSignatureDiff(stored: "\(base)|hrmax=203|tz=7200",
                                                     current: "\(base)|hrmax=195|tz=7200"),
            ["hrmax: 203 → 195"])
    }
}

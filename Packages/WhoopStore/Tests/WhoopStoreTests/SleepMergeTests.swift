import XCTest
import WhoopStore

/// #715 — merging imported + computed sleep must preserve EVERY session. The old per-day dictionary
/// (`[String: CachedSleepSession]`) overwrote on collision, so a day with two sessions (a main night
/// and a nap, or two nights) silently lost one in both the app and the CSV export.
final class SleepMergeTests: XCTestCase {

    private func session(start: Int, end: Int, stages: String? = nil) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil,
                           restingHr: nil, avgHrv: nil, stagesJSON: stages)
    }
    /// One hour of segments. Against the 8-hour spans these tests use this is a HOLED timeline — which
    /// is deliberate for the presence-rule cases below (rank 1 behaves exactly as the old "has stages"
    /// did against a stage-less day) and is the fixture the coverage cases contrast with `tiling`.
    private let someStages = #"[{"start":0,"end":3600,"stage":"deep"}]"#
    /// A single segment that covers `[start, end)` exactly — a night that accounts for its own span.
    private func tiling(_ start: Int, _ end: Int) -> String {
        #"[{"start":\#(start),"end":\#(end),"stage":"deep"}]"#
    }
    // Deterministic "local day" keyer for the tests (real callers pass their tz-aware keyer).
    private let dayKey: (CachedSleepSession) -> String = { String($0.endTs / 86_400) }

    func testTwoComputedSessionsSameEndDayBothSurvive() {
        let night = session(start: 0, end: 8 * 3600)            // ends day 0
        let nap   = session(start: 14 * 3600, end: 15 * 3600)   // ALSO ends day 0
        let merged = SleepMerge.merge(imported: [], computed: [night, nap], endDay: dayKey)
        XCTAssertEqual(merged.count, 2, "both same-end-day sessions must survive")
        XCTAssertEqual(merged.map(\.startTs), [0, 14 * 3600], "sorted by start")
    }

    func testTwoImportedSessionsSameEndDayBothSurvive() {
        let a = session(start: 0, end: 8 * 3600)
        let b = session(start: 14 * 3600, end: 15 * 3600)
        let merged = SleepMerge.merge(imported: [a, b], computed: [], endDay: dayKey)
        XCTAssertEqual(merged.count, 2)
    }

    func testImportedWinsForItsDayButKeepsComputedOnOtherDays() {
        let compDay0 = session(start: 0, end: 8 * 3600)                 // day 0
        let compDay1 = session(start: 86_400, end: 86_400 + 8 * 3600)   // day 1
        let impDay0  = session(start: 3600, end: 8 * 3600 + 1800)       // day 0, imported
        let merged = SleepMerge.merge(imported: [impDay0], computed: [compDay0, compDay1], endDay: dayKey)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.startTs == 3600 }, "imported day-0 session kept")
        XCTAssertFalse(merged.contains { $0.startTs == 0 }, "computed day-0 session yields to imported")
        XCTAssertTrue(merged.contains { $0.startTs == 86_400 }, "computed day-1 session untouched")
    }

    func testEmptyInputsReturnEmpty() {
        XCTAssertTrue(SleepMerge.merge(imported: [], computed: [], endDay: dayKey).isEmpty)
    }

    // Richness exception (Swift twin of ryanbr/noop#240): a stage-less import must not blank a
    // computed day that has stage data.

    func testStagelessImportYieldsToComputedDayWithStages() {
        let comp = session(start: 0, end: 8 * 3600, stages: someStages)
        let imp  = session(start: 3600, end: 8 * 3600 + 1800)            // same day, no stages
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [0], "computed session with stages survives sparse import")
    }

    func testImportWithStagesStillWinsItsDay() {
        let comp = session(start: 0, end: 8 * 3600, stages: someStages)
        let imp  = session(start: 3600, end: 8 * 3600 + 1800, stages: someStages)
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [3600], "imported-over-computed unchanged when import has stages")
    }

    func testNeitherSideHasStagesImportStillWins() {
        let comp = session(start: 0, end: 8 * 3600)
        let imp  = session(start: 3600, end: 8 * 3600 + 1800)
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [3600], "no richness signal , keep imported-wins rule")
    }

    func testEmptyArrayAndBlankStagesJSONCountAsStageless() {
        let comp = session(start: 0, end: 8 * 3600, stages: someStages)
        let impEmpty = session(start: 3600, end: 8 * 3600 + 1800, stages: "[]")
        let impBlank = session(start: 86_400 + 3600, end: 86_400 + 8 * 3600, stages: "  ")
        let compDay1 = session(start: 86_400, end: 86_400 + 8 * 3600, stages: someStages)
        let merged = SleepMerge.merge(imported: [impEmpty, impBlank],
                                      computed: [comp, compDay1], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [0, 86_400], #""[]" and blank JSON are not stages"#)
    }

    // Coverage rank: a stage timeline that covers only part of the span it claims (a device hypnogram
    // assembled from records that arrived incomplete) outranks nothing, but not a whole night.

    /// The case the presence-only rule could not express, and the reason this change exists: a HOLED
    /// import used to win purely by being an import, blanking a computed night that covers itself.
    func testHoledImportYieldsToFullyCoveredComputedNight() {
        let comp = session(start: 0, end: 8 * 3600, stages: tiling(0, 8 * 3600))
        let imp  = session(start: 0, end: 8 * 3600, stages: someStages)   // 1 h of segments over 8 h
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [0])
        XCTAssertEqual(merged.first?.stagesJSON, tiling(0, 8 * 3600),
                       "the night that covers its own span wins over a holed import")
    }

    /// …but partial data still beats none. A holed import must not lose to a stage-less computed day.
    func testHoledImportStillBeatsStagelessComputed() {
        let comp = session(start: 0, end: 8 * 3600)                        // no stages
        let imp  = session(start: 3600, end: 8 * 3600 + 1800, stages: someStages)
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [3600], "some stages beat none, holed or not")
    }

    /// Equal rank keeps the imported-over-computed default — the rule only fires on a strict out-rank.
    func testEquallyHoledSidesKeepImportedWins() {
        let comp = session(start: 0, end: 8 * 3600, stages: someStages)
        let imp  = session(start: 3600, end: 8 * 3600 + 1800, stages: someStages)
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [3600])
    }

    /// A fully-covered import is untouched by any of this.
    func testFullyCoveredImportStillWins() {
        let comp = session(start: 0, end: 8 * 3600, stages: tiling(0, 8 * 3600))
        let imp  = session(start: 3600, end: 3600 + 8 * 3600, stages: tiling(3600, 3600 + 8 * 3600))
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [3600])
    }

    /// The imported minute-dict shape carries no timestamps, so it can never be judged holed — every
    /// WHOOP/Apple/Health-Connect import keeps its existing precedence.
    func testImportedMinuteDictIsNeverHoled() {
        let comp = session(start: 0, end: 8 * 3600, stages: tiling(0, 8 * 3600))
        let imp  = session(start: 3600, end: 8 * 3600 + 1800,
                           stages: #"{"light":300,"deep":100,"rem":80,"awake":40}"#)
        let merged = SleepMerge.merge(imported: [imp], computed: [comp], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [3600], "a dict-shaped import is not measurable, so it wins as before")
    }

    func testRichnessExceptionKeepsEverySessionOfWinningDay() {
        // Day has computed main night (with stages) + computed nap (no stages); import is stage-less.
        // The WHOLE computed day survives — #715's keep-every-session guarantee still holds.
        let night = session(start: 0, end: 8 * 3600, stages: someStages)
        let nap   = session(start: 14 * 3600, end: 15 * 3600)
        let imp   = session(start: 3600, end: 8 * 3600 + 1800)
        let merged = SleepMerge.merge(imported: [imp], computed: [night, nap], endDay: dayKey)
        XCTAssertEqual(merged.map(\.startTs), [0, 14 * 3600])
    }
}

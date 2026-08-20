import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// A strap that MEASURES its own respiratory rate (the Oura ring's 0x6A `breath`) supplies the night's
/// `respRateBpm` instead of NOOP's RSA-from-R-R estimate — and the personal baseline that value feeds is
/// scoped to the current device era, so a strap switch is not read as physiology.
final class VendorRespRateTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let ring = "oura-2H3B2405003655"

    // MARK: - fixtures

    private func nightStreams(start: Int, end: Int) -> (hr: [HRSample], rr: [RRInterval]) {
        let hr = stride(from: start, to: end, by: 30).map { HRSample(ts: $0, bpm: 52 + ($0 / 300) % 4) }
        var i = 0
        let rr = stride(from: start, to: end, by: 2).map { ts -> RRInterval in
            defer { i += 1 }
            return RRInterval(ts: ts, rrMs: 1080 + (i % 6) * 8)
        }
        return (hr, rr)
    }

    private func hypnogram(start: Int) -> [StageSegment] {
        var t = start
        func seg(_ mins: Int, _ stage: String) -> StageSegment {
            let s = StageSegment(start: t, end: t + mins * 60, stage: stage); t += mins * 60; return s
        }
        return [seg(20, "wake"), seg(100, "light"), seg(60, "deep"), seg(60, "light"),
                seg(60, "rem"), seg(120, "light"), seg(60, "deep"), seg(60, "rem"),
                seg(40, "light"), seg(20, "wake")]
    }

    /// Ring respiration rows at `everyS` spacing across `[start, start + durationS)`, cycling through
    /// the 0.125-step values a real night holds.
    private func ringRows(start: Int, durationS: Int, everyS: Int = 296,
                          bpms: [Double] = [14.25, 14.5, 14.625, 14.75, 15.0]) -> [RespSample] {
        stride(from: 0, to: durationS, by: everyS).enumerated().map { i, off in
            RespSample(ts: start + off,
                       raw: OuraRespScale.milliBpm(fromBreathsPerMin: bpms[i % bpms.count]),
                       unit: OuraRespScale.unitTag)
        }
    }

    // MARK: - The nightly value

    /// The median of the rows inside the session, in bpm — the same statistic the ledger this decode was
    /// validated with used.
    func testNightlyValueIsTheMedianOfTheInSessionRows() {
        let start = 1_754_000_000
        let rows = ringRows(start: start, durationS: 8 * 3_600)
        let v = AnalyticsEngine.vendorRespRateBpm(rows, sessions: [(start: start, end: start + 8 * 3_600)])
        XCTAssertNotNil(v)
        XCTAssertEqual(v ?? 0, 14.625, accuracy: 1e-9)
    }

    /// Rows outside the in-bed window are not part of the night. A daytime tail must not drag it.
    func testRowsOutsideTheSessionAreIgnored() {
        let start = 1_754_000_000
        let night = ringRows(start: start, durationS: 8 * 3_600, bpms: [14.5])
        let daytime = ringRows(start: start + 12 * 3_600, durationS: 4 * 3_600, bpms: [22.0])
        let v = AnalyticsEngine.vendorRespRateBpm(night + daytime,
                                                  sessions: [(start: start, end: start + 8 * 3_600)])
        XCTAssertEqual(v ?? 0, 14.5, accuracy: 1e-9)
    }

    /// A fragment of a night is not a night. The ledger's two thin captures (0.6 h and 2.0 h of
    /// coverage) are exactly the rows that must not enter a personal baseline as though they described
    /// the night — the gate is on SPAN, not on row count, because the record cadence is not constant.
    func testAFragmentOfANightIsRefused() {
        let start = 1_754_000_000
        let session = (start: start, end: start + 8 * 3_600)
        // 36 minutes of dense (30 s) rows: many rows, far too little of the night.
        let dense = ringRows(start: start + 7 * 3_600, durationS: 36 * 60, everyS: 30)
        XCTAssertGreaterThan(dense.count, 60, "fixture sanity: row COUNT alone would pass any count gate")
        XCTAssertNil(AnalyticsEngine.vendorRespRateBpm(dense, sessions: [session]))

        // Two hours of the same night does clear the one-hour span floor.
        let twoHours = ringRows(start: start + 6 * 3_600, durationS: 2 * 3_600, everyS: 296)
        XCTAssertNotNil(AnalyticsEngine.vendorRespRateBpm(twoHours, sessions: [session]))
    }

    /// One corrupt record can never publish an impossible rate: the median must land in the same
    /// plausible band the RSA path is clamped to.
    func testAnImplausibleMedianIsRefused() {
        let start = 1_754_000_000
        let rows = ringRows(start: start, durationS: 8 * 3_600, bpms: [31.875])   // the wire's ceiling
        XCTAssertNil(AnalyticsEngine.vendorRespRateBpm(rows, sessions: [(start: start,
                                                                        end: start + 8 * 3_600)]))
    }

    func testNoRowsAndNoSessionsYieldNothing() {
        let start = 1_754_000_000
        XCTAssertNil(AnalyticsEngine.vendorRespRateBpm([], sessions: [(start: start, end: start + 3_600)]))
        XCTAssertNil(AnalyticsEngine.vendorRespRateBpm(ringRows(start: start, durationS: 8 * 3_600),
                                                       sessions: []))
    }

    // MARK: - Through analyzeDay, on the night shape a ring actually produces

    /// A ring night: no gravity, staged from the ring's OWN hypnogram (#804 Fix A). With the ring's
    /// respiration rows it reports the ring's measured rate; without them the day falls back to the RSA
    /// estimate, which is what every WHOOP night keeps doing.
    func testAnalyzeDayPrefersTheDeviceMeasuredRate() {
        let day = "2026-08-14"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let sleepStart = dayStart - 4 * 3_600
        let sleepEnd = sleepStart + 600 * 60
        let s = nightStreams(start: sleepStart, end: sleepEnd)
        let provided = [SleepSession(start: sleepStart, end: sleepEnd, efficiency: 0.75,
                                     stages: hypnogram(start: sleepStart), restingHR: nil, avgHRV: nil)]
        let rows = ringRows(start: sleepStart, durationS: 600 * 60)

        let withVendor = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, vendorResp: rows,
                                                    profile: profile, providedSleep: provided)
        XCTAssertEqual(withVendor.daily.respRateBpm ?? 0, 14.625, accuracy: 1e-9)

        let without = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr,
                                                 profile: profile, providedSleep: provided)
        XCTAssertNotEqual(without.daily.respRateBpm ?? -1, 14.625,
                          "without the rows the day must not report the device rate")
    }

    /// Passing no vendor rows leaves every field of the day byte-identical to omitting the parameter —
    /// the guarantee that every WHOOP night is untouched by this change.
    func testEmptyVendorRespIsByteIdenticalToOmitting() {
        let day = "2026-08-14"
        let dayStart = AnalyticsEngine.dayStartUtcSeconds(day)
        let sleepStart = dayStart - 4 * 3_600
        let s = nightStreams(start: sleepStart, end: sleepStart + 600 * 60)
        let provided = [SleepSession(start: sleepStart, end: sleepStart + 600 * 60, efficiency: 0.75,
                                     stages: hypnogram(start: sleepStart), restingHR: nil, avgHRV: nil)]

        let omitted = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr,
                                                 profile: profile, providedSleep: provided)
        let empty = AnalyticsEngine.analyzeDay(day: day, hr: s.hr, rr: s.rr, vendorResp: [],
                                               profile: profile, providedSleep: provided)
        XCTAssertEqual(omitted.daily, empty.daily)
    }

    // MARK: - The baseline the value feeds

    /// The composition IntelligenceEngine performs, pinned here because the wiring itself lives in the
    /// app target where no test runs: a respiration history that crosses brands must fold from the
    /// CURRENT era only. A WHOOP export reports ~16.1 and the ring ~14.6; pooled, the switch reads as a
    /// multi-sigma drop — a device artifact scored as physiology.
    func testRespBaselineFoldsTheCurrentDeviceEraOnly() {
        guard let cfg = Baselines.metricCfg["resp"] else { return XCTFail("no resp cfg") }
        var dayKeys: [String] = []
        var values: [Double?] = []
        var sources: [(day: String, sourceId: String)] = []
        // 20 WHOOP-import nights at ~16.1, then 10 ring nights at ~14.6.
        for i in 0..<30 {
            let day = String(format: "2026-07-%02d", i + 1)
            let isRing = i >= 20
            dayKeys.append(day)
            values.append(isRing ? 14.6 : 16.1)
            sources.append((day: day, sourceId: isRing ? ring : "my-whoop"))
        }
        let epoch = Baselines.deviceEraEpoch(sources)
        XCTAssertGreaterThan(epoch, 0, "a brand switch must open a new era")

        let scoped = Baselines.foldHistory(values, dayKeys: dayKeys, cfg: cfg, baselineEpoch: epoch)
        let pooled = Baselines.foldHistory(values, dayKeys: dayKeys, cfg: cfg, baselineEpoch: 0)
        XCTAssertEqual(scoped.baseline, 14.6, accuracy: 0.05,
                       "the era-scoped baseline sits on the ring's own nights")
        XCTAssertGreaterThan(pooled.baseline, scoped.baseline + 0.2,
                             "the pooled baseline is dragged up by the previous strap — the defect")
        // And the consequence that matters: against the pooled baseline a normal ring night reads as a
        // large deviation, which is what would reach the illness watch.
        XCTAssertLessThan(Baselines.deviation(14.6, state: scoped).z.magnitude, 1.0)
        XCTAssertGreaterThan(Baselines.deviation(14.6, state: pooled).z.magnitude, 1.0)
    }

    /// A single-brand history is untouched: `deviceEraEpoch` returns 0 for every WHOOP-origin id, so an
    /// existing user's baseline folds exactly as it did before.
    func testASingleBrandHistoryIsUnscoped() {
        let days = (1...30).map { (day: String(format: "2026-07-%02d", $0),
                                   sourceId: $0 % 2 == 0 ? "my-whoop" : "my-whoop-noop") }
        XCTAssertEqual(Baselines.deviceEraEpoch(days), 0.0, accuracy: 0.0)
    }
}

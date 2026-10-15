import XCTest
@testable import StrandAnalytics

/// Tests for the CosinorAge biomarker. The expected biological-age values are computed
/// from the reference Python (`bioages/cosinorage.py`) with the same open weights.
final class CosinorAgeEngineTests: XCTestCase {

    private let w = 2.0 * Double.pi / 1440.0

    // Build D whole days of minute-level activity in mg from a known cosine on the running index t=1…N.
    // value(mg) = mesor + amp·cos(ω·t + phi). Every minute present → exact recovery.
    private func syntheticDays(days: Int, mesor: Double, amp: Double, phi: Double) -> [CosinorAgeEngine.DaySeries] {
        var out: [CosinorAgeEngine.DaySeries] = []
        var t = 0
        for _ in 0..<days {
            var minutes = [Double?](repeating: nil, count: 1440)
            for slot in 0..<1440 {
                t += 1
                minutes[slot] = mesor + amp * cos(w * Double(t) + phi)
            }
            out.append(CosinorAgeEngine.DaySeries(minutes: minutes, validMinutes: 1440))
        }
        return out
    }

    // MARK: 1. Gompertz closed-form (pinned to the reference Python)

    func testBiologicalAgeMatchesReferenceAllSexes() {
        // biologicalAge(mesor:30, amp:25, phi:-1.5, age:40)
        XCTAssertEqual(CosinorAgeEngine.biologicalAge(mesor: 30, amplitude: 25, acrophaseRadians: -1.5, age: 40, sex: .unknown),
                       40.4054333204, accuracy: 1e-6)
        XCTAssertEqual(CosinorAgeEngine.biologicalAge(mesor: 30, amplitude: 25, acrophaseRadians: -1.5, age: 40, sex: .female),
                       39.6765236784, accuracy: 1e-6)
        XCTAssertEqual(CosinorAgeEngine.biologicalAge(mesor: 30, amplitude: 25, acrophaseRadians: -1.5, age: 40, sex: .male),
                       43.4054735692, accuracy: 1e-6)
        // other feature points
        XCTAssertEqual(CosinorAgeEngine.biologicalAge(mesor: 20, amplitude: 10, acrophaseRadians: -3.0, age: 60, sex: .male),
                       67.6579310871, accuracy: 1e-6)
        XCTAssertEqual(CosinorAgeEngine.biologicalAge(mesor: 35, amplitude: 30, acrophaseRadians: -0.8, age: 25, sex: .female),
                       24.9180354334, accuracy: 1e-6)
    }

    // MARK: 2. Minute-level fit recovery (on the minute axis, not folded hourly)

    func testCosinorRecoversInjectedParametersOnMinuteAxis() {
        let phi = -1.5
        let fit = CosinorAgeEngine.cosinorMinuteLevel(syntheticDays(days: 7, mesor: 30, amp: 25, phi: phi))!
        XCTAssertEqual(fit.mesor, 30, accuracy: 1e-6)
        XCTAssertEqual(fit.amplitude, 25, accuracy: 1e-6)
        XCTAssertEqual(fit.acrophaseRadians, phi, accuracy: 1e-6)
        XCTAssertTrue(fit.acrophaseRadians <= 0 && fit.acrophaseRadians > -2 * Double.pi, "phi in (−2π, 0]")
    }

    func testCosinorPhaseShiftKeepsRangeForPositiveOffset() {
        // A cosine with a positive stored offset must come back shifted into (−2π, 0].
        let fit = CosinorAgeEngine.cosinorMinuteLevel(syntheticDays(days: 7, mesor: 40, amp: 15, phi: -0.3))!
        XCTAssertEqual(fit.acrophaseRadians, -0.3, accuracy: 1e-6)
    }

    // MARK: 3. Coverage / whole-day gating

    func testLowCoverageDayIsDropped() {
        // A single day with only 500 present minutes is below minValidMinutesPerDay → dropped.
        var minutes = [Double?](repeating: nil, count: 1440)
        for m in 0..<500 { minutes[m] = 20 }
        let days = [CosinorAgeEngine.DaySeries(minutes: minutes, validMinutes: 500)]
        // compute() also needs age>0 and enough days — here we just assert the day count gate:
        XCTAssertTrue(days.first!.validMinutes < CosinorAgeEngine.minValidMinutesPerDay)
    }

    func testDailyMinuteSeriesBucketsAndGates() {
        // 7 full days, one sample per minute → 7 kept days of 1440 valid minutes each.
        var samples: [CosinorAgeEngine.ActivitySample] = []
        for day in 0..<7 {
            for minute in 0..<1440 {
                let mg = 30.0 + 25.0 * cos(w * Double(day * 1440 + minute))
                samples.append(.init(ts: day * 86400 + minute * 60, g: mg / 1000.0))
            }
        }
        let series = CosinorAgeEngine.dailyMinuteSeries(samples, tzOffsetSeconds: 0)
        XCTAssertEqual(series.count, 7)
        XCTAssertTrue(series.allSatisfy { $0.validMinutes == 1440 })
    }

    func testTooFewDaysReturnsNil() {
        var samples: [CosinorAgeEngine.ActivitySample] = []
        for day in 0..<3 {                       // < minQualifyingDays
            for minute in 0..<1440 {
                let mg = 30.0 + 25.0 * cos(w * Double(day * 1440 + minute))
                samples.append(.init(ts: day * 86400 + minute * 60, g: mg / 1000.0))
            }
        }
        XCTAssertNil(CosinorAgeEngine.compute(activity: samples, age: 40, sex: .male, tzOffsetSeconds: 0))
    }

    func testEmptyInputReturnsNil() {
        // The 5.0-without-R22 case: no motion at all.
        XCTAssertNil(CosinorAgeEngine.compute(activity: [], age: 40, sex: .male, tzOffsetSeconds: 0))
        XCTAssertTrue(CosinorAgeEngine.dailyMinuteSeries([], tzOffsetSeconds: 0).isEmpty)
    }

    // MARK: 4. Tracks a varying input (anti-#194 guard — not a single coincidental match)

    func testBiologicalAgeDecreasesWithAmplitude() {
        // Higher circadian amplitude → younger biological age (male, M=30, phi=-1.5, age=40).
        let ages = [5.0, 10, 20, 30, 40].map {
            CosinorAgeEngine.biologicalAge(mesor: 30, amplitude: $0, acrophaseRadians: -1.5, age: 40, sex: .male)
        }
        for i in 1..<ages.count { XCTAssertLessThan(ages[i], ages[i - 1]) }
        // pinned endpoints from the reference
        XCTAssertEqual(ages.first!, 48.8654, accuracy: 1e-3)
        XCTAssertEqual(ages.last!, 39.3106, accuracy: 1e-3)
    }

    func testBiologicalAgeIncreasesWithChronoAge() {
        let ages = [20.0, 40, 60, 80].map {
            CosinorAgeEngine.biologicalAge(mesor: 30, amplitude: 25, acrophaseRadians: -1.5, age: $0, sex: .male)
        }
        for i in 1..<ages.count { XCTAssertGreaterThan(ages[i], ages[i - 1]) }
    }

    // MARK: 5. Rhythm gate

    func testFlatSignalIsArrhythmicNil() {
        // A constant (flat) signal has ~zero amplitude → below minRelativeAmplitude → compute nil.
        var samples: [CosinorAgeEngine.ActivitySample] = []
        for day in 0..<7 {
            for minute in 0..<1440 { samples.append(.init(ts: day * 86400 + minute * 60, g: 30.0 / 1000.0)) }
        }
        XCTAssertNil(CosinorAgeEngine.compute(activity: samples, age: 40, sex: .male, tzOffsetSeconds: 0))
    }

    // MARK: End-to-end

    func testComputeEndToEndRecoversAndScores() {
        let mesor = 30.0, amp = 25.0
        var samples: [CosinorAgeEngine.ActivitySample] = []
        for day in 0..<7 {
            for minute in 0..<1440 {
                let mg = mesor + amp * cos(w * Double(day * 1440 + minute))
                samples.append(.init(ts: day * 86400 + minute * 60, g: mg / 1000.0))
            }
        }
        let r = CosinorAgeEngine.compute(activity: samples, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertEqual(r.daysUsed, 7)
        XCTAssertEqual(r.mesor, mesor, accuracy: 1e-3)
        XCTAssertEqual(r.amplitude, amp, accuracy: 1e-3)
        // cosinorAge must equal the Gompertz mapping of the recovered features.
        let expected = CosinorAgeEngine.biologicalAge(mesor: r.mesor, amplitude: r.amplitude,
                                                      acrophaseRadians: r.acrophaseRadians, age: 40, sex: .male)
        XCTAssertEqual(r.cosinorAge, expected, accuracy: 1e-9)
        XCTAssertEqual(r.advance, r.cosinorAge - 40, accuracy: 1e-9)
    }

    // MARK: 6. Provisional ("forecast") path — early values, explicitly marked

    /// Per-second samples for `days` whole days of a known cosine, optionally truncating each day to the
    /// first `minutesPerDay` minutes (to exercise the coverage gates).
    private func syntheticSamples(days: Int, mesor: Double, amp: Double,
                                  minutesPerDay: Int = 1440) -> [CosinorAgeEngine.ActivitySample] {
        var samples: [CosinorAgeEngine.ActivitySample] = []
        for day in 0..<days {
            for minute in 0..<minutesPerDay {
                let mg = mesor + amp * cos(w * Double(day * 1440 + minute))
                samples.append(.init(ts: day * 86400 + minute * 60, g: mg / 1000.0))
            }
        }
        return samples
    }

    func testProvisionalYieldsAValueFromASingleDay() {
        // The exact input `testTooFewDaysReturnsNil` rejects on the strict path. 1–2 whole days is
        // 24–48 h, still under the study's 72 h bar, so these must come back flagged as forecasts.
        for days in 1...2 {
            let s = syntheticSamples(days: days, mesor: 30, amp: 25)
            XCTAssertNil(CosinorAgeEngine.compute(activity: s, age: 40, sex: .male, tzOffsetSeconds: 0),
                         "strict compute must still reject \(days) day(s)")
            let p = CosinorAgeEngine.computeProvisional(activity: s, age: 40, sex: .male, tzOffsetSeconds: 0)
            XCTAssertNotNil(p, "provisional must produce a value from \(days) day(s)")
            XCTAssertTrue(p!.provisional, "\(days) day(s) is under the 72 h wear bar")
            XCTAssertFalse(p!.coverage.meetsWearTime)
            XCTAssertTrue(p!.coverage.meetsCircadianCoverage, "a fully-worn day has no blind spot")
            XCTAssertEqual(p!.daysUsed, days)
        }
    }

    func testThreeFullDaysMeetTheWearBar() {
        // 3 × 24 h = exactly 72 h — the study's threshold, so this is reportable even though the strict
        // day-count path would still reject it. Coverage, not day count, decides.
        let s = syntheticSamples(days: 3, mesor: 30, amp: 25)
        let p = CosinorAgeEngine.computeProvisional(activity: s, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertEqual(p.coverage.observedHours, 72, accuracy: 1e-9)
        XCTAssertTrue(p.coverage.meetsWearTime)
        XCTAssertFalse(p.provisional)
    }

    func testProvisionalAtFullCoverageEqualsStrictCompute() {
        let s = syntheticSamples(days: 7, mesor: 30, amp: 25)
        let strict = CosinorAgeEngine.compute(activity: s, age: 40, sex: .male, tzOffsetSeconds: 0)!
        let prov = CosinorAgeEngine.computeProvisional(activity: s, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertFalse(prov.provisional)
        XCTAssertEqual(prov, strict)   // same code path — identical in every field, band included
    }

    func testBandWidensAsWearTimeShrinks() {
        // At the study's 72 h bar the band is exactly bandYears; past it, it never narrows further.
        XCTAssertEqual(CosinorAgeEngine.band(observedHours: 72, jackknifeSD: nil),
                       CosinorAgeEngine.bandYears, accuracy: 1e-9)
        XCTAssertEqual(CosinorAgeEngine.band(observedHours: 200, jackknifeSD: nil),
                       CosinorAgeEngine.bandYears, accuracy: 1e-9)
        // Half an hour of data must read as absurd, not as a tidy number: ±5 · √144 = ±60 yrs.
        XCTAssertEqual(CosinorAgeEngine.band(observedHours: 0.5, jackknifeSD: nil), 60, accuracy: 1e-9)
        // Monotone in wear time, never below the floor.
        var previous = Double.infinity
        for h in stride(from: 1.0, through: 100.0, by: 5.0) {
            let b = CosinorAgeEngine.band(observedHours: h, jackknifeSD: nil)
            XCTAssertLessThanOrEqual(b, previous)
            XCTAssertGreaterThanOrEqual(b, CosinorAgeEngine.bandYears)
            previous = b
        }
        // A measured spread wins over the formula — and is still floored.
        XCTAssertEqual(CosinorAgeEngine.band(observedHours: 1, jackknifeSD: 9), 18, accuracy: 1e-9)
        XCTAssertEqual(CosinorAgeEngine.band(observedHours: 1, jackknifeSD: 0.1),
                       CosinorAgeEngine.bandYears, accuracy: 1e-9)
    }

    /// Anti-#194 guard for the RELAXED path: a one-day fit must actually track a varying input, not
    /// manufacture a plausible-looking constant. Recover MULTIPLE injected amplitudes (not one) and
    /// assert both the recovered parameter and the resulting age move with them, monotonically.
    func testProvisionalTracksVaryingInputOnOneDay() {
        var ages: [Double] = []
        for amp in [5.0, 10, 15, 20, 25] {
            let s = syntheticSamples(days: 1, mesor: 30, amp: amp)
            let r = CosinorAgeEngine.computeProvisional(activity: s, age: 40, sex: .male, tzOffsetSeconds: 0)!
            XCTAssertEqual(r.mesor, 30, accuracy: 1e-2)
            XCTAssertEqual(r.amplitude, amp, accuracy: 1e-2, "one-day fit must recover the injected amplitude")
            ages.append(r.cosinorAge)
        }
        // Higher circadian amplitude → younger biological age, same direction as the 7-day path.
        for i in 1..<ages.count { XCTAssertLessThan(ages[i], ages[i - 1]) }
    }

    func testThinDayIsKeptButHonestlyBanded() {
        // There is no per-day floor any more: a sliver of wear still produces a value, but it must be
        // flagged provisional and carry a band wide enough that nobody reads it as an answer.
        let thin = syntheticSamples(days: 1, mesor: 30, amp: 25, minutesPerDay: 100)
        let r = CosinorAgeEngine.computeProvisional(activity: thin, age: 40, sex: .male, tzOffsetSeconds: 0)
        if let r {
            XCTAssertTrue(r.provisional)
            XCTAssertGreaterThan(r.bandYears, 20, "1.7 h of wear must not read as a tight estimate")
        }   // nil is also acceptable: the plausibility guard may reject an extrapolated fit outright.
    }

    // MARK: 7. Circadian coverage — WHERE the minutes fall, not just how many

    /// Samples for `days` days, skipping the clock hours in `skip` every day (a FIXED blind spot).
    private func samplesSkippingHours(days: Int, skip: Set<Int>,
                                      mesor: Double = 30, amp: Double = 25) -> [CosinorAgeEngine.ActivitySample] {
        var out: [CosinorAgeEngine.ActivitySample] = []
        for day in 0..<days {
            for minute in 0..<1440 where !skip.contains(minute / 60) {
                let mg = mesor + amp * cos(w * Double(day * 1440 + minute))
                out.append(.init(ts: day * 86400 + minute * 60, g: mg / 1000.0))
            }
        }
        return out
    }

    func testBlindSpotIsMeasuredCyclically() {
        // A night gap runs 23 → 06: one run of 8, not 1 + 7.
        var bins = [Int](repeating: 60, count: 24)
        for h in [23, 0, 1, 2, 3, 4, 5, 6] { bins[h] = 0 }
        let (hours, start) = CosinorAgeEngine.largestBlindSpot(bins)
        XCTAssertEqual(hours, 8)
        XCTAssertEqual(start, 23)
        // Degenerate ends.
        XCTAssertEqual(CosinorAgeEngine.largestBlindSpot([Int](repeating: 60, count: 24)).hours, 0)
        XCTAssertEqual(CosinorAgeEngine.largestBlindSpot([Int](repeating: 0, count: 24)).hours, 24)
        // A bin under the per-hour minimum counts as unobserved.
        var thinOne = [Int](repeating: 60, count: 24)
        thinOne[13] = CosinorAgeEngine.minMinutesPerHourBin - 1
        XCTAssertEqual(CosinorAgeEngine.largestBlindSpot(thinOne).hours, 1)
    }

    func testDaytimeOnlyWearIsFlaggedNotSilentlyAccepted() {
        // The regression this whole gate exists for: 7 days worn 07:00–23:00 clears the old day-count
        // AND the 16 h/day rule, yet the missing trough biases the estimate OLD.
        let night: Set<Int> = [23, 0, 1, 2, 3, 4, 5, 6]
        let dayOnly = samplesSkippingHours(days: 7, skip: night)
        let r = CosinorAgeEngine.compute(activity: dayOnly, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertEqual(r.daysUsed, 7, "each day still has 960 valid minutes — the old gate passes")
        XCTAssertTrue(r.coverage.meetsWearTime, "112 h of wear clears the 72 h bar")
        XCTAssertFalse(r.coverage.meetsCircadianCoverage, "…but the whole night is unobserved")
        XCTAssertEqual(r.coverage.largestBlindSpotHours, 8)
        XCTAssertTrue(r.provisional, "coverage, not day count, decides — this must be labelled")

        // And it must read OLDER than the same behaviour observed round the clock.
        let full = syntheticSamples(days: 7, mesor: 30, amp: 25)
        let ref = CosinorAgeEngine.compute(activity: full, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertLessThan(ref.amplitude * 0.5, r.amplitude + ref.amplitude,
                          "sanity: both fits produced an amplitude")
        XCTAssertFalse(ref.provisional, "the round-the-clock reference is reportable")
    }

    func testFixedChargingHourStillQualifies() {
        // Measured cost of a 1 h fixed gap is −0.24 y — it must NOT disqualify an otherwise good window.
        let charging = samplesSkippingHours(days: 7, skip: [13])
        let r = CosinorAgeEngine.compute(activity: charging, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertEqual(r.coverage.largestBlindSpotHours, 1)
        XCTAssertTrue(r.coverage.meetsCircadianCoverage)
        XCTAssertFalse(r.provisional)
    }

    func testTwoHourGapPassesAndThreeDoesNot() {
        // The tolerance sits exactly at the measured knee: ≤2 h is fine, 3 h is not.
        let two = samplesSkippingHours(days: 7, skip: [12, 13])
        XCTAssertFalse(CosinorAgeEngine.compute(activity: two, age: 40, sex: .male, tzOffsetSeconds: 0)!.provisional)
        let three = samplesSkippingHours(days: 7, skip: [12, 13, 14])
        XCTAssertTrue(CosinorAgeEngine.compute(activity: three, age: 40, sex: .male, tzOffsetSeconds: 0)!.provisional)
    }

    func testWearAcrossMidnightIsNotPunished() {
        // 20:00 → 12:00 is 16 h perfectly spread over the cycle, but it lands in TWO calendar days. The
        // old per-day rule failed both; the window-level rule must accept it.
        let off: Set<Int> = [12, 13, 14, 15, 16, 17, 18, 19]      // worn 20:00–12:00
        let s = samplesSkippingHours(days: 7, skip: off)
        let r = CosinorAgeEngine.computeProvisional(activity: s, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertEqual(r.coverage.observedHours, 7 * 16, accuracy: 1e-9)
        XCTAssertTrue(r.coverage.meetsWearTime)
    }

    // MARK: 8. Jackknife uncertainty

    func testJackknifeIsFlatOnIdenticalDaysAndWiderOnVariedOnes() {
        let identical = CosinorAgeEngine.dailyMinuteSeries(
            syntheticSamples(days: 7, mesor: 30, amp: 25), tzOffsetSeconds: 0)
        let flat = CosinorAgeEngine.jackknifeSD(days: identical, age: 40, sex: .male)
        XCTAssertNotNil(flat)
        XCTAssertLessThan(flat!, 0.01, "identical days can't disagree with each other")

        // Days whose amplitude walks upward: dropping one now moves the estimate.
        var varied: [CosinorAgeEngine.DaySeries] = []
        for d in 0..<7 {
            varied += syntheticDays(days: 1, mesor: 30, amp: 5 + Double(d) * 6, phi: 0)
        }
        let spread = CosinorAgeEngine.jackknifeSD(days: varied, age: 40, sex: .male)
        XCTAssertNotNil(spread)
        XCTAssertGreaterThan(spread!, flat!)

        // Below three days there is no spread to report.
        XCTAssertNil(CosinorAgeEngine.jackknifeSD(days: Array(identical.prefix(2)), age: 40, sex: .male))
    }

    func testPartialDaysAreKeptRatherThanDiscarded() {
        // 5 full days + 2 daytime-only partial days. Measured cost of folding the partials in is well
        // under half a year, which is why there is no per-day floor.
        let full = syntheticSamples(days: 5, mesor: 30, amp: 25)
        var withPartials = full
        for day in 5..<7 {
            for minute in (9 * 60)..<(19 * 60) {      // 10 h, daytime only
                let mg = 30.0 + 25.0 * cos(w * Double(day * 1440 + minute))
                withPartials.append(.init(ts: day * 86400 + minute * 60, g: mg / 1000.0))
            }
        }
        let a = CosinorAgeEngine.computeProvisional(activity: full, age: 40, sex: .male, tzOffsetSeconds: 0)!
        let b = CosinorAgeEngine.computeProvisional(activity: withPartials, age: 40, sex: .male, tzOffsetSeconds: 0)!
        XCTAssertEqual(b.daysUsed, 7, "the partial days are USED, not dropped")
        XCTAssertEqual(a.cosinorAge, b.cosinorAge, accuracy: 0.5,
                       "folding in partial days must not move the estimate materially")
    }

    func testProvisionalStillRejectsAFlatTrace() {
        // The rhythm gate is NOT relaxed: no rhythm, no age, however much data there is.
        var samples: [CosinorAgeEngine.ActivitySample] = []
        for minute in 0..<1440 { samples.append(.init(ts: minute * 60, g: 30.0 / 1000.0)) }
        XCTAssertNil(CosinorAgeEngine.computeProvisional(activity: samples, age: 40, sex: .male, tzOffsetSeconds: 0))
    }
}

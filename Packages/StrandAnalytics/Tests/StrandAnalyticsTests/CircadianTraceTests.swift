import XCTest
@testable import StrandAnalytics

/// The Circadian & Body Clock trace line shapes.
///
/// These lines are what someone reads in an exported report to find out WHY a body-clock estimate is
/// missing or flagged unreadable — three outcomes the UI renders identically. So the properties that
/// matter are: every gate has a line, every line names its threshold beside the value it tests, and no
/// line carries anything but derived, hour-of-day-level data.
final class CircadianTraceTests: XCTestCase {

    private func bins(_ pairs: [(Double, Double)]) -> [CircadianEngine.ActivityBin] {
        pairs.map { CircadianEngine.ActivityBin(hour: $0.0, activity: $0.1) }
    }

    // MARK: - Input

    func testInputLineStatesCoverageAndTheThresholdItIsJudgedAgainst() {
        let line = CircadianTrace.inputLine(binCount: 18, daysObserved: 5, hoursCovered: 18,
                                            minDaysForFit: 7)
        XCTAssertTrue(line.hasPrefix("circadian input "))
        XCTAssertTrue(line.contains("bins=18"))
        XCTAssertTrue(line.contains("days=5"))
        XCTAssertTrue(line.contains("hoursCovered=18/24"))
        XCTAssertTrue(line.contains("minDays=7"), "the reader must see the threshold, not just the value")
    }

    func testBinsLineIsHourValuePairs() {
        let line = CircadianTrace.binsLine(bins([(0, 58.4), (13, 92.15)]))
        XCTAssertEqual(line, "circadian bins 0:58.4 13:92.2")
    }

    func testEmptyBinsLineDoesNotCrashOrFabricate() {
        XCTAssertEqual(CircadianTrace.binsLine([]), "circadian bins ")
    }

    // MARK: - Fit

    func testFitLineCarriesRelativeAmplitudeBesideItsThreshold() {
        let fit = CircadianEngine.CosinorFit(mesor: 60, amplitude: 12, acrophaseHours: 15.5)
        let line = CircadianTrace.fitLine(fit, minRelativeAmplitude: 0.10)
        XCTAssertTrue(line.contains("mesor=60.00"))
        XCTAssertTrue(line.contains("amp=12.00"))
        XCTAssertTrue(line.contains("acrophase=15.50h"))
        XCTAssertTrue(line.contains("relAmp=0.200"))
        XCTAssertTrue(line.contains("minRelAmp=0.100"))
    }

    /// A zero mesor would make the relative amplitude a division by zero; it must report 0, not "inf".
    func testZeroMesorReportsZeroRelativeAmplitude() {
        let fit = CircadianEngine.CosinorFit(mesor: 0, amplitude: 5, acrophaseHours: 3)
        let line = CircadianTrace.fitLine(fit, minRelativeAmplitude: 0.10)
        XCTAssertTrue(line.contains("relAmp=0.000"))
        XCTAssertFalse(line.lowercased().contains("inf"))
        XCTAssertFalse(line.lowercased().contains("nan"))
    }

    /// A negative mesor is still a magnitude question — the relative amplitude must not go negative and
    /// silently read as "flat".
    func testNegativeMesorUsesMagnitude() {
        let fit = CircadianEngine.CosinorFit(mesor: -50, amplitude: 10, acrophaseHours: 3)
        XCTAssertTrue(CircadianTrace.fitLine(fit, minRelativeAmplitude: 0.10).contains("relAmp=0.200"))
    }

    // MARK: - Phase

    func testPhaseLineCarriesTheEstimateAndItsConfidence() {
        let estimate = CircadianEngine.PhaseEstimate(
            tempMinHour: 4.5, acrophaseHours: 16.5, offsetVsScheduleMinutes: 45,
            confidence: .wide, note: "Your body clock looks later (a night-owl lean).")
        let line = CircadianTrace.phaseLine(estimate, habitualWakeHour: 7)
        XCTAssertTrue(line.contains("tempMin=4.50h"))
        XCTAssertTrue(line.contains("acrophase=16.50h"))
        XCTAssertTrue(line.contains("wake=7.00h"))
        XCTAssertTrue(line.contains("offset=45min"))
        XCTAssertTrue(line.contains("confidence=wide"))
    }

    // MARK: - Rejection and degradation

    func testRejectionNamesTheGate() {
        XCTAssertEqual(CircadianTrace.rejectedLine(reason: .tooFewBins, detail: "bins=3 need=6"),
                       "circadian rejected reason=tooFewBins bins=3 need=6")
    }

    func testRejectionWithoutDetailHasNoTrailingSpace() {
        XCTAssertEqual(CircadianTrace.rejectedLine(reason: .noFit), "circadian rejected reason=noFit")
    }

    /// The case the mode exists for: an `unreadable` estimate must say which of the two gates softened
    /// it, since the surface shows the same sentence for both.
    func testDegradedLineListsEveryReason() {
        XCTAssertEqual(CircadianTrace.degradedLine(reasons: [.tooFewDays, .flatRhythm]),
                       "circadian degraded confidence=unreadable reasons=tooFewDays,flatRhythm")
    }

    func testDegradedLineWithNoReasonSaysSoRatherThanBeingBlank() {
        XCTAssertEqual(CircadianTrace.degradedLine(reasons: []),
                       "circadian degraded confidence=unreadable reasons=none")
    }

    // MARK: - Voice

    func testNoLineContainsAnEmDash() {
        let fit = CircadianEngine.CosinorFit(mesor: 60, amplitude: 12, acrophaseHours: 15.5)
        let estimate = CircadianEngine.PhaseEstimate(tempMinHour: 4, acrophaseHours: 16,
                                                     offsetVsScheduleMinutes: 0, confidence: .solid,
                                                     note: "ok")
        let lines = [
            CircadianTrace.inputLine(binCount: 24, daysObserved: 14, hoursCovered: 24, minDaysForFit: 7),
            CircadianTrace.binsLine(bins([(0, 1)])),
            CircadianTrace.fitLine(fit, minRelativeAmplitude: 0.1),
            CircadianTrace.phaseLine(estimate, habitualWakeHour: 7),
            CircadianTrace.rejectedLine(reason: .tooFewBuckets),
            CircadianTrace.degradedLine(reasons: [.flatRhythm]),
        ]
        for line in lines { XCTAssertFalse(line.contains("\u{2014}"), "em-dash in: \(line)") }
    }
}

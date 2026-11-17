import XCTest
@testable import Strand

/// The readings table under a series-backed vital detail (task #8) — Swift twin of Android's
/// `VitalReadingsTableTest`. Pins the pure projection `vitalReadingRows` the MetricDetailView table
/// renders: rows and the "N readings" caption derive from the SAME windowed list (so their counts can't
/// disagree), rows are NEWEST-FIRST, each raw source id resolves through the shared
/// `TodayView.provenanceDisplayLabel` (strap → "WHOOP", Health Connect → "Health Connect", Apple Health →
/// "Apple Health", the "-noop" sibling → "On-device"), and each value reuses the model's own formatter +
/// unit. Blood Oxygen (SpO2) is the acceptance case.
final class VitalReadingsTableTests: XCTestCase {

    private let strap = Repository.whoopSource                  // "my-whoop"
    private let healthConnect = Repository.healthConnectSource  // "health-connect"
    private let appleHealth = Repository.appleHealthSource      // "apple-health"

    /// A fixed "now" long after the sample January-2026 readings, so none resolve as Today/Yesterday.
    private let now = ISO8601DateFormatter().date(from: "2026-07-09T00:00:00Z")!

    /// Blood Oxygen: %-formatted, ascending readings from three different sources — a strap reading, a
    /// Health Connect import (e.g. a Galaxy Watch), and an Apple Health import.
    private func spo2Readings() -> [VitalReading] {
        [
            VitalReading(day: "2026-01-01", value: 96, source: strap),
            VitalReading(day: "2026-01-02", value: 95, source: healthConnect),
            VitalReading(day: "2026-01-03", value: 97, source: appleHealth),
        ]
    }
    private func spo2Format(_ v: Double) -> String { String(format: "%.0f", v) }

    func testRowCountEqualsReadingsCount() {
        let rows = vitalReadingRows(readings: spo2Readings(), unit: "%", strapDeviceId: strap,
                                    now: now, format: spo2Format)
        XCTAssertEqual(rows.count, spo2Readings().count)
    }

    func testRowsAreNewestFirst() {
        let rows = vitalReadingRows(readings: spo2Readings(), unit: "%", strapDeviceId: strap,
                                    now: now, format: spo2Format)
        // Ascending input (01 → 03) must render descending (03 → 01).
        XCTAssertEqual(rows.map(\.time), ["Sat 3 Jan", "Fri 2 Jan", "Thu 1 Jan"])
        XCTAssertEqual(rows.first?.value, "97 %")   // the newest reading leads
    }

    func testReadingDatesShowWeekdaysIncludingTodayAndYesterday() {
        let today = ISO8601DateFormatter().date(from: "2026-09-30T00:00:00Z")!
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(vitalReadingDateLabel("2026-09-30", now: today, locale: english), "Today · Wed")
        XCTAssertEqual(vitalReadingDateLabel("2026-09-29", now: today, locale: english), "Yesterday · Tue")
        XCTAssertEqual(vitalReadingDateLabel("2026-09-26", now: today, locale: english), "Sat 26 Sep")
        XCTAssertEqual(vitalReadingDateLabel("bad-day", now: today, locale: english), "bad-day")
    }

    func testSourceLabelsResolvePerSample() {
        let rows = vitalReadingRows(readings: spo2Readings(), unit: "%", strapDeviceId: strap,
                                    now: now, format: spo2Format)
        // Newest-first, so: Apple Health (03), Health Connect (02), Whoop strap (01).
        XCTAssertEqual(rows.map(\.source), ["Apple Health", "Health Connect", "WHOOP"])
    }

    func testComputedStrapSiblingReadsOnDevice() {
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-01-04", value: 55, source: strap + "-noop")],
            unit: "yrs", strapDeviceId: strap, now: now, format: { String(format: "%.0f", $0) }
        )
        XCTAssertEqual(rows.first?.source, "On-device")
    }

    /// #103/queue-11a follow-up: a spo2 candidate-fallback row (see `spo2CandidateAttributionSource`)
    /// must resolve to "strap estimate (unverified)" — the SAME caption every other candidate-fallback
    /// surface uses — never a device name, which would misrepresent an unvalidated estimate as a
    /// calibrated reading.
    func testSpo2CandidateSourceReadsStrapEstimateUnverified() {
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-08-24", value: 97, source: spo2CandidateAttributionSource)],
            unit: "%", strapDeviceId: strap, now: now, format: spo2Format
        )
        XCTAssertEqual(rows.first?.source, "strap estimate (unverified)")
    }

    func testValueReusesModelFormatAndUnit() {
        // The row value is the model's own formatter applied to the reading, with the unit appended —
        // 41.7 ms formats (%.0f) to "42 ms".
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-01-01", value: 41.7, source: strap)],
            unit: "ms", strapDeviceId: strap, now: now, format: { String(format: "%.0f", $0) }
        )
        XCTAssertEqual(rows.first?.value, "42 ms")
    }

    func testUnitlessMetricLeavesNoTrailingSpace() {
        // Vitality has an empty unit; the value must not carry a dangling space.
        let rows = vitalReadingRows(
            readings: [VitalReading(day: "2026-01-01", value: 72, source: strap + "-noop")],
            unit: "", strapDeviceId: strap, now: now, format: { String(format: "%.0f", $0) }
        )
        XCTAssertEqual(rows.first?.value, "72")
    }

    // MARK: - #1942: the Explorer pairs a unit-BEARING formatter with an EMPTY unit

    /// Every test above passes `spo2Format`, a unit-LESS closure, which is the contract this function was
    /// written to and the one all of Android's call sites follow. The Explorer cannot follow it: its
    /// formatter is `MetricDescriptor.format`, which already ends in the unit, and the CONVERTED one —
    /// there is no unit-less iOS formatter that also converts kg→lb / °C→°F / 0–100→0–21. So it pairs that
    /// formatter with an empty unit, and this pins both halves of that pairing.
    ///
    /// Passing the descriptor's stored `unit` alongside it is what rendered "33 % %" in the readings table
    /// while the hero and the stat tiles, which render the formatter directly, stayed correct (#1942).
    func testExplorerFormatterAlreadyCarriesTheUnitSoTheUnitParameterIsEmpty() throws {
        let spo2 = try XCTUnwrap(MetricCatalog.metric(key: "spo2", source: strap))
        let explorerFormat: (Double) -> String = { spo2.format($0, system: .metric, temperature: .celsius) }

        // Half one: the Explorer's own formatter is unit-BEARING, unlike `spo2Format` above.
        XCTAssertEqual(explorerFormat(97), "97 %")

        // Half two: paired with an empty unit, the row carries exactly one.
        let rows = vitalReadingRows(readings: spo2Readings(), unit: "", strapDeviceId: strap,
                                    now: now, format: explorerFormat)
        XCTAssertEqual(rows.first?.value, "97 %")
    }

    /// The function itself is not at fault, and this says so: given the pairing the Explorer used to pass,
    /// doubling is the CORRECT output. That is why the fix is at the call site and why Android, whose
    /// twin appends identically, was never affected. Kept as the counter-case to the test above so a
    /// future reader restoring `unit: metric.unit` sees what it does.
    func testAUnitBearingFormatterPlusAUnitDoublesItWhichIsWhyTheCallSitePassesEmpty() throws {
        let spo2 = try XCTUnwrap(MetricCatalog.metric(key: "spo2", source: strap))
        let rows = vitalReadingRows(readings: spo2Readings(), unit: spo2.unit, strapDeviceId: strap,
                                    now: now,
                                    format: { spo2.format($0, system: .metric, temperature: .celsius) })
        XCTAssertEqual(rows.first?.value, "97 % %")
    }
}

/// A night read in minutes.
///
/// "526 min" is a true figure nobody reads as eight and three quarter hours, and it was reported from the
/// Readings table under the sleep metrics (Discord, 2026-11-17). Everywhere else in the app a duration is
/// already "8h 46m"; this is the one table that still printed the raw minutes.
///
/// Whether a metric IS a duration is the descriptor's answer, not the formatted string's: the Explorer
/// hands this function a unit-bearing formatter and an empty unit (#1942), so sniffing "… min" off the
/// output would be reading the label to find out what the number means.
extension VitalReadingsTableTests {

    private func minutes(_ values: [Double]) -> [VitalReading] {
        values.enumerated().map { index, value in
            VitalReading(day: String(format: "2026-01-%02d", index + 1), value: value,
                         source: Repository.whoopSource)
        }
    }

    private func rows(_ value: Double, unit: String, duration: Bool,
                      format: @escaping (Double) -> String = { String(format: "%.0f", $0) }) -> [VitalReadingRow] {
        vitalReadingRows(readings: minutes([value]), unit: unit, strapDeviceId: Repository.whoopSource,
                         now: now, durationMinutes: duration, format: format)
    }

    func testAMinuteReadingPastAnHourReadsAsHoursAndMinutes() {
        XCTAssertEqual(rows(526, unit: "min", duration: true).first?.value, "8h 46m")
    }

    /// The shape the screen actually uses: the formatter already says "526 min" and the unit is empty.
    func testTheExplorersOwnShapeIsConvertedToo() {
        let value = rows(526, unit: "", duration: true, format: { String(format: "%.0f min", $0) })
        XCTAssertEqual(value.first?.value, "8h 46m")
    }

    func testUnderAnHourItStaysAsTheFormatterWroteIt() {
        let value = rows(47, unit: "", duration: true, format: { String(format: "%.0f min", $0) })
        XCTAssertEqual(value.first?.value, "47 min")
    }

    func testAnExactHourSaysBothParts() {
        XCTAssertEqual(rows(60, unit: "min", duration: true).first?.value, "1h 0m")
    }

    /// Only a metric the descriptor calls a duration is rearranged. A percentage of 96 is not 1h 36m.
    func testOtherMetricsAreUntouched() {
        XCTAssertEqual(rows(96, unit: "%", duration: false).first?.value, "96 %")
        XCTAssertEqual(rows(96, unit: "min", duration: false).first?.value, "96 min")
    }
}

/// The screen-wide rule behind the table: ONE decision, so the headline, the chart's readout, the stat
/// tiles and the table cannot spell the same night two ways (reported 2026-11-17).
final class MetricDurationSpellingTests: XCTestCase {

    func testAMinuteMetricPastAnHourIsSpelledOut() {
        XCTAssertEqual(metricDurationSpelling(unit: "min", value: 443), "7h 23m")
        XCTAssertEqual(metricDurationSpelling(unit: "min", value: 526), "8h 46m")
    }

    func testTheHourItselfCounts() {
        XCTAssertEqual(metricDurationSpelling(unit: "min", value: 60), "1h 0m")
    }

    /// Under the hour the metric's own formatter keeps the value, so the rule answers nothing.
    func testUnderAnHourItDeclines() {
        XCTAssertNil(metricDurationSpelling(unit: "min", value: 59))
        XCTAssertNil(metricDurationSpelling(unit: "min", value: 0))
    }

    /// Everything that is not counted in minutes is left alone — 96 % is not an hour and a half.
    func testOnlyMinutesAreTreatedAsALength() {
        XCTAssertNil(metricDurationSpelling(unit: "%", value: 96))
        XCTAssertNil(metricDurationSpelling(unit: "bpm", value: 142))
        XCTAssertNil(metricDurationSpelling(unit: "", value: 443))
    }
}

import XCTest
import WhoopStore
@testable import Strand

/// `WeightSeries` — the union of NOOP's own weigh-ins over Apple Health.
///
/// This is the rule that decides what the Today tile, the goal card and the Coach all read, so the
/// cases that matter are the disagreements: the same day measured twice, and a NOOP weigh-in that
/// must not be shown twice because Apple also has that day.
final class WeightSeriesMergeTests: XCTestCase {

    // MARK: - Daily series

    func testAppleOnlyPassesThrough() {
        let merged = WeightSeries.merge(manual: [], appleHealth: [("2026-08-01", 82.0)])
        XCTAssertEqual(merged.map(\.value), [82.0])
        XCTAssertEqual(merged.map(\.source), [.appleHealth])
    }

    func testManualOnlyPassesThrough() {
        let merged = WeightSeries.merge(manual: [("2026-08-01", 82.0)], appleHealth: [])
        XCTAssertEqual(merged.map(\.value), [82.0])
        XCTAssertEqual(merged.map(\.source), [.manual])
    }

    /// The load-bearing rule: on a day both sources cover, the weigh-in the person typed wins. A
    /// correction entered in NOOP is the newer intent, and summing the two would invent a body.
    func testManualWinsADayBothCover() {
        let merged = WeightSeries.merge(manual: [("2026-08-01", 80.0)],
                                        appleHealth: [("2026-08-01", 90.0)])
        XCTAssertEqual(merged.count, 1, "one day must yield one value, never a sum")
        XCTAssertEqual(merged[0].value, 80.0)
        XCTAssertEqual(merged[0].source, .manual)
    }

    func testAppleFillsTheDaysManualDoesNotCover() {
        let merged = WeightSeries.merge(manual: [("2026-08-02", 80.0)],
                                        appleHealth: [("2026-08-01", 90.0), ("2026-08-03", 91.0)])
        XCTAssertEqual(merged.map(\.day), ["2026-08-01", "2026-08-02", "2026-08-03"])
        XCTAssertEqual(merged.map(\.source), [.appleHealth, .manual, .appleHealth])
    }

    func testResultIsOldestFirstRegardlessOfInputOrder() {
        let merged = WeightSeries.merge(manual: [("2026-08-03", 80.0), ("2026-08-01", 81.0)],
                                        appleHealth: [("2026-08-02", 90.0)])
        XCTAssertEqual(merged.map(\.day), ["2026-08-01", "2026-08-02", "2026-08-03"])
    }

    func testEmptyInputsYieldNothing() {
        XCTAssertTrue(WeightSeries.merge(manual: [], appleHealth: []).isEmpty)
    }

    // MARK: - History list

    /// Several weigh-ins on one day are all listed — the daily series keeps only the latest, but the
    /// history is where a person checks what they actually recorded.
    func testEveryManualEntryIsItsOwnRow() {
        let entries = WeightSeries.mergeEntries(
            manual: [row(id: "morning", day: "2026-08-01", takenAt: 1_000, kg: 82.0),
                     row(id: "evening", day: "2026-08-01", takenAt: 2_000, kg: 83.0)],
            appleHealth: [])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.id), ["evening", "morning"], "newest first")
    }

    /// Apple contributes nothing for a day NOOP already has a weigh-in on — otherwise the same
    /// morning shows twice, once uneditable, and the user cannot tell which one they typed.
    func testAppleIsSuppressedOnADayThatHasAManualEntry() {
        let entries = WeightSeries.mergeEntries(
            manual: [row(id: "a", day: "2026-08-01", takenAt: 1_000, kg: 82.0)],
            appleHealth: [("2026-08-01", 90.0), ("2026-08-02", 91.0)])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.source), [.appleHealth, .manual])
        XCTAssertEqual(entries.map(\.day), ["2026-08-02", "2026-08-01"])
    }

    func testOnlyManualEntriesAreEditable() {
        let entries = WeightSeries.mergeEntries(
            manual: [row(id: "a", day: "2026-08-02", takenAt: 1_000, kg: 82.0)],
            appleHealth: [("2026-08-01", 90.0)])
        let byDay = Dictionary(uniqueKeysWithValues: entries.map { ($0.day, $0) })
        XCTAssertEqual(byDay["2026-08-02"]?.isEditable, true)
        XCTAssertEqual(byDay["2026-08-01"]?.isEditable, false,
                       "an Apple day lives in Health — offering to delete it here would delete nothing")
    }

    /// A NOOP weigh-in carries its instant; an Apple day does not, and the list must not invent one.
    func testAppleRowsCarryNoInstant() {
        let entries = WeightSeries.mergeEntries(manual: [], appleHealth: [("2026-08-01", 90.0)])
        XCTAssertNil(entries.first?.takenAt)
    }

    func testManualRowsCarryTheirInstantAndNote() {
        let entries = WeightSeries.mergeEntries(
            manual: [row(id: "a", day: "2026-08-01", takenAt: 1_234, kg: 82.0, note: "after run")],
            appleHealth: [])
        XCTAssertEqual(entries.first?.takenAt, Date(timeIntervalSince1970: 1_234))
        XCTAssertEqual(entries.first?.note, "after run")
    }

    // MARK: - Day parsing

    /// Noon anchoring, so a timezone shift can never move a weigh-in onto the neighbouring day.
    func testDayParsesToNoon() {
        let date = try? XCTUnwrap(WeightSeries.date(forDay: "2026-08-01"))
        XCTAssertNotNil(date)
        let hour = Calendar.autoupdatingCurrent.component(.hour, from: date ?? Date())
        XCTAssertEqual(hour, 12)
    }

    func testMalformedDayIsRejected() {
        XCTAssertNil(WeightSeries.date(forDay: "not-a-day"))
        XCTAssertNil(WeightSeries.date(forDay: "2026-08"))
    }

    // MARK: - Helper

    private func row(id: String, day: String, takenAt: Int, kg: Double,
                     note: String? = nil) -> BodyWeightRow {
        BodyWeightRow(id: id, deviceId: "test", day: day, takenAt: takenAt, weightKg: kg,
                      source: BodyWeightRow.Source.manual.rawValue, note: note)
    }
}

import Foundation
import XCTest
@testable import WhoopProtocol

/// #823 follow-through. The store now returns a second's R-R beats in EMISSION order, but every
/// analytics entry point re-sorts by `ts` defensively before computing RMSSD. Swift's `sorted(by:)`
/// is explicitly documented as NOT stable, so that re-sort was free to re-scramble same-second beats
/// and undo the store fix. `sortedByTsStable` makes the comparator total instead of relying on the
/// current stdlib implementation happening to be timsort.
final class RRStableSortTests: XCTestCase {

    /// The property that matters: equal `ts` keeps input order, whatever the values are.
    func testSameSecondBeatsKeepEmissionOrder() {
        let emission = [812, 795, 840, 801, 833]
        let rr = emission.map { RRInterval(ts: 100, rrMs: $0) }
        XCTAssertEqual(rr.sortedByTsStable().map(\.rrMs), emission,
                       "a stable sort must not reorder beats that share a ts")
    }

    /// It must still actually sort — stability is worthless if the ordering is wrong.
    func testStillOrdersBySecond() {
        let rr = [RRInterval(ts: 300, rrMs: 700), RRInterval(ts: 100, rrMs: 800),
                  RRInterval(ts: 200, rrMs: 900)]
        XCTAssertEqual(rr.sortedByTsStable().map(\.ts), [100, 200, 300])
    }

    /// Interleaved seconds: each second's internal order is preserved while the seconds are ordered.
    func testInterleavedSecondsSortWithoutDisturbingWithinSecondOrder() {
        let rr = [RRInterval(ts: 200, rrMs: 810), RRInterval(ts: 100, rrMs: 795),
                  RRInterval(ts: 200, rrMs: 780), RRInterval(ts: 100, rrMs: 840),
                  RRInterval(ts: 200, rrMs: 830)]
        let out = rr.sortedByTsStable()
        XCTAssertEqual(out.map(\.ts), [100, 100, 200, 200, 200])
        XCTAssertEqual(out.map(\.rrMs), [795, 840, 810, 780, 830],
                       "within each second, the original relative order must survive")
    }

    /// The consequence, on the issue's own example: an unstable sort that happened to order a second
    /// by value would read 12.72 ms where the truth is 34.85 ms. Guarding the number, not just the order.
    func testStabilityPreservesRmssd() {
        func rmssd(_ v: [Int]) -> Double {
            let d = zip(v, v.dropFirst()).map { pow(Double($1 - $0), 2) }
            return (d.reduce(0, +) / Double(d.count)).squareRoot()
        }
        let emission = [812, 795, 840, 801, 833]
        let rr = emission.map { RRInterval(ts: 100, rrMs: $0) }
        XCTAssertEqual(rmssd(rr.sortedByTsStable().map(\.rrMs)), 34.85, accuracy: 0.01)
        XCTAssertEqual(rmssd(emission.sorted()), 12.72, accuracy: 0.01)
    }

    func testEmptyAndSingleAreHandled() {
        XCTAssertEqual([RRInterval]().sortedByTsStable().count, 0)
        XCTAssertEqual([RRInterval(ts: 1, rrMs: 800)].sortedByTsStable().map(\.rrMs), [800])
    }

    /// Duplicate (ts, rrMs) beats — the v24 case where two EQUAL intervals share a second — must all
    /// survive the sort. A comparator that treated them as interchangeable could drop or duplicate.
    func testEqualBeatsAllSurvive() {
        let rr = [RRInterval(ts: 100, rrMs: 600), RRInterval(ts: 100, rrMs: 600),
                  RRInterval(ts: 100, rrMs: 610)]
        XCTAssertEqual(rr.sortedByTsStable().map(\.rrMs), [600, 600, 610])
    }
}

import XCTest
@testable import OuraProtocol

/// Tests for deriving `hrSample`-shaped HR from banked IBI (#728). Kotlin twin: `OuraIbiHrTest`.
final class OuraIbiHrTests: XCTestCase {

    private func ibi(_ rt: UInt32, _ ms: Int) -> OuraIBI { OuraIBI(ringTimestamp: rt, ibiMs: ms) }

    func testPerRecordMedianHRGroupsByRingTime() {
        // rt=100: median(1000,1020,980)=1000 → 60 bpm. rt=200: median(900,910)=905 → 66 bpm.
        let hr = OuraIbiHr.perRecordMedianHR([
            ibi(100, 1000), ibi(100, 1020), ibi(100, 980), ibi(200, 900), ibi(200, 910),
        ])
        XCTAssertEqual(hr, [
            OuraHR(ringTimestamp: 100, bpm: 60, ibiMs: 1000),
            OuraHR(ringTimestamp: 200, bpm: 66, ibiMs: 905),
        ])
    }

    func testSixBeatsOfOneRecordCollapseToOneRow() {
        // A 0x60 record's 6 same-ring-time beats → ONE median HR (matches the hrSample (deviceId, ts) key).
        let hr = OuraIbiHr.perRecordMedianHR((0..<6).map { ibi(500, 1000 + $0) })
        XCTAssertEqual(hr.count, 1)
        XCTAssertEqual(hr.first?.ringTimestamp, 500)
    }

    func testOutOfRangeIBIsExcludedFromMedian() {
        // 100 ms and 3000 ms are non-physiological (outside 300..2000) → dropped; median{1000} → 60 bpm.
        XCTAssertEqual(OuraIbiHr.perRecordMedianHR([ibi(1, 100), ibi(1, 1000), ibi(1, 3000)]),
                       [OuraHR(ringTimestamp: 1, bpm: 60, ibiMs: 1000)])
    }

    func testRecordWithNoInRangeBeatYieldsNothing() {
        XCTAssertTrue(OuraIbiHr.perRecordMedianHR([ibi(1, 100), ibi(1, 5000)]).isEmpty)
    }

    func testEmptyInput() {
        XCTAssertTrue(OuraIbiHr.perRecordMedianHR([]).isEmpty)
    }

    func testReturnedOldestRingTimeFirst() {
        XCTAssertEqual(OuraIbiHr.perRecordMedianHR([ibi(300, 1000), ibi(100, 1000), ibi(200, 1000)])
                        .map { $0.ringTimestamp }, [100, 200, 300])
    }
}

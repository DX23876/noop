import XCTest
import StrandCore
import WhoopStore
@testable import Strand

/// The live Stress screen reads a night against the nights after a manual "Recalibrate baseline", the same
/// window as the stored series (`StressMath.proxyRows`, tested in the StrandCore package).
final class StressProxySeriesTests: XCTestCase {

    private func day(_ dayStr: String, restingHr: Int? = nil, avgHrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: dayStr, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: restingHr, avgHrv: avgHrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    // MARK: - Recalibration (AI-28)

    /// 20 nights at an old HRV level of 90 ms, a recalibration, then nights around 78 ms: the reported
    /// case, where a night of 82 ms was read as "HRV is down".
    private var recalibratedDays: [DailyMetric] {
        let old = (1...20).map { day(String(format: "2026-09-%02d", $0), restingHr: 50, avgHrv: 90 + Double($0 % 3)) }
        let new = (1...6).map { day(String(format: "2026-10-%02d", $0), restingHr: 50,
                                    avgHrv: [77, 79, 78, 76, 80, 78][$0 - 1]) }
        return old + new + [day("2026-10-07", restingHr: 50, avgHrv: 82)]
    }

    private let cut = StressMath.Cut(hrvFirstNight: "2026-10-01", rhrFirstNight: "2026-10-01")

    func testANightAfterARecalibrationIsReadAgainstTheNightsAfterIt() throws {
        let days = recalibratedDays
        let ref = StressMath.reference(before: days.count - 1, in: days, cut: cut)
        XCTAssertEqual(try XCTUnwrap(ref.meanHRV), 78, accuracy: 1e-9)
        let model = try XCTUnwrap(StressModel(days: days, stored: [], cut: cut))
        XCTAssertGreaterThan(try XCTUnwrap(model.hrvDelta), 0, "82 ms is above the recalibrated 78 ms")
        let uncut = try XCTUnwrap(StressModel(days: days, stored: [], cut: .none))
        XCTAssertLessThan(try XCTUnwrap(uncut.hrvDelta), 0, "the old window read it as down")
    }
}

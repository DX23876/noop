import XCTest
@testable import Strand
import WhoopStore

final class Vo2MaxTrendProvenanceTests: XCTestCase {
    func testMethodChangesCreateSequentialSegmentsEvenWhenMethodReturns() {
        let sources = [
            "2026-08-01": vo2MaxAttributionSource(.nes),
            "2026-08-08": vo2MaxAttributionSource(.nes),
            "2026-08-15": vo2MaxAttributionSource(.uth),
            "2026-08-22": vo2MaxAttributionSource(.nes),
        ]
        XCTAssertEqual(
            vo2MaxTrendSegmentIds(
                days: ["2026-08-01", "2026-08-08", "2026-08-15", "2026-08-22"],
                sourceByDay: sources),
            [
                "0:vo2max-estimator:nes",
                "0:vo2max-estimator:nes",
                "1:vo2max-estimator:uth",
                "2:vo2max-estimator:nes",
            ]
        )
    }

    func testLegacyPointIsExplicitlyUnknown() {
        XCTAssertEqual(vo2MaxAttributionSource(nil), "vo2max-estimator:unknown")
        XCTAssertEqual(vo2MaxEstimatorDisplayName(nil), String(localized: "Unknown"))
        XCTAssertEqual(
            TodayView.provenanceDisplayLabel(rawSource: vo2MaxAttributionSource(nil), deviceId: "my-whoop"),
            "\(String(localized: "On-device")) · \(String(localized: "Unknown"))"
        )
    }
}

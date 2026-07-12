import XCTest
@testable import StrandImport

final class OuraHypnogramTests: XCTestCase {
    private func d(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testStageLegendMapsOuraDigits() {
        XCTAssertEqual(OuraHypnogram.stageName("1"), "deep")
        XCTAssertEqual(OuraHypnogram.stageName("2"), "light")
        XCTAssertEqual(OuraHypnogram.stageName("3"), "rem")
        XCTAssertEqual(OuraHypnogram.stageName("4"), "wake")
        XCTAssertNil(OuraHypnogram.stageName("0"))
    }

    func testDecodeMergesAdjacentEqualStagesAndAligns() {
        let start = d("2026-01-01T23:00:00Z")
        // "1123" → deep(2 epochs merged), light(1), rem(1); 5-min epochs.
        let segs = OuraHypnogram.decode("1123", start: start, epochSeconds: 300)
        XCTAssertEqual(segs.map(\.stage), ["deep", "light", "rem"])
        XCTAssertEqual(segs[0].start, start)
        XCTAssertEqual(segs[0].end, start.addingTimeInterval(600))   // two 5-min epochs merged
        XCTAssertEqual(segs[2].end, start.addingTimeInterval(1200))  // total 4 epochs = 20 min
    }

    func testMovementLegendIsDistinctFromStages() {
        // movement uses 1=no motion … 4=active; unknown → 0.
        XCTAssertEqual(OuraHypnogram.movement("1234x"), [1, 2, 3, 4, 0])
    }
}

import XCTest
import WhoopStore
@testable import StrandAnalytics

final class SleepGroupEditTests: XCTestCase {
    private let hour = 3_600
    private let t0 = 1_780_000_000

    private func fragment(_ start: Int, _ end: Int) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil,
                           avgHrv: nil, stagesJSON: nil)
    }

    private var splitNight: [CachedSleepSession] {
        [fragment(t0, t0 + 2 * hour),
         fragment(t0 + 3 * hour, t0 + 5 * hour),
         fragment(t0 + 8 * hour, t0 + 10 * hour)]
    }

    private func window(_ plan: SleepGroupEdit.Plan) -> (Int, Int) {
        (plan.clipped.map(\.effectiveStartTs).min()!, plan.clipped.map(\.endTs).max()!)
    }

    func testDrawnWindowBecomesWholeNightWindow() {
        let plan = SleepGroupEdit.plan(splitNight, newStartTs: t0 + hour, newEndTs: t0 + 6 * hour)
        XCTAssertEqual(window(plan).0, t0 + hour)
        XCTAssertEqual(window(plan).1, t0 + 6 * hour)
        XCTAssertEqual(plan.dropped.map(\.startTs), [t0 + 8 * hour])
    }

    func testInteriorFragmentsNarrowButDoNotStretch() {
        let plan = SleepGroupEdit.plan(splitNight, newStartTs: t0 - hour, newEndTs: t0 + 11 * hour)
        XCTAssertEqual(plan.clipped[1].effectiveStartTs, t0 + 3 * hour)
        XCTAssertEqual(plan.clipped[1].endTs, t0 + 5 * hour)
        XCTAssertEqual(window(plan).0, t0 - hour)
        XCTAssertEqual(window(plan).1, t0 + 11 * hour)
        XCTAssertTrue(plan.dropped.isEmpty)
    }

    func testSingleFragmentMatchesExistingEditSemantics() {
        let original = fragment(t0, t0 + 8 * hour)
        let plan = SleepGroupEdit.plan([original], newStartTs: t0 + hour, newEndTs: t0 + 7 * hour)
        XCTAssertEqual(plan.clipped.count, 1)
        XCTAssertEqual(plan.clipped[0].startTs, original.startTs, "the immutable key must not move")
        XCTAssertEqual(plan.clipped[0].effectiveStartTs, t0 + hour)
        XCTAssertEqual(plan.clipped[0].endTs, t0 + 7 * hour)
        XCTAssertTrue(plan.clipped[0].userEdited)
    }

    func testDisjointAndInvertedWindowsChangeNothing() {
        let disjoint = SleepGroupEdit.plan(splitNight, newStartTs: t0 + 20 * hour,
                                           newEndTs: t0 + 22 * hour)
        XCTAssertTrue(disjoint.clipped.isEmpty)
        XCTAssertTrue(disjoint.dropped.isEmpty)
        let inverted = SleepGroupEdit.plan(splitNight, newStartTs: t0 + 6 * hour,
                                           newEndTs: t0 + hour)
        XCTAssertTrue(inverted.clipped.isEmpty)
        XCTAssertTrue(inverted.dropped.isEmpty)
    }

    func testGroupWindowSpansAllFragments() {
        let window = SleepGroupEdit.groupWindow(splitNight)
        XCTAssertEqual(window?.start, t0)
        XCTAssertEqual(window?.end, t0 + 10 * hour)
        XCTAssertNil(SleepGroupEdit.groupWindow([]))
    }
}

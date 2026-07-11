import XCTest
@testable import StrandImport

final class HealthWritebackTests: XCTestCase {

    private let start = 1_700_000_000
    private var end: Int { start + 8 * 3600 }

    private func intervals(_ json: String?) -> [HealthWriteback.StageInterval] {
        HealthWriteback.stageIntervals(stagesJSON: json, sessionStart: start, sessionEnd: end)
    }

    func testSegmentShapeParsesAndSorts() {
        let json = """
        [{"start": \(start + 3600), "end": \(start + 5400), "stage": "deep"},
         {"start": \(start), "end": \(start + 3600), "stage": "light"},
         {"start": \(start + 5400), "end": \(start + 7200), "stage": "rem"}]
        """
        let out = intervals(json)
        XCTAssertEqual(out, [
            .init(start: start, end: start + 3600, kind: .light),
            .init(start: start + 3600, end: start + 5400, kind: .deep),
            .init(start: start + 5400, end: start + 7200, kind: .rem),
        ])
    }

    func testWakeAndAwakeBothMapToAwake() {
        let json = """
        [{"start": \(start), "end": \(start + 60), "stage": "wake"},
         {"start": \(start + 60), "end": \(start + 120), "stage": "awake"}]
        """
        XCTAssertEqual(intervals(json).map(\.kind), [.awake, .awake])
    }

    func testSegmentsClampedToSessionBounds() {
        let json = """
        [{"start": \(start - 600), "end": \(start + 600), "stage": "light"},
         {"start": \(end - 600), "end": \(end + 600), "stage": "rem"}]
        """
        let out = intervals(json)
        XCTAssertEqual(out.first, .init(start: start, end: start + 600, kind: .light))
        XCTAssertEqual(out.last, .init(start: end - 600, end: end, kind: .rem))
    }

    func testZeroAndNegativeLengthSegmentsDropped() {
        let json = """
        [{"start": \(start), "end": \(start), "stage": "deep"},
         {"start": \(start + 100), "end": \(start + 50), "stage": "rem"},
         {"start": \(end + 100), "end": \(end + 200), "stage": "light"}]
        """
        XCTAssertEqual(intervals(json), [])
    }

    func testUnknownStageLabelDropped() {
        let json = """
        [{"start": \(start), "end": \(start + 60), "stage": "hyperdrive"},
         {"start": \(start + 60), "end": \(start + 120), "stage": "deep"}]
        """
        XCTAssertEqual(intervals(json).map(\.kind), [.deep])
    }

    func testAggregateMinuteShapesReturnEmpty() {
        // Dict shape (Android/demo seeds) and per-stage-minutes array carry no timing.
        XCTAssertEqual(intervals(#"{"deep": 90, "rem": 60, "light": 210}"#), [])
        XCTAssertEqual(intervals(#"[{"stage": "deep", "min": 90}, {"stage": "rem", "min": 60}]"#), [])
    }

    func testMixedSegmentAndAggregateBailsEntirely() {
        // One segment missing start/end means the shape is untrustworthy — no partial mix.
        let json = """
        [{"start": \(start), "end": \(start + 3600), "stage": "light"},
         {"stage": "deep", "min": 90}]
        """
        XCTAssertEqual(intervals(json), [])
    }

    func testNilGarbageAndInvertedSessionReturnEmpty() {
        XCTAssertEqual(intervals(nil), [])
        XCTAssertEqual(intervals("not json"), [])
        XCTAssertEqual(HealthWriteback.stageIntervals(stagesJSON: "[]",
                                                      sessionStart: end, sessionEnd: start), [])
    }

    func testDoubleTimestampsAccepted() {
        let json = """
        [{"start": \(start).0, "end": \(start + 60).5, "stage": "deep"}]
        """
        XCTAssertEqual(intervals(json), [.init(start: start, end: start + 60, kind: .deep)])
    }
}

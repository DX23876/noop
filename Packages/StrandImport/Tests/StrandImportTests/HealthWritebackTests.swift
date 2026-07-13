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

    // MARK: - mergedSleepPlan (#364 night-stitch)
    //
    // One write-back entry per BRIDGED night: the caller (HealthKitBridge) groups fragments with
    // SleepStageTotals.bridgedNightGroups; this pure layer folds each group into one span + one
    // merged stage timeline with every inter-fragment seam as an explicit `wake`, keyed by the
    // earliest fragment's immutable startTs, carrying the COMPLETE per-fragment key set so a night
    // previously exported as two entries deletes both before the merged write.

    private func frag(_ start: Int, _ end: Int, stages: String? = nil,
                      eff: Int? = nil) -> HealthWriteback.SleepFragment {
        .init(startTs: start, effectiveStartTs: eff ?? start, endTs: end, stagesJSON: stages)
    }
    private func stagesJSON(_ segs: [(Int, Int, String)]) -> String {
        "[" + segs.map { "{\"start\":\($0.0),\"end\":\($0.1),\"stage\":\"\($0.2)\"}" }
            .joined(separator: ",") + "]"
    }

    func testMergedPlanFoldsTwoFragmentsWithWakeSeam() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200, stages: stagesJSON([(t, t + 7_200, "light")]))
        let b = frag(t + 7_200 + 960, t + 14_400,
                     stages: stagesJSON([(t + 7_200 + 960, t + 14_400, "deep")]))
        let plan = HealthWriteback.mergedSleepPlan(groups: [[a, b]])
        XCTAssertEqual(plan.count, 1)
        let e = plan[0]
        XCTAssertEqual(e.keyStartTs, t)
        XCTAssertEqual(e.spanStart, t)
        XCTAssertEqual(e.spanEnd, t + 14_400)
        XCTAssertEqual(e.allKeyStartTs, [t, t + 7_200 + 960])
        // The seam sits EXACTLY on [prev.end, next.effectiveStart] as .awake.
        XCTAssertEqual(e.intervals, [
            .init(start: t, end: t + 7_200, kind: .light),
            .init(start: t + 7_200, end: t + 7_200 + 960, kind: .awake),
            .init(start: t + 7_200 + 960, end: t + 14_400, kind: .deep),
        ])
    }

    func testMergedPlanSingleFragmentMatchesLegacyShape() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200,
                     stages: stagesJSON([(t, t + 3_600, "light"), (t + 3_600, t + 7_200, "rem")]))
        let e = HealthWriteback.mergedSleepPlan(groups: [[a]])[0]
        XCTAssertEqual(e.keyStartTs, t)
        XCTAssertEqual(e.spanStart, t)
        XCTAssertEqual(e.spanEnd, t + 7_200)
        XCTAssertEqual(e.allKeyStartTs, [t])
        XCTAssertEqual(e.intervals, HealthWriteback.stageIntervals(
            stagesJSON: a.stagesJSON, sessionStart: t, sessionEnd: t + 7_200))
    }

    func testMergedPlanUnstagedFragmentsDegradeToUnspecifiedPlusSeam() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200)                       // no stagesJSON → honest unspecified block
        let b = frag(t + 7_200 + 960, t + 14_400)
        let e = HealthWriteback.mergedSleepPlan(groups: [[a, b]])[0]
        XCTAssertEqual(e.intervals, [
            .init(start: t, end: t + 7_200, kind: .unspecified),
            .init(start: t + 7_200, end: t + 7_200 + 960, kind: .awake),
            .init(start: t + 7_200 + 960, end: t + 14_400, kind: .unspecified),
        ])
    }

    func testMergedPlanMixedStagedAndUnstagedFragments() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200, stages: stagesJSON([(t, t + 7_200, "light")]))
        let b = frag(t + 7_200 + 960, t + 14_400)        // second fragment carries no timing
        let e = HealthWriteback.mergedSleepPlan(groups: [[a, b]])[0]
        XCTAssertEqual(e.intervals, [
            .init(start: t, end: t + 7_200, kind: .light),
            .init(start: t + 7_200, end: t + 7_200 + 960, kind: .awake),
            .init(start: t + 7_200 + 960, end: t + 14_400, kind: .unspecified),
        ])
    }

    func testMergedPlanEditedOnsetMovesSpanButNotKey() {
        let t = 1_767_312_000
        let a = frag(t, t + 7_200, eff: t + 600)         // user moved bedtime 10 min later
        let e = HealthWriteback.mergedSleepPlan(groups: [[a]])[0]
        XCTAssertEqual(e.keyStartTs, t)                  // immutable key
        XCTAssertEqual(e.spanStart, t + 600)             // edited onset drives the span
        XCTAssertEqual(e.intervals, [.init(start: t + 600, end: t + 7_200, kind: .unspecified)])
    }

    func testMergedPlanSkipsDegenerateFragmentsAndEmptyGroups() {
        let t = 1_767_312_000
        let bad = frag(t, t)                             // zero-length → contributes no interval
        let good = frag(t + 600, t + 7_200)
        let plan = HealthWriteback.mergedSleepPlan(groups: [[], [bad, good]])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].spanStart, t + 600)
        // The degenerate fragment still contributes its key to the delete set (its old export, if
        // any, must clear), but produces no interval.
        XCTAssertEqual(plan[0].allKeyStartTs, [t, t + 600])
        XCTAssertEqual(plan[0].intervals, [.init(start: t + 600, end: t + 7_200, kind: .unspecified)])
    }
}

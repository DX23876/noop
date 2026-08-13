import XCTest
@testable import StrandImport

final class HealthWritebackTests: XCTestCase {

    private let start = 1_700_000_000
    private var end: Int { start + 8 * 3600 }

    func testHeartRateIntervalAndPointShapesKeepTheSameValue() {
        let bucket = HealthWriteback.HeartRateBucket(startTs: start, bpm: 72.5)
        let interval = HealthWriteback.heartRateSamples(
            buckets: [bucket], encoding: .interval60Seconds, nowTs: start + 100)[0]
        let point = HealthWriteback.heartRateSamples(
            buckets: [bucket], encoding: .pointAtBucketMidpoint, nowTs: start + 100)[0]

        XCTAssertEqual(interval.startTs, start)
        XCTAssertEqual(interval.endTs, start + 60)
        XCTAssertEqual(point.startTs, start + 30)
        XCTAssertEqual(point.endTs, start + 30)
        XCTAssertEqual(interval.bpm, point.bpm)
        XCTAssertEqual(interval.bucketTs, point.bucketTs)
    }

    func testHeartRatePlannerClampsFutureEdgeAndRejectsInvalidValues() {
        let buckets = [
            HealthWriteback.HeartRateBucket(startTs: start, bpm: 70),
            .init(startTs: start + 60, bpm: .nan),
            .init(startTs: start + 120, bpm: 0),
            .init(startTs: start + 180, bpm: 75),
        ]
        let interval = HealthWriteback.heartRateSamples(
            buckets: buckets, encoding: .interval60Seconds, nowTs: start + 20)
        let point = HealthWriteback.heartRateSamples(
            buckets: buckets, encoding: .pointAtBucketMidpoint, nowTs: start + 20)
        XCTAssertEqual(interval, [.init(bucketTs: start, startTs: start, endTs: start + 20, bpm: 70)])
        XCTAssertEqual(point, [.init(bucketTs: start, startTs: start + 20, endTs: start + 20, bpm: 70)])
    }

    func testHeartRateExperimentChoosesTwoDenseNonOverlappingWindows() {
        let buckets = (0..<240).map {
            HealthWriteback.HeartRateBucket(startTs: start + $0 * 60, bpm: 60 + Double($0 % 20))
        }
        XCTAssertEqual(HealthWriteback.heartRateExperimentWindows(buckets: buckets), [
            .init(startTs: start, endTs: start + 120 * 60),
            .init(startTs: start + 120 * 60, endTs: start + 240 * 60),
        ])
    }

    func testHeartRateExperimentRefusesSparseInput() {
        let buckets = stride(from: 0, to: 240, by: 3).map {
            HealthWriteback.HeartRateBucket(startTs: start + $0 * 60, bpm: 70)
        }
        XCTAssertEqual(HealthWriteback.heartRateExperimentWindows(buckets: buckets), [])
    }

    func testHeartRateMigrationChunksBackwardAndStopsAtFloor() {
        let twoDays = 2 * 86_400
        let first = HealthWriteback.heartRateMigrationChunk(
            endTs: start + 30 * 86_400, floorTs: start, chunkDays: 14)
        XCTAssertEqual(first, .init(
            window: .init(startTs: start + 16 * 86_400, endTs: start + 30 * 86_400),
            completesMigration: false))

        let final = HealthWriteback.heartRateMigrationChunk(
            endTs: start + twoDays, floorTs: start, chunkDays: 14)
        XCTAssertEqual(final, .init(
            window: .init(startTs: start, endTs: start + twoDays),
            completesMigration: true))
        XCTAssertNil(HealthWriteback.heartRateMigrationChunk(endTs: start, floorTs: start))
    }

    // MARK: - HRV/SDNN repair (#hrv-sdnn-truncation)

    /// The repair is a SECOND writer of the nightly-vitals samples. If it spelled the external key
    /// differently from the regular write-back, that pass would no longer delete the repair's samples
    /// before re-saving its own and every overlapping day would double up in Apple Health. Pin the
    /// literal shape so a rename cannot silently break the dedup contract.
    func testVitalsExternalKeyShapeIsStable() {
        XCTAssertEqual(
            HealthWriteback.vitalsExternalKey(noopDeviceId: "AA:BB",
                                              identifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                                              day: "2026-08-13"),
            "noop:AA:BB:HKQuantityTypeIdentifierHeartRateVariabilitySDNN:2026-08-13")
    }

    /// Both migrations must share ONE boundary implementation, or their resume behavior drifts apart.
    func testNeutralChunkEntryPointMatchesTheHeartRateOne() {
        for days in [1, 14, 90] {
            XCTAssertEqual(
                HealthWriteback.backwardMigrationChunk(endTs: start + 400 * 86_400,
                                                       floorTs: start, chunkDays: days),
                HealthWriteback.heartRateMigrationChunk(endTs: start + 400 * 86_400,
                                                        floorTs: start, chunkDays: days))
        }
    }

    /// The property that makes the repair safe: walking backwards in 90-day chunks tiles the whole span
    /// contiguously — no gap (a gap would be history left deleted-but-not-rewritten) and no overlap —
    /// terminates, and reports `completesMigration` on the last chunk only.
    func testBackwardWalkTilesTheWholeSpanWithoutGapOrOverlap() {
        let floor = start
        let top = start + 400 * 86_400
        var cursor = top
        var windows: [HealthWriteback.TimeWindow] = []
        var completions = 0
        while let chunk = HealthWriteback.backwardMigrationChunk(endTs: cursor, floorTs: floor,
                                                                chunkDays: 90) {
            windows.append(chunk.window)
            if chunk.completesMigration { completions += 1; break }
            cursor = chunk.window.startTs
        }

        XCTAssertEqual(completions, 1)
        XCTAssertEqual(windows.first?.endTs, top)
        XCTAssertEqual(windows.last?.startTs, floor)
        // Newest-first and edge-to-edge: each window starts exactly where the previous one began.
        for (newer, older) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(older.endTs, newer.startTs)
            XCTAssertLessThan(older.startTs, older.endTs)
        }
    }

    /// A cancelled run persists `window.startTs` as the cursor and a later tap continues from there.
    /// The resumed walk must cover exactly the same span as an uninterrupted one — that is what makes
    /// "stop is safe" true rather than merely hoped for.
    func testInterruptedWalkResumesOverTheIdenticalSpan() {
        let floor = start
        let top = start + 400 * 86_400
        func walk(stoppingAfter stopAfter: Int) -> (windows: [HealthWriteback.TimeWindow], cursor: Int) {
            var cursor = top
            var windows: [HealthWriteback.TimeWindow] = []
            while let chunk = HealthWriteback.backwardMigrationChunk(endTs: cursor, floorTs: floor,
                                                                    chunkDays: 90) {
                windows.append(chunk.window)
                if chunk.completesMigration { break }
                cursor = chunk.window.startTs
                if windows.count == stopAfter { break }
            }
            return (windows, cursor)
        }

        let full = walk(stoppingAfter: .max).windows
        let interrupted = walk(stoppingAfter: 2)
        var resumed = interrupted.windows
        var cursor = interrupted.cursor
        while let chunk = HealthWriteback.backwardMigrationChunk(endTs: cursor, floorTs: floor,
                                                                chunkDays: 90) {
            resumed.append(chunk.window)
            if chunk.completesMigration { break }
            cursor = chunk.window.startTs
        }
        XCTAssertEqual(resumed, full)
    }

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

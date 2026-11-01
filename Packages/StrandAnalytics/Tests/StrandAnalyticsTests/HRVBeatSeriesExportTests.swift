import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Beat-to-beat export: another app computes its own successive-difference HRV from these intervals, so a
/// five-minute segment is exported only when NOOP would trust the same statistic from the same beats.
final class HRVBeatSeriesExportTests: XCTestCase {

    /// One beat per second, each stamped where the previous interval says it lands.
    private func clean(from start: Int, seconds: Int) -> [RRInterval] {
        (0..<seconds).map { RRInterval(ts: start + $0, rrMs: 1_000) }
    }

    func testACleanBeatTrainIsExportableInFiveMinuteSegments() {
        let segments = HRVAnalyzer.exportableBeatSegments(clean(from: 1_000, seconds: 600))
        XCTAssertEqual(segments.map(\.count), [300, 300])
        XCTAssertEqual(segments.first?.first?.ts, 1_000)
    }

    /// Two beats a second for a heart beating once a second: the stream banks more beat-time than the
    /// clock spans, and its successive differences are not the heart's.
    func testAnOverCountedSegmentIsDropped() {
        var rr: [RRInterval] = []
        for i in 0..<300 {
            rr.append(.init(ts: 1_000 + i, rrMs: 900))
            rr.append(.init(ts: 1_000 + i, rrMs: 905))
        }
        XCTAssertEqual(HRVAnalyzer.exportableBeatSegments(rr), [])
    }

    /// A banked record: five intervals decomposed across one timestamp. The sum is right, the individual
    /// values are not beat-to-beat measurements.
    func testADecomposedRecordIsDropped() {
        var rr: [RRInterval] = []
        for record in 0..<60 {
            for _ in 0..<5 { rr.append(.init(ts: 1_000 + record * 5, rrMs: 1_000)) }
        }
        XCTAssertEqual(HRVAnalyzer.exportableBeatSegments(rr), [])
    }

    /// One refused segment does not take the clean rest of the night with it.
    func testARefusedSegmentDropsOutAlone() {
        var rr = clean(from: 1_000, seconds: 300)
        for i in 0..<300 {
            rr.append(.init(ts: 1_300 + i, rrMs: 900))
            rr.append(.init(ts: 1_300 + i, rrMs: 905))
        }
        rr += clean(from: 1_600, seconds: 300)
        let segments = HRVAnalyzer.exportableBeatSegments(rr.shuffled())
        XCTAssertEqual(segments.map { $0.first?.ts }, [1_000, 1_600])
        XCTAssertEqual(segments.map(\.count), [300, 300])
    }
}

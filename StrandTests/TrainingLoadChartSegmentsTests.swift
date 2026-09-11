import XCTest
import StrandAnalytics
@testable import Strand

/// Pins how the Training Load chart splits a lane's line into zone-coloured pieces: every threshold
/// crossing gets a point exactly on the threshold, shared by the piece it ends and the piece it starts.
final class TrainingLoadChartSegmentsTests: XCTestCase {
    private typealias Sample = LoadRatioChart.Sample

    private func day(_ index: Double, _ value: Double) -> Sample {
        Sample(date: Date(timeIntervalSince1970: index * 86_400), value: value)
    }

    private func values(_ segments: [LoadRatioChart.Segment]) -> [[Double]] {
        segments.map { $0.samples.map { ($0.value * 1000).rounded() / 1000 } }
    }

    func testEachCrossingEndsOnePieceAndStartsTheNext() {
        let segments = LoadRatioChart.zoneSegments([day(0, 0.7), day(1, 0.9), day(2, 1.2), day(3, 1.5), day(4, 1.1)])
        XCTAssertEqual(segments.map(\.band), [.below, .maintaining, .productive, .above, .productive])
        XCTAssertEqual(values(segments), [[0.7, 0.8], [0.8, 0.9, 1.0], [1.0, 1.2, 1.3], [1.3, 1.5, 1.3], [1.3, 1.1]])
    }

    func testCrossingIsPlacedInTimeWhereTheLineMeetsTheThreshold() {
        let segments = LoadRatioChart.zoneSegments([day(0, 0.7), day(1, 0.9)])
        let edge = segments[0].samples[1]
        XCTAssertEqual(edge.value, 0.8, accuracy: 1e-12)
        XCTAssertEqual(edge.date.timeIntervalSince1970, 0.5 * 86_400, accuracy: 1e-6)
        XCTAssertEqual(segments[1].samples.first, edge)
    }

    func testOneStepAcrossSeveralZonesPassesThroughEachThreshold() {
        let segments = LoadRatioChart.zoneSegments([day(0, 0.6), day(1, 1.5)])
        XCTAssertEqual(segments.map(\.band), [.below, .maintaining, .productive, .above])
        XCTAssertEqual(values(segments), [[0.6, 0.8], [0.8, 1.0], [1.0, 1.3], [1.3, 1.5]])

        let falling = LoadRatioChart.zoneSegments([day(0, 1.5), day(1, 0.6)])
        XCTAssertEqual(falling.map(\.band), [.above, .productive, .maintaining, .below])
    }

    func testStayingInOneZoneIsOnePiece() {
        let segments = LoadRatioChart.zoneSegments([day(0, 1.05), day(1, 1.1), day(2, 1.25)])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].band, .productive)
        XCTAssertEqual(segments[0].samples.count, 3)
    }

    /// 1.3 itself is still productive (Polar's "above 1.3"), so a day exactly on it adds no crossing.
    func testADayExactlyOnAThresholdIsNotDuplicated() {
        let segments = LoadRatioChart.zoneSegments([day(0, 1.2), day(1, 1.3), day(2, 1.4)])
        XCTAssertEqual(segments.map(\.band), [.productive, .above])
        XCTAssertEqual(values(segments), [[1.2, 1.3], [1.3, 1.4]])
    }

    func testADayWithoutAComparisonBreaksTheLine() {
        let segments = LoadRatioChart.zoneSegments([day(0, 1.1), day(1, 1.2), nil, day(3, 1.15)])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(values(segments), [[1.1, 1.2], [1.15]])
    }
}

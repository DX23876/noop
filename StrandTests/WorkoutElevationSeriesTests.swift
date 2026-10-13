import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The profile series a route's heights become, and the climb a recording carries onto a new key.
final class WorkoutElevationSeriesTests: XCTestCase {

    private func point(_ i: Int, baro: Double?, altitude: Double?, segment: Int = 0) -> WorkoutRoutePoint {
        WorkoutRoutePoint(lat: 47.37 + Double(i) * 0.0001, lon: 8.55, accuracyM: 5,
                          tMs: 1_700_000_000_000 + Int64(i) * 5_000, segment: segment,
                          activeSeconds: Double(i * 5), altitudeM: altitude, baroAltitudeM: baro)
    }

    func testBarometerShapeIsLiftedToSeaLevelByTheMedianOffset() throws {
        let points = (0..<20).map { point($0, baro: Double($0), altitude: 400 + Double($0) + ($0 == 3 ? 30 : 0)) }
        let series = try XCTUnwrap(WorkoutElevationSeries.make(points: points))
        XCTAssertTrue(series.isAbsolute)
        XCTAssertEqual(series.heights.first ?? 0, 400, accuracy: 1e-9)
        XCTAssertEqual(series.heights.last ?? 0, 419, accuracy: 1e-9)
        // About 11.1 m per point, 1 m up per point: a steady 9 % grade.
        XCTAssertEqual(series.currentGrade ?? 0, 1 / 11.12, accuracy: 0.002)
    }

    func testBarometerWithoutAbsoluteIsRelativeToStart() throws {
        let points = (0..<5).map { point($0, baro: 3 + Double($0), altitude: nil) }
        let series = try XCTUnwrap(WorkoutElevationSeries.make(points: points))
        XCTAssertFalse(series.isAbsolute)
        XCTAssertEqual(series.heights, [0, 1, 2, 3, 4])
    }

    func testHealthRouteUsesItsAltitudeAndPointsWithoutHeightDropOut() throws {
        let points = [point(0, baro: nil, altitude: 500), point(1, baro: nil, altitude: nil),
                      point(2, baro: nil, altitude: 502)]
        let series = try XCTUnwrap(WorkoutElevationSeries.make(points: points))
        XCTAssertTrue(series.isAbsolute)
        XCTAssertEqual(series.heights, [500, 502])
        XCTAssertNil(WorkoutElevationSeries.make(points: [point(0, baro: nil, altitude: nil)]))
    }

    func testDistanceDoesNotRunAcrossASegmentGap() throws {
        let points = [point(0, baro: 0, altitude: nil), point(1, baro: 0, altitude: nil),
                      point(50, baro: 0, altitude: nil, segment: 1), point(51, baro: 0, altitude: nil, segment: 1)]
        let series = try XCTUnwrap(WorkoutElevationSeries.make(points: points))
        XCTAssertEqual(series.totalDistanceM, 2 * 11.12, accuracy: 0.1)
        XCTAssertNotNil(series.wholeGradeAdjustedPace(gait: .walking))
    }

    func testDrawableKeepsEndsAndCapsTheCount() throws {
        let points = (0..<1000).map { point($0, baro: Double($0 % 7), altitude: nil) }
        let samples = try XCTUnwrap(WorkoutElevationSeries.make(points: points)).drawable(maxPoints: 100)
        XCTAssertLessThanOrEqual(samples.count, 101)
        XCTAssertEqual(samples.first?.distanceM, 0)
        XCTAssertEqual(samples.last?.distanceM ?? 0, 999 * 11.12, accuracy: 2)
    }

    func testGaitFollowsTheSport() {
        XCTAssertEqual(WorkoutElevationSeries.gait(forSport: "Running"), .running)
        XCTAssertEqual(WorkoutElevationSeries.gait(forSport: "Hiking"), .walking)
        XCTAssertNil(WorkoutElevationSeries.gait(forSport: "Cycling"))
    }

    func testRecordedClimbSumsAcrossMergedRecordings() throws {
        func recording(_ gain: Double?, _ loss: Double?) -> CompletedWorkoutRecording {
            var timeline = WorkoutRecordingTimeline(splitLengthM: 1000)
            if let gain, let loss { timeline.recordElevation(gainM: gain, lossM: loss) }
            let row = WorkoutRow(startTs: 100, endTs: 400, sport: "Walking", source: "manual", durationS: 300,
                                 energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                 zonesJSON: nil, notes: nil, steps: nil)
            return CompletedWorkoutRecording(id: UUID(), deviceId: "strap", row: row, route: nil, timeline: timeline)
        }
        let merged = WorkoutRow(startTs: 50, endTs: 900, sport: "Hiking", source: "manual", durationS: 850,
                                energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                zonesJSON: nil, notes: nil, steps: nil)
        let row = try XCTUnwrap(Repository.recordedElevation([recording(12, 3), recording(nil, nil), recording(6, 9)],
                                                             row: merged, deviceId: "strap"))
        XCTAssertEqual(row.key, WorkoutKey(deviceId: "strap", startTs: 50, sport: "Hiking"))
        XCTAssertEqual(row.ascentM, 18)
        XCTAssertEqual(row.descentM, 12)
        XCTAssertEqual(row.source, WorkoutElevationSource.barometer)
        XCTAssertNil(Repository.recordedElevation([recording(nil, nil)], row: merged, deviceId: "strap"))
    }

    func testElevationAndGradeFormatting() {
        XCTAssertEqual(UnitFormatter.elevationFromMeters(412.4, system: .metric), "412 m")
        XCTAssertEqual(UnitFormatter.elevationFromMeters(100, system: .imperial), "328 ft")
        XCTAssertEqual(UnitFormatter.gradePercent(0.064), "6 %")
        XCTAssertEqual(UnitFormatter.gradePercent(-0.03), "−3 %")
    }
}

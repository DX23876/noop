import XCTest
@testable import StrandAnalytics

/// gpx.studio's grade window, Minetti's cost curves and the grade-adjusted pace built on them.
final class ElevationProfileTests: XCTestCase {

    // MARK: Grade (gpx.studio)

    func testConstantSlopeReadsItsGradeEverywhere() {
        let distances = stride(from: 0.0, through: 500, by: 10).map { $0 }
        let heights = distances.map { $0 * 0.05 }
        let grades = ElevationProfile.grades(distancesM: distances, elevationsM: heights)
        XCTAssertEqual(grades.count, distances.count)
        for grade in grades { XCTAssertEqual(grade, 0.05, accuracy: 1e-9) }
    }

    /// gpx.studio's window: back while more than 50 m away, forward while within 50 m, at least one point
    /// either side. A single 10 m step shows up only for points whose window spans it.
    func testWindowReachesFiftyMetresEitherSide() {
        let distances = stride(from: 0.0, through: 300, by: 10).map { $0 }
        let heights = distances.map { $0 >= 150 ? 1.0 : 0.0 }
        let grades = ElevationProfile.grades(distancesM: distances, elevationsM: heights)
        // Point at 100 m: window 50…150 m, which contains the step.
        XCTAssertEqual(grades[10], 1.0 / 100, accuracy: 1e-9)
        // Point at 90 m: window 40…140 m, flat.
        XCTAssertEqual(grades[9], 0, accuracy: 1e-9)
        // Point at 200 m: window 150…250 m, flat after the step.
        XCTAssertEqual(grades[20], 0, accuracy: 1e-9)
        // Point at 199.9-ish neighbours: 190 m spans 140…240 m, contains it.
        XCTAssertEqual(grades[19], 1.0 / 100, accuracy: 1e-9)
    }

    func testSparsePointsStillUseOneNeighbourEachSide() {
        let grades = ElevationProfile.grades(distancesM: [0, 200, 400], elevationsM: [0, 10, 10])
        XCTAssertEqual(grades[0], 10.0 / 200, accuracy: 1e-9)
        XCTAssertEqual(grades[1], 10.0 / 400, accuracy: 1e-9)
        XCTAssertEqual(grades[2], 0, accuracy: 1e-9)
        XCTAssertEqual(ElevationProfile.grades(distancesM: [0, 0], elevationsM: [0, 5]), [0, 0])
        XCTAssertEqual(ElevationProfile.grades(distancesM: [], elevationsM: []), [])
    }

    // MARK: Minetti 2002

    func testCostCurvesMatchThePaper() {
        XCTAssertEqual(MinettiCost.running(grade: 0), 3.6, accuracy: 1e-9)
        XCTAssertEqual(MinettiCost.walking(grade: 0), 2.5, accuracy: 1e-9)
        // The fitted curve at +0.45 against the measured 17.33 ± 1.11 J/kg/m for walking.
        XCTAssertEqual(MinettiCost.walking(grade: 0.45), 17.33, accuracy: 1.11)
        // Running's measured cost at −0.20 was 1.73 ± 0.36 J/kg/m.
        XCTAssertEqual(MinettiCost.running(grade: -0.20), 1.73, accuracy: 0.36)
        // Outside the measured range the curve is held at its edge, never extrapolated.
        XCTAssertEqual(MinettiCost.running(grade: 0.9), MinettiCost.running(grade: 0.45))
        XCTAssertEqual(MinettiCost.walking(grade: .nan), 2.5)
    }

    func testFlatEquivalentFactor() {
        XCTAssertEqual(MinettiCost.flatEquivalentFactor(grade: 0, gait: .running), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(MinettiCost.flatEquivalentFactor(grade: 0.05, gait: .running), 1)
        XCTAssertLessThan(MinettiCost.flatEquivalentFactor(grade: -0.05, gait: .running), 1)
    }

    // MARK: Grade-adjusted pace

    private func track(grade: Double, seconds perKm: Double, segment: Int = 0) -> [ElevationTrackPoint] {
        stride(from: 0.0, through: 1000, by: 10).map {
            ElevationTrackPoint(distanceM: $0, seconds: $0 / 1000 * perKm, elevationM: $0 * grade, segment: segment)
        }
    }

    func testFlatRouteKeepsItsPace() {
        let points = track(grade: 0, seconds: 360)
        let grades = GradeAdjustedPace.grades(points)
        let gap = GradeAdjustedPace.paceSecPerKm(points, grades: grades, gait: .running, from: 0, to: 360)
        XCTAssertEqual(gap ?? 0, 360, accuracy: 1e-6)
    }

    func testUphillReadsFasterAndDownhillSlowerOnTheFlat() {
        let up = track(grade: 0.06, seconds: 400)
        let upGap = GradeAdjustedPace.paceSecPerKm(up, grades: GradeAdjustedPace.grades(up), gait: .running,
                                                   from: 0, to: 400)
        XCTAssertEqual(upGap ?? 0, 400 / MinettiCost.flatEquivalentFactor(grade: 0.06, gait: .running), accuracy: 1e-6)
        XCTAssertLessThan(upGap ?? .infinity, 400)
        let down = track(grade: -0.04, seconds: 330)
        let downGap = GradeAdjustedPace.paceSecPerKm(down, grades: GradeAdjustedPace.grades(down), gait: .walking,
                                                     from: 0, to: 330)
        XCTAssertGreaterThan(downGap ?? 0, 330)
    }

    func testSectionUsesOnlyItsOwnShareOfALeg() {
        let points = track(grade: 0, seconds: 360)
        let grades = GradeAdjustedPace.grades(points)
        let half = GradeAdjustedPace.flatEquivalentMeters(points, grades: grades, gait: .running, from: 0, to: 180)
        XCTAssertEqual(half ?? 0, 500, accuracy: 1e-6)
    }

    func testNoHeightsGiveNoGradeAndSegmentsAreGradedApart() {
        let none = [ElevationTrackPoint(distanceM: 0, seconds: 0, elevationM: nil, segment: 0),
                    ElevationTrackPoint(distanceM: 10, seconds: 5, elevationM: nil, segment: 0)]
        XCTAssertEqual(GradeAdjustedPace.grades(none), [nil, nil])
        XCTAssertNil(GradeAdjustedPace.paceSecPerKm(none, grades: [nil, nil], gait: .running, from: 0, to: 5))
        // Two flat segments at different barometer baselines (a relaunch) must not read as a cliff.
        let first = track(grade: 0, seconds: 360)
        let second = track(grade: 0, seconds: 360, segment: 1).map {
            ElevationTrackPoint(distanceM: $0.distanceM + 1000, seconds: $0.seconds + 400,
                                elevationM: 80, segment: 1)
        }
        let grades = GradeAdjustedPace.grades(first + second)
        XCTAssertEqual(grades.compactMap { $0 }.map(abs).max() ?? 1, 0, accuracy: 1e-12)
        XCTAssertEqual(GradeAdjustedPace.extremes(grades)?.maxUp, 0)
    }
}

import XCTest
@testable import StrandAnalytics

final class EnergyCalibrationEngineTests: XCTestCase {
    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testStableSevenDayOverlapProducesBoundedRobustFit() throws {
        var points: [EnergyCalibrationPoint] = []
        for day in 0..<7 {
            for bucket in 0..<12 {
                points.append(.init(timestamp: 1_700_000_000 + day * 86_400 + bucket * 300,
                                    whoopKcal: 10, appleWatchKcal: 11, overlapQuality: 0.9))
            }
        }
        points.append(.init(timestamp: 1_700_000_000, whoopKcal: 1, appleWatchKcal: 90,
                            overlapQuality: 1))
        let fit = try XCTUnwrap(EnergyCalibrationEngine.fit(points: points, calendar: utc))
        XCTAssertEqual(fit.factor, 1.1, accuracy: 0.001)
        XCTAssertEqual(fit.sampleDays, 7)
        XCTAssertEqual(fit.sampleBuckets, 84)
        XCTAssertEqual(EnergyCalibrationEngine.apply(2_000, fit: fit), 2_200, accuracy: 1)
    }

    func testInsufficientDaysBucketsOrQualityWithholdsFit() {
        let rows = (0..<84).map {
            EnergyCalibrationPoint(timestamp: 1_700_000_000 + $0 * 300,
                                   whoopKcal: 10, appleWatchKcal: 11, overlapQuality: 0.9)
        }
        XCTAssertNil(EnergyCalibrationEngine.fit(points: rows, calendar: utc))
        XCTAssertNil(EnergyCalibrationEngine.fit(points: rows.map {
            .init(timestamp: $0.timestamp, whoopKcal: $0.whoopKcal,
                  appleWatchKcal: $0.appleWatchKcal, overlapQuality: 0.2)
        }, calendar: utc))
    }

    func testUnstableRatiosAndExtremeFactorsAreRejectedOrClamped() throws {
        let unstable = (0..<84).map { index in
            EnergyCalibrationPoint(timestamp: 1_700_000_000 + (index / 12) * 86_400 + index % 12 * 300,
                                   whoopKcal: 10, appleWatchKcal: index.isMultiple(of: 2) ? 5 : 18,
                                   overlapQuality: 1)
        }
        XCTAssertNil(EnergyCalibrationEngine.fit(points: unstable, calendar: utc))

        let stable = (0..<84).map { index in
            EnergyCalibrationPoint(timestamp: 1_700_000_000 + (index / 12) * 86_400 + index % 12 * 300,
                                   whoopKcal: 10, appleWatchKcal: 15, overlapQuality: 1)
        }
        XCTAssertEqual(EnergyCalibrationEngine.fit(points: stable, calendar: utc)?.factor, 1.2)
    }

    /// Guards the invalidation contract, not a magic string: `Repository.energyCalibrationState`
    /// treats a stored fit as `.active` only when its `modelVersion` matches exactly, so a v1
    /// (total-based) fit reads as absent rather than being applied as if it had been fitted on
    /// active-only energy. A silent revert of the version bump would resurrect that diluted factor.
    func testModelVersionIsTheActiveOnlyGeneration() {
        XCTAssertEqual(EnergyCalibrationFit.modelVersion, "watch-reference-v2")
    }
}

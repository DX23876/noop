import XCTest
@testable import StrandAnalytics

final class WorkoutEnergyEstimateTests: XCTestCase {
    private let profile = UserProfile(weightKg: 80, heightCm: 180, age: 30, sex: "male")

    private func resolve(recorded: Double? = nil, sport: String = "Strength Training",
                         seconds: Double = 4_620, avgHR: Int? = nil)
        -> WorkoutEnergyEstimate.Resolved? {
        WorkoutEnergyEstimate.resolve(recordedKcal: recorded, sport: sport, durationSeconds: seconds,
                                      averageHR: avgHR, profile: profile, hrMax: 190, restingHR: 55)
    }

    func testARecordedFigureWinsAndIsNotMarkedAsAnEstimate() {
        let resolved = resolve(recorded: 512, avgHR: 103)
        XCTAssertEqual(resolved?.kcal, 512)
        XCTAssertEqual(resolved?.provenance, .recorded)
        XCTAssertEqual(resolved?.isEstimated, false)
    }

    func testAnAverageHeartRateBeatsTheTable() {
        // The reported session: 1 h 17 m at 103 bpm, nothing recorded. Heart rate is evidence about
        // the person who did it; the table is an average over everyone who ever did the activity.
        let resolved = resolve(avgHR: 103)
        XCTAssertEqual(resolved?.provenance, .heartRate)
        XCTAssertEqual(resolved?.isEstimated, true)
        XCTAssertGreaterThan(resolved?.kcal ?? 0, 0)

        let table = resolve()
        XCTAssertEqual(table?.provenance, .metTable)
        XCTAssertNotEqual(resolved?.kcal, table?.kcal, "the two branches must not coincide by accident")
    }

    func testTheTableCarriesASessionWithNoHeartRateAtAll() {
        // A Hevy import or a hand-entered bout: no samples, no average, still an hour of lifting.
        let resolved = resolve(sport: "Strength", seconds: 3_600, avgHR: nil)
        XCTAssertEqual(resolved?.provenance, .metTable)
        XCTAssertEqual(resolved?.kcal ?? 0,
                       ActivityMETCatalog.grossKcal(sport: "Strength", seconds: 3_600, weightKg: 80) ?? 0,
                       accuracy: 0.001)
    }

    func testAZeroHeartRateIsNotEvidenceAndFallsThrough() {
        XCTAssertEqual(resolve(avgHR: 0)?.provenance, .metTable)
    }

    func testARecordedZeroIsNotARecording() {
        // Several importers write 0 rather than omitting the field. Treating that as "measured, and
        // it cost nothing" is how a lifting session ends up reading as free.
        XCTAssertEqual(resolve(recorded: 0, avgHR: 103)?.provenance, .heartRate)
    }

    func testASessionNobodyCanPriceIsNilRatherThanZero() {
        XCTAssertNil(resolve(seconds: 0, avgHR: 103))
        XCTAssertNil(WorkoutEnergyEstimate.resolve(
            recordedKcal: nil, sport: "Strength", durationSeconds: 3_600, averageHR: nil,
            profile: UserProfile(weightKg: 0, heightCm: 180, age: 30, sex: "male"),
            hrMax: nil, restingHR: nil))
    }

    func testAnUnknownSportStillCostsSomething() {
        // Free text is allowed everywhere a sport is entered, and an unrecognised name must not make
        // the session free — `ActivityMETCatalog` has a deliberately conservative default for it.
        let resolved = resolve(sport: "Underwater basket weaving", seconds: 3_600)
        XCTAssertEqual(resolved?.provenance, .metTable)
        XCTAssertGreaterThan(resolved?.kcal ?? 0, 0)
    }
}

import XCTest
import StrandAnalytics
import StrandCore
import WhoopStore
@testable import NoopCore

/// The Energy detail screen on Android (parity plan 2.3): a day without a minute-by-minute record says so, and the
/// comparison falls back to what the store can honestly show.
@MainActor
final class CoreEnergyDetailTests: XCTestCase {
    func testADayWithoutBucketsHasNoCurveAndSaysWhyTheComparisonIsMissing() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "my-whoop", registeredWhoopIds: [])
        let settings = CoreGoalEnergy.settings(["sex": "male", "energyProfile":
            ["weightKg": 90.0, "heightCm": 180.0, "age": 40.0, "maxHR": 185.0]])
        let noProfile = await CoreEnergyDetail.read(reader: reader, settings: CoreGoalEnergy.settings([:]), day: nil,
                                                    comparison: "")
        XCTAssertTrue(noProfile.summaries.isEmpty)
        XCTAssertEqual(noProfile.comparison, "sevenDay")

        let week = await CoreEnergyDetail.read(reader: reader, settings: settings, day: nil, comparison: "sevenDay")
        XCTAssertEqual(week.day, week.today)
        XCTAssertTrue(week.points.isEmpty)
        XCTAssertTrue(week.comparisonPoints.isEmpty)
        XCTAssertEqual(week.comparisonUnavailable, "Not enough fully measured days yet to show a 7-day average.")

        let previous = await CoreEnergyDetail.read(reader: reader, settings: settings, day: "2026-10-20",
                                                   comparison: "previousDay")
        XCTAssertEqual(previous.day, "2026-10-20")
        XCTAssertEqual(previous.comparisonUnavailable, "The day before has no minute-by-minute record.")
        XCTAssertEqual(CoreEnergyDetail.previousDay("2026-03-01"), "2026-02-28")
    }
}

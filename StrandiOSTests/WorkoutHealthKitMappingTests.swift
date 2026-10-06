#if os(iOS)
import XCTest
import HealthKit
@testable import NOOP_Staging

final class WorkoutHealthKitMappingTests: XCTestCase {
    func testRepresentativeSportsKeepTheirHealthKitMeaning() {
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Running"), .running)
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Mountain biking"), .cycling)
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Calisthenics"), .functionalStrengthTraining)
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Jiu jitsu"), .martialArts)
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Stand-up paddleboard"), .paddleSports)
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Horseback riding"), .equestrianSports)
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Wheelchair"), .wheelchairWalkPace)
    }

    func testUnknownSportFallsBackWithoutDroppingWorkout() {
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Custom expedition"), .other)
    }

    func testMotorsportsWithoutHealthKitTypeWriteAsOther() {
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Motocross"), .other)
        XCTAssertEqual(HealthKitBridge.activityType(forSport: "Motor racing"), .other)
    }
}
#endif

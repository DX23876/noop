import XCTest
import StrandCore

/// What the phone's health store is told about where a session happened (Refs #2928). The write-back
/// used to send only the activity type, so a reader fell back to outdoors and a treadmill run exported
/// from NOOP showed up in Strava as an outdoor run.
final class WorkoutHealthLocationTests: XCTestCase {
    func testAnIndoorSportIsIndoorWhateverTheRouteSays() {
        for sport in ["Treadmill run", "Treadmill walk", "Indoor cycle", "Row machine", "Elliptical",
                      "Strength", "Yoga", "Pool swim"] {
            let location = WorkoutCatalog.healthLocation(sportNamed: sport, hasRoute: false)
            XCTAssertEqual(location.environment, .indoor, sport)
            XCTAssertEqual(location.isIndoor, true, sport)
            // A stray GPS trace (a phone carried past a window) does not move a treadmill outdoors.
            XCTAssertEqual(WorkoutCatalog.healthLocation(sportNamed: sport, hasRoute: true).isIndoor, true, sport)
        }
    }

    func testAnOutdoorSportIsOutdoor() {
        for sport in ["Golf", "Mountain biking", "Rucking", "Nordic walking", "Kayaking"] {
            let location = WorkoutCatalog.healthLocation(sportNamed: sport, hasRoute: false)
            XCTAssertEqual(location.environment, .outdoor, sport)
            XCTAssertEqual(location.isIndoor, false, sport)
        }
    }

    /// A sport that can be either is resolved by whether the session actually recorded a route, and
    /// otherwise carries NO flag: a missing flag reads as unknown, where `false` would assert outdoors.
    func testASportThatCanBeEitherFollowsTheRoute() {
        let noRoute = WorkoutCatalog.healthLocation(sportNamed: "Boxing", hasRoute: false)
        XCTAssertEqual(noRoute.environment, .either)
        XCTAssertNil(noRoute.isIndoor)

        let withRoute = WorkoutCatalog.healthLocation(sportNamed: "Boxing", hasRoute: true)
        XCTAssertEqual(withRoute.environment, .outdoor)
        XCTAssertEqual(withRoute.isIndoor, false)

        // An unknown sport name (an imported, localized label) behaves the same way.
        XCTAssertNil(WorkoutCatalog.healthLocation(sportNamed: "Spazieren", hasRoute: false).isIndoor)
        XCTAssertEqual(WorkoutCatalog.healthLocation(sportNamed: "Spazieren", hasRoute: true).isIndoor, false)
    }

    func testTheSwimmingWater() {
        XCTAssertEqual(WorkoutCatalog.swimWater(sportNamed: "Pool swim"), .pool)
        XCTAssertEqual(WorkoutCatalog.swimWater(sportNamed: "Open-water swim"), .openWater)
        XCTAssertEqual(WorkoutCatalog.swimWater(sportNamed: "open water swimming"), .openWater)
        XCTAssertNil(WorkoutCatalog.swimWater(sportNamed: "Swimming"), "a bare swim does not say which")
        XCTAssertNil(WorkoutCatalog.swimWater(sportNamed: "Running"))
        XCTAssertEqual(WorkoutCatalog.healthLocation(sportNamed: "Open-water swim", hasRoute: false).swim,
                       .openWater)
    }
}

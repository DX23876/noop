import XCTest
@testable import Strand

/// Pins the Training tab's one-tap start: which activities it offers and that each one repeats, and
/// states, the route and zone-coach choice it was last started with.
@MainActor
final class WorkoutQuickStartTests: XCTestCase {
    nonisolated private static let suite = "WorkoutQuickStartTests"
    private var defaults: UserDefaults { UserDefaults(suiteName: Self.suite)! }

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: Self.suite)?.removePersistentDomain(forName: Self.suite)
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suite)?.removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func sport(_ name: String) -> WorkoutCatalog.Sport {
        guard let sport = WorkoutCatalog.sport(named: name) else {
            XCTFail("\(name) is not in the catalogue")
            return WorkoutCatalog.Sport(name: name, isDistanceSport: false)
        }
        return sport
    }

    func testFirstVisitOffersTheStarterSet() {
        XCTAssertEqual(WorkoutQuickStart.activities(recent: []).map(\.name), ["Walking", "Running", "Cycling"])
    }

    func testRecentsComeFirstWithoutStrengthOrDuplicates() {
        let names = WorkoutQuickStart.activities(recent: ["Yoga", "Strength Training", "walking", "Unknown"])
            .map(\.name)
        XCTAssertEqual(names, ["Yoga", "Walking", "Running"])
    }

    func testListStopsAtTheCap() {
        let names = WorkoutQuickStart.activities(recent: ["Yoga", "Hiking", "Swimming", "Rowing", "Padel"])
        XCTAssertEqual(names.count, WorkoutQuickStart.maxActivities)
        XCTAssertEqual(names.first?.name, "Yoga")
    }

    func testAnActivityNeverStartedUsesItsRouteDefaultAndNoZoneCoach() {
        let walking = sport("Walking")
        XCTAssertEqual(WorkoutStartSettings.remembered(for: walking, in: defaults),
                       WorkoutStartSettings(gpsEnabled: walking.defaultGpsEnabled, targetZone: nil))
    }

    func testTheLastStartIsRememberedPerActivity() {
        let walking = sport("Walking")
        let yoga = sport("Yoga")
        WorkoutStartSettings.record(WorkoutStartSettings(gpsEnabled: false, targetZone: 2), for: walking, in: defaults)
        WorkoutStartSettings.record(WorkoutStartSettings(gpsEnabled: false, targetZone: 3), for: yoga, in: defaults)
        XCTAssertEqual(WorkoutStartSettings.remembered(for: walking, in: defaults),
                       WorkoutStartSettings(gpsEnabled: false, targetZone: 2))
        XCTAssertEqual(WorkoutStartSettings.remembered(for: yoga, in: defaults).targetZone, 3)
    }

    func testRouteAndZoneAreKeptValid() {
        let yoga = sport("Yoga")
        XCTAssertFalse(yoga.supportsRoute)
        WorkoutStartSettings.record(WorkoutStartSettings(gpsEnabled: true, targetZone: 9), for: yoga, in: defaults)
        XCTAssertEqual(WorkoutStartSettings.remembered(for: yoga, in: defaults),
                       WorkoutStartSettings(gpsEnabled: false, targetZone: nil))
    }

    func testSummaryNamesWhatTheStartWillDo() {
        let walking = sport("Walking")
        XCTAssertEqual(TrainingQuickStartCard.summary(WorkoutStartSettings(gpsEnabled: true, targetZone: 2), for: walking),
                       "Route · Zone 2")
        XCTAssertEqual(TrainingQuickStartCard.summary(WorkoutStartSettings(gpsEnabled: false, targetZone: nil),
                                                      for: sport("Yoga")),
                       "No zone coach")
    }
}

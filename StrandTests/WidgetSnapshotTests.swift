import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testAltStoreProvisionedGroupWinsOverBuildTimeIdentifier() {
        let configured = "group.com.noopapp.noop.staging"
        let remapped = configured + ".TEAM123456"

        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": configured,
                "ALTAppGroups": [remapped]
            ]),
            remapped
        )
    }

    func testXcodeBuildFallsBackToConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop"
            ]),
            "group.example.noop"
        )
    }

    func testUnrelatedAltStoreGroupsDoNotOverrideConfiguredGroup() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "AppGroupIdentifier": "group.example.noop",
                "ALTAppGroups": [
                    "group.example.first",
                    "group.example.second"
                ]
            ]),
            "group.example.noop"
        )
    }

    func testSingleProvisionedGroupIsUsableWithoutConfiguredIdentifier() {
        XCTAssertEqual(
            WidgetSnapshot.resolveSuiteName(infoDictionary: [
                "ALTAppGroups": ["group.example.noop.TEAM123456"]
            ]),
            "group.example.noop.TEAM123456"
        )
    }

    func testRuntimeUnavailableSnapshotContainsNoDemoValues() {
        let snapshot = WidgetSnapshot.unavailable

        XCTAssertNil(snapshot.recovery)
        XCTAssertNil(snapshot.bpm)
        XCTAssertNil(snapshot.batteryPct)
        XCTAssertFalse(snapshot.bonded)
        // The goal widget reads these; an unavailable snapshot must not imply a goal exists.
        XCTAssertFalse(snapshot.hasGoal)
        XCTAssertNil(snapshot.goalFraction)
    }

    /// The compatibility contract for every field added after the first ship: a snapshot written by an
    /// OLDER app build never encoded those keys, and it must still decode rather than leaving the widget
    /// with nothing to draw. Pinned with a hand-written payload because a round-trip through the CURRENT
    /// encoder can never reproduce the absence of a key.
    func testSnapshotFromAnOlderBuildStillDecodes() throws {
        let legacy = """
        {"recovery":64,"bpm":57,"batteryPct":80,"bonded":true,"updated":760000000}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: legacy)

        XCTAssertEqual(decoded.recovery, 64)
        XCTAssertEqual(decoded.bpm, 57)
        // Everything added later reads as absent, not as a default that looks like data.
        XCTAssertNil(decoded.effort)
        XCTAssertNil(decoded.goalTitle)
        XCTAssertNil(decoded.goalSymbol)
        XCTAssertNil(decoded.goalFraction)
        XCTAssertFalse(decoded.hasGoal)
    }

    func testGoalFieldsSurviveARoundTrip() throws {
        let snapshot = WidgetSnapshot(recovery: 70, bpm: nil, batteryPct: nil, bonded: true,
                                      updated: Date(timeIntervalSince1970: 760_000_000),
                                      goalTitle: "Half marathon", goalSymbol: "figure.run",
                                      goalTintId: "coach.goal.run", goalFraction: 0.42,
                                      goalRunwayWeeks: 9, goalLine: "12.0 km now.")

        let decoded = try JSONDecoder().decode(WidgetSnapshot.self,
                                               from: try JSONEncoder().encode(snapshot))

        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.hasGoal)
        XCTAssertEqual(decoded.goalSymbol, "figure.run")
        XCTAssertEqual(try XCTUnwrap(decoded.goalFraction), 0.42, accuracy: 0.0001)
    }
}

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

    private func renderedSnapshot(updated: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> WidgetSnapshot {
        WidgetSnapshot(recovery: 72, bpm: 58, batteryPct: 84, bonded: true, updated: updated,
                       effort: 38, rest: 81, hrv: 64, restingHr: 52,
                       effortDisplay: "38", effortWhoop: false)
    }

    func testRenderedContentFirstPublishAlwaysChanges() {
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: nil, to: renderedSnapshot()))
    }

    func testRenderedContentIgnoresTimestampOnlyChange() {
        let previous = renderedSnapshot()
        let next = renderedSnapshot(updated: previous.updated.addingTimeInterval(900))

        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsLiveFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.bpm = 59

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testRenderedContentDetectsScoreFieldChange() {
        let previous = renderedSnapshot()
        var next = previous
        next.rest = 82

        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    /// The goal widget renders these, so they have to earn a reload like any other visible field. Left
    /// out of the dedup, a renamed or re-measured goal would sit stale on the home screen because the
    /// publisher decided nothing had changed.
    func testRenderedContentDetectsGoalFieldChange() {
        let previous = renderedSnapshot()

        var renamed = previous
        renamed.goalTitle = "Half marathon"
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: previous, to: renamed))

        var remeasured = renamed
        remeasured.goalFraction = 0.62
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: renamed, to: remeasured))

        var deleted = remeasured
        deleted.goalTitle = nil
        deleted.goalFraction = nil
        XCTAssertTrue(WidgetSnapshot.renderedContentChanged(from: remeasured, to: deleted))
    }

    func testLiveUpdateReusesSnapshotWithinSameLocalDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let oneHourLater = previous.updated.addingTimeInterval(3_600)

        XCTAssertFalse(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: oneHourLater, calendar: calendar))
    }

    func testLiveUpdateRequiresFullBuildAfterLocalDayRollover() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let previous = renderedSnapshot(updated: Date(timeIntervalSince1970: 1_700_000_000))
        let nextDay = previous.updated.addingTimeInterval(86_400)

        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: previous, now: nextDay, calendar: calendar))
        XCTAssertTrue(WidgetSnapshot.liveUpdateRequiresFullBuild(
            previous: nil, now: nextDay, calendar: calendar))
    }
}

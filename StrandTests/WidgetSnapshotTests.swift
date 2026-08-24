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

    func testEnergyChangeReloadsOnlyEnergyContent() {
        let previous = renderedSnapshot()
        var next = previous
        next.energy = WidgetEnergySnapshot(day: "2026-08-22", totalKcal: 1_234,
                                           activeKcal: 345, basalKcal: 889,
                                           projectedKcal: 2_300, source: "appleSplit",
                                           confidence: "solid", asOf: Date())

        XCTAssertTrue(WidgetSnapshot.energyContentChanged(from: previous, to: next))
        XCTAssertFalse(WidgetSnapshot.glanceContentChanged(from: previous, to: next))
        XCTAssertFalse(WidgetSnapshot.ringsContentChanged(from: previous, to: next))
    }

    func testEnergyTimestampAloneDoesNotSpendAReload() {
        var previous = renderedSnapshot()
        previous.energy = WidgetEnergySnapshot(day: "2026-08-22", totalKcal: 1_234,
                                               activeKcal: 345, basalKcal: 889,
                                               projectedKcal: 2_300, source: "appleSplit",
                                               confidence: "solid", asOf: Date())
        var next = previous
        next.energy?.asOf = Date().addingTimeInterval(900)

        XCTAssertFalse(WidgetSnapshot.energyContentChanged(from: previous, to: next))
        XCTAssertFalse(WidgetSnapshot.renderedContentChanged(from: previous, to: next))
    }

    func testSnapshotWithoutEnergyKeyStillDecodes() throws {
        struct Legacy: Codable {
            let recovery: Int?
            let bpm: Int?
            let batteryPct: Int?
            let bonded: Bool
            let updated: Date
            let effort: Int?
            let rest: Int?
            let hrv: Int?
            let restingHr: Int?
            let effortDisplay: String?
            let effortWhoop: Bool?
        }
        let data = try JSONEncoder().encode(Legacy(
            recovery: 70, bpm: 58, batteryPct: 80, bonded: true, updated: Date(),
            effort: 40, rest: 82, hrv: 61, restingHr: 52,
            effortDisplay: "40", effortWhoop: false))
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(decoded.energy)
        XCTAssertEqual(decoded.recovery, 70)
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

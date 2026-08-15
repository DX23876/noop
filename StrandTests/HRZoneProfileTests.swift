import XCTest
@testable import Strand
import StrandAnalytics

/// The app-target half of the custom-zone feature: `ProfileStore`'s resolver and the coach's band line.
///
/// These matter more than usual because no default CI compiles this target at all (`app-build.yml` is
/// disabled, `swift-packages.yml` covers `Packages/**` only), so the pure `HRZonesTests` can be green
/// while the wiring that actually feeds the screens is broken.
///
/// `ProfileStore` reads and writes `UserDefaults.standard` with no suite seam, so each test snapshots
/// the three zone keys and puts them back — a test must not leave a tester's real bands rewritten.
@MainActor
final class HRZoneProfileTests: XCTestCase {

    private static let keys = ["profile.zoneMode", "profile.zonePercentEdges", "profile.zoneBpmEdges",
                               "profile.hrZoneThresholds", "profile.hrMaxOverride"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        saved = Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        for k in Self.keys { UserDefaults.standard.removeObject(forKey: k) }
    }

    override func tearDown() {
        for (k, v) in saved {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    /// A fresh profile is on the conventional bands, and says so rather than claiming a customisation.
    func testDefaultProfileResolvesToStandardBands() {
        let profile = ProfileStore()
        XCTAssertFalse(profile.hasCustomHRZones)
        XCTAssertEqual(profile.hrZoneConfig.mode, .auto)
        let zs = profile.hrZoneSet
        XCTAssertEqual(zs.zones.count, 5)
        XCTAssertEqual(zs.zones[0].lowerPct, 0.50, accuracy: 1e-9)
        XCTAssertEqual(zs.maxHR, Double(profile.hrMax), accuracy: 1e-9)
    }

    /// The resolver honours the manual HR-max override. This is the regression that started the whole
    /// change: `workoutZoneMinutes` used to build zones from AGE alone, so a wearer with a manual
    /// maximum saw one Zone 2 on the live screen and a different one in a workout's zone split.
    func testResolverHonoursTheManualHrMaxOverride() {
        let profile = ProfileStore()
        profile.hrMaxOverride = 200
        XCTAssertEqual(profile.hrZoneSet.maxHR, 200, accuracy: 1e-9)
        XCTAssertEqual(profile.hrZoneSet.zones[0].lower, 100, accuracy: 1e-9)
        XCTAssertEqual(profile.hrZoneSet.source, "manual")
    }

    /// A restore from an upstream ryanbr/noop backup: their single `profile.hrZoneThresholds` key is the
    /// only zone value present, and the wearer must still open the app on THEIR bands. Without the
    /// import they would silently be back on the conventional 50/60/70/80/90 set, having been told
    /// nothing — the one failure in this whole change that costs a user their own data.
    func testUpstreamThresholdsAreImportedAsBpmBands() {
        UserDefaults.standard.set(200, forKey: "profile.hrMaxOverride")
        UserDefaults.standard.set("95,118,142,168,184", forKey: "profile.hrZoneThresholds")

        let profile = ProfileStore()
        XCTAssertEqual(profile.hrZoneConfig.mode, .bpm)
        XCTAssertTrue(profile.hasCustomHRZones)
        XCTAssertEqual(profile.hrZoneSet.zones.map(\.lower), [95, 118, 142, 168, 184])
        XCTAssertEqual(profile.hrZoneSet.zoneNumber(forBPM: 117), 1)
        XCTAssertEqual(profile.hrZoneSet.zoneNumber(forBPM: 118), 2)
    }

    /// The import is a fallback, never an override: a wearer who has set bands in THIS fork keeps them
    /// even when an upstream key is also lying around (a restore from a mixed backup, say). Their own
    /// edit is the more recent statement of intent.
    func testOwnBandsWinOverTheUpstreamKey() {
        UserDefaults.standard.set(200, forKey: "profile.hrMaxOverride")
        UserDefaults.standard.set("95,118,142,168,184", forKey: "profile.hrZoneThresholds")
        UserDefaults.standard.set("bpm", forKey: "profile.zoneMode")
        UserDefaults.standard.set("110,130,150,170,184", forKey: "profile.zoneBpmEdges")

        let profile = ProfileStore()
        XCTAssertEqual(profile.hrZoneSet.zones.map(\.lower), [110, 130, 150, 170, 184])
    }

    /// A garbled upstream value must not flip the mode: `.auto` with an unusable import is still `.auto`,
    /// so the wearer sees the conventional bands rather than a broken partition.
    func testGarbledUpstreamKeyIsIgnored() {
        UserDefaults.standard.set("not,a,zone,set", forKey: "profile.hrZoneThresholds")

        let profile = ProfileStore()
        XCTAssertEqual(profile.hrZoneConfig.mode, .auto)
        XCTAssertFalse(profile.hasCustomHRZones)
    }

    func testPercentBandsPersistAndResolve() {
        let profile = ProfileStore()
        profile.hrMaxOverride = 200
        XCTAssertTrue(profile.setHRZoneConfig(
            HRZoneConfig(mode: .percent, percentLowerBounds: [0.55, 0.65, 0.75, 0.85, 0.92])))

        XCTAssertTrue(profile.hasCustomHRZones)
        XCTAssertEqual(profile.zonePercentEdgesRaw, "55,65,75,85,92")
        XCTAssertEqual(profile.hrZoneSet.source, "custom-percent")
        XCTAssertEqual(profile.hrZoneSet.zones[0].lower, 110, accuracy: 1e-9)

        // Survives a reload — the whole point of storing it.
        XCTAssertEqual(ProfileStore().hrZoneSet.zones[0].lower, 110, accuracy: 1e-9)
    }

    func testBpmBandsPersistAndResolve() {
        let profile = ProfileStore()
        profile.hrMaxOverride = 200
        XCTAssertTrue(profile.setHRZoneConfig(
            HRZoneConfig(mode: .bpm, bpmLowerBounds: [112, 132, 152, 172, 186])))

        XCTAssertEqual(profile.zoneBpmEdgesRaw, "112,132,152,172,186")
        XCTAssertEqual(profile.hrZoneSet.source, "custom-bpm")
        XCTAssertEqual(profile.hrZoneSet.zones[0].lower, 112, accuracy: 1e-9)
        XCTAssertEqual(ProfileStore().hrZoneSet.zones[0].lower, 112, accuracy: 1e-9)
    }

    /// An illegal set changes NOTHING — not the bounds, not the mode. The editor disables Save on the
    /// same rule, so this is the backstop rather than the only guard.
    func testInvalidConfigIsRefusedAndLeavesStorageAlone() {
        let profile = ProfileStore()
        profile.hrMaxOverride = 200
        XCTAssertTrue(profile.setHRZoneConfig(
            HRZoneConfig(mode: .percent, percentLowerBounds: [0.55, 0.65, 0.75, 0.85, 0.92])))

        XCTAssertFalse(profile.setHRZoneConfig(
            HRZoneConfig(mode: .percent, percentLowerBounds: [0.9, 0.6, 0.7, 0.8, 0.5])))

        XCTAssertEqual(profile.zonePercentEdgesRaw, "55,65,75,85,92")
        XCTAssertEqual(profile.hrZoneSet.zones[0].lower, 110, accuracy: 1e-9)
    }

    /// Switching modes must not discard the other mode's numbers — a wearer comparing the two would
    /// otherwise have to retype five bounds every time they flick back.
    func testSwitchingModesKeepsBothBoundSets() {
        let profile = ProfileStore()
        profile.hrMaxOverride = 200
        profile.setHRZoneConfig(HRZoneConfig(mode: .percent, percentLowerBounds: [0.55, 0.65, 0.75, 0.85, 0.92]))
        profile.setHRZoneConfig(HRZoneConfig(mode: .bpm, bpmLowerBounds: [112, 132, 152, 172, 186]))

        XCTAssertEqual(profile.zonePercentEdgesRaw, "55,65,75,85,92")
        XCTAssertEqual(profile.zoneBpmEdgesRaw, "112,132,152,172,186")

        profile.resetHRZones()
        XCTAssertFalse(profile.hasCustomHRZones)
        XCTAssertEqual(profile.zonePercentEdgesRaw, "55,65,75,85,92", "reset must not erase the drafts")
        XCTAssertEqual(profile.zoneBpmEdgesRaw, "112,132,152,172,186")
    }

    /// The coach has to STATE the bands it is prescribing in: "Zone 2" is not a shared constant once the
    /// wearer can move it, and a coach quoting the textbook 60–70 % at someone whose Zone 2 starts at
    /// 65 % is prescribing a different session than the one they'll ride.
    func testZoneBandsLineNamesCustomBandsExplicitly() {
        let custom = HRZones.zones(config: HRZoneConfig(mode: .percent,
                                                        percentLowerBounds: [0.55, 0.65, 0.75, 0.85, 0.92]),
                                   maxHR: 200)
        let line = AICoachEngine.zoneBandsLine(custom)
        XCTAssertTrue(line.contains("custom"), line)
        XCTAssertTrue(line.contains("110"), "the bpm bounds have to be in there, not just percentages: \(line)")
        XCTAssertTrue(line.contains("HRmax 200"), line)

        let standard = HRZones.zones(config: .auto, maxHR: 200, autoSource: "tanaka")
        XCTAssertTrue(AICoachEngine.zoneBandsLine(standard).contains("standard"))
    }
}

import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HRZonesTests: XCTestCase {

    func testTanakaMaxHR() {
        XCTAssertEqual(HRZones.tanakaMaxHR(age: 30), 187.0, accuracy: 1e-9)
        XCTAssertEqual(HRZones.tanakaMaxHR(age: 40), 180.0, accuracy: 1e-9)
    }

    func testZonesFromAge() {
        let zs = HRZones.zones(age: 30)
        XCTAssertEqual(zs.source, "tanaka")
        XCTAssertEqual(zs.maxHR, 187.0, accuracy: 1e-9)
        XCTAssertEqual(zs.zones.count, 5)
        // Zone 1 lower = 50% of 187 = 93.5; Zone 5 upper = 187.
        XCTAssertEqual(zs.zones[0].lower, 93.5, accuracy: 1e-9)
        XCTAssertEqual(zs.zones[4].upper, 187.0, accuracy: 1e-9)
    }

    func testManualOverride() {
        let zs = HRZones.zones(age: 30, maxHROverride: 200)
        XCTAssertEqual(zs.source, "manual")
        XCTAssertEqual(zs.maxHR, 200.0, accuracy: 1e-9)
        XCTAssertEqual(zs.zones[0].lower, 100.0, accuracy: 1e-9)  // 50% of 200
    }

    func testZonesPartitionContiguously() {
        // Each zone's upper edge must equal the next zone's lower edge (no gaps/overlap).
        let zs = HRZones.zones(maxHR: 200)
        for i in 0..<4 {
            XCTAssertEqual(zs.zones[i].upper, zs.zones[i + 1].lower, accuracy: 1e-9)
        }
    }

    func testZoneNumberForBPM() {
        let zs = HRZones.zones(maxHR: 200)  // edges: 100,120,140,160,180,200
        XCTAssertEqual(zs.zoneNumber(forBPM: 90), 0)    // below zone 1
        XCTAssertEqual(zs.zoneNumber(forBPM: 100), 1)   // zone 1 lower edge
        XCTAssertEqual(zs.zoneNumber(forBPM: 119), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 120), 2)
        XCTAssertEqual(zs.zoneNumber(forBPM: 150), 3)
        XCTAssertEqual(zs.zoneNumber(forBPM: 170), 4)
        XCTAssertEqual(zs.zoneNumber(forBPM: 185), 5)
        XCTAssertEqual(zs.zoneNumber(forBPM: 200), 5)   // top edge inclusive
        XCTAssertEqual(zs.zoneNumber(forBPM: 250), 5)   // above max still z5
    }

    func testTimeInZoneAccountsForAllTime() {
        let zs = HRZones.zones(maxHR: 200)  // edges 100/120/140/160/180/200
        // 1 Hz samples: 3 in z1 (110), 2 in z3 (150), 1 below (90).
        let hr = [
            HRSample(ts: 0, bpm: 110),
            HRSample(ts: 1, bpm: 110),
            HRSample(ts: 2, bpm: 110),
            HRSample(ts: 3, bpm: 150),
            HRSample(ts: 4, bpm: 150),
            HRSample(ts: 5, bpm: 90),
        ]
        let tiz = HRZones.timeInZone(hr, zoneSet: zs)
        // Each of the first 5 samples holds 1 s; tail (90 bpm) gets median gap (1 s).
        XCTAssertEqual(tiz.seconds(inZone: 1), 3.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.seconds(inZone: 3), 2.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.belowZone1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.seconds(inZone: 2), 0.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.total, 6.0, accuracy: 1e-9)
    }

    func testTimeInZoneEmpty() {
        let zs = HRZones.zones(maxHR: 200)
        let tiz = HRZones.timeInZone([], zoneSet: zs)
        XCTAssertEqual(tiz.total, 0.0)
    }

    func testTimeInZoneSortsDefensively() {
        let zs = HRZones.zones(maxHR: 200)
        // Out-of-order, evenly-spaced (1 s) input must sort then partition correctly:
        // ts 0,1,2 at 110 bpm (zone 1) → 3 s in zone 1 (each holds 1 s incl. the tail).
        let hr = [
            HRSample(ts: 2, bpm: 110),
            HRSample(ts: 0, bpm: 110),
            HRSample(ts: 1, bpm: 110),
        ]
        let tiz = HRZones.timeInZone(hr, zoneSet: zs)
        XCTAssertEqual(tiz.seconds(inZone: 1), 3.0, accuracy: 1e-9)
        XCTAssertEqual(tiz.total, 3.0, accuracy: 1e-9)  // all time accounted for
    }

    func testTimeInZoneCapsHugePositiveGap() {
        let zs = HRZones.zones(maxHR: 200)
        // Three 1 Hz zone-1 samples (median gap 1 s), then one sample an HOUR later. The 3600 s
        // gap before the last sample must be capped at the median (1 s) — as the comment promises —
        // not credited in full, so one wear gap / sparse stretch can't blow up a bucket.
        let hr = [
            HRSample(ts: 0, bpm: 110),
            HRSample(ts: 1, bpm: 110),
            HRSample(ts: 2, bpm: 110),
            HRSample(ts: 3602, bpm: 110),
        ]
        let tiz = HRZones.timeInZone(hr, zoneSet: zs)
        XCTAssertLessThan(tiz.total, 10.0,
                          "a huge inter-sample gap must be capped at the median, not credited in full")
        XCTAssertEqual(tiz.seconds(inZone: 1), tiz.total, accuracy: 1e-9)  // all of it is zone 1
    }

    // MARK: - Custom bands

    /// The whole point of the custom-edge overload: passing the DEFAULT edges explicitly must produce
    /// exactly what the pre-existing call produced, bound for bound. If this ever drifts, every user
    /// who never touched the setting silently gets different zones.
    func testDefaultEdgesAreUnchangedByTheOverload() {
        let plain = HRZones.zones(maxHR: 187)
        let explicit = HRZones.zones(maxHR: 187, edges: HRZones.zoneEdges)
        XCTAssertEqual(plain.zones, explicit.zones)
        XCTAssertTrue(HRZones.isDefaultEdges(HRZones.zoneEdges))
    }

    func testValidatedEdgesAcceptsALegalSet() {
        let edges = HRZones.validatedEdges(lowerPercents: [0.55, 0.65, 0.75, 0.85, 0.92])
        XCTAssertEqual(edges, [0.55, 0.65, 0.75, 0.85, 0.92, 1.0])
    }

    func testValidatedEdgesRejectsIllegalSets() {
        // Not five bounds.
        XCTAssertNil(HRZones.validatedEdges(lowerPercents: [0.5, 0.6, 0.7, 0.8]))
        // Zone 1 below the resting-HR floor.
        XCTAssertNil(HRZones.validatedEdges(lowerPercents: [0.2, 0.6, 0.7, 0.8, 0.9]))
        // Not ascending.
        XCTAssertNil(HRZones.validatedEdges(lowerPercents: [0.5, 0.6, 0.55, 0.8, 0.9]))
        // Two bounds equal — would make a zero-wide zone `zoneNumber(forBPM:)` can never return.
        XCTAssertNil(HRZones.validatedEdges(lowerPercents: [0.5, 0.6, 0.6, 0.8, 0.9]))
        // Zone 5 leaves no room under HRmax.
        XCTAssertNil(HRZones.validatedEdges(lowerPercents: [0.5, 0.6, 0.7, 0.8, 1.0]))
    }

    func testCustomZonesPartitionContiguouslyAndBucketCorrectly() {
        let edges = HRZones.validatedEdges(lowerPercents: [0.55, 0.65, 0.75, 0.85, 0.92])!
        let zs = HRZones.zones(maxHR: 200, edges: edges, source: "custom")
        XCTAssertEqual(zs.source, "custom")
        // bpm bounds: 110 / 130 / 150 / 170 / 184 / 200
        for i in 0..<4 {
            XCTAssertEqual(zs.zones[i].upper, zs.zones[i + 1].lower, accuracy: 1e-9)
        }
        XCTAssertEqual(zs.zoneNumber(forBPM: 109), 0)   // below the raised zone-1 floor
        XCTAssertEqual(zs.zoneNumber(forBPM: 110), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 129), 1)   // still z1 where the default set said z2
        XCTAssertEqual(zs.zoneNumber(forBPM: 130), 2)
        XCTAssertEqual(zs.zoneNumber(forBPM: 184), 5)
        XCTAssertEqual(zs.zoneNumber(forBPM: 200), 5)   // top edge inclusive
    }

    /// A band boundary must land in its OWN zone even when `pct × maxHR` doesn't divide cleanly in
    /// binary (0.55 × 200 = 110.000000000000014). Before `edgeEpsilon`, exactly 110 bpm read as "below
    /// Zone 1" on this band set — invisible on the round-tens default, routine on a user-set one.
    func testBandBoundaryLandsInItsOwnZoneDespiteBinaryRounding() {
        let edges = HRZones.validatedEdges(lowerPercents: [0.55, 0.65, 0.75, 0.85, 0.92])!
        let zs = HRZones.zones(maxHR: 200, edges: edges)
        XCTAssertGreaterThan(zs.zones[0].lower, 110.0, "precondition: the bound is fp-above 110")
        // Each boundary belongs to the zone it opens, and only to that one.
        XCTAssertEqual(zs.zoneNumber(forBPM: 110), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 130), 2)
        XCTAssertEqual(zs.zoneNumber(forBPM: 150), 3)
        XCTAssertEqual(zs.zoneNumber(forBPM: 170), 4)
        XCTAssertEqual(zs.zoneNumber(forBPM: 184), 5)
    }

    /// A stored value that somehow isn't six edges must fall back to the default bands rather than
    /// render a partial set — a readout with four zones would be worse than an un-customised one.
    func testMalformedEdgeCountFallsBackToDefault() {
        let zs = HRZones.zones(maxHR: 200, edges: [0.5, 0.6, 0.7])
        XCTAssertEqual(zs.zones.count, 5)
        XCTAssertEqual(zs.zones[0].lower, 100.0, accuracy: 1e-9)
    }

    // MARK: - HRZoneEdges wire form

    func testEncodeDecodeRoundTrips() {
        let edges = HRZones.validatedEdges(lowerPercents: [0.55, 0.65, 0.75, 0.85, 0.92])!
        let raw = HRZoneEdges.encode(edges)
        XCTAssertEqual(raw, "55,65,75,85,92")
        XCTAssertEqual(HRZoneEdges.decode(raw), edges)
    }

    /// Half-percent bounds must survive the round trip, and must NOT pick up a locale's decimal comma —
    /// this string travels in a `.noopbak` between devices.
    func testEncodeKeepsHalvesAndStaysPOSIX() {
        let edges = HRZones.validatedEdges(lowerPercents: [0.505, 0.625, 0.75, 0.85, 0.925])!
        let raw = HRZoneEdges.encode(edges)
        XCTAssertEqual(raw, "50.5,62.5,75,85,92.5")
        let back = HRZoneEdges.decode(raw)!
        for (a, b) in zip(back, edges) { XCTAssertEqual(a, b, accuracy: 1e-9) }
    }

    /// The default set encodes to "" so "not customised" is stored as absence, never as a literal to
    /// keep in sync with `zoneEdges`.
    func testDefaultEncodesToEmpty() {
        XCTAssertEqual(HRZoneEdges.encode(HRZones.zoneEdges), "")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(HRZoneEdges.decode(""))
        XCTAssertNil(HRZoneEdges.decode("50,60,70,80"))          // too few
        XCTAssertNil(HRZoneEdges.decode("50,60,70,80,90,95"))    // too many
        XCTAssertNil(HRZoneEdges.decode("50,60,seventy,80,90"))  // not numeric
        XCTAssertNil(HRZoneEdges.decode("90,80,70,60,50"))       // descending
        XCTAssertNil(HRZoneEdges.decode("50,5,62,5,75"))         // a locale-comma decimal, split apart
    }

    func testDecodeToleratesWhitespace() {
        XCTAssertEqual(HRZoneEdges.decode(" 55 , 65 , 75 , 85 , 92 "),
                       [0.55, 0.65, 0.75, 0.85, 0.92, 1.0])
    }

    // MARK: - Absolute (bpm) bands

    func testValidatedBpmEdgesAcceptsALegalSet() {
        let edges = HRZones.validatedBpmEdges(lowerBpm: [110, 130, 150, 170, 184], maxHR: 200)
        XCTAssertEqual(edges, [110, 130, 150, 170, 184, 200])
    }

    func testValidatedBpmEdgesRejectsIllegalSets() {
        XCTAssertNil(HRZones.validatedBpmEdges(lowerBpm: [110, 130, 150, 170], maxHR: 200))
        XCTAssertNil(HRZones.validatedBpmEdges(lowerBpm: [30, 130, 150, 170, 184], maxHR: 200))
        XCTAssertNil(HRZones.validatedBpmEdges(lowerBpm: [110, 130, 120, 170, 184], maxHR: 200))
        // The top band must leave room under HRmax, or Zone 5 is empty and the maximum unreachable.
        XCTAssertNil(HRZones.validatedBpmEdges(lowerBpm: [110, 130, 150, 170, 200], maxHR: 200))
        XCTAssertNil(HRZones.validatedBpmEdges(lowerBpm: [110, 130, 150, 170, 184], maxHR: 0))
    }

    /// In bpm mode the heart rates are the truth and the percentages are derived — the reverse of the
    /// percent mode. Both are reported, because the coach and the editor speak in both.
    func testBpmZonesDeriveTheirPercentages() {
        let edges = HRZones.validatedBpmEdges(lowerBpm: [110, 130, 150, 170, 184], maxHR: 200)!
        let zs = HRZones.zones(bpmEdges: edges, maxHR: 200)
        XCTAssertEqual(zs.source, "custom-bpm")
        XCTAssertEqual(zs.zones[0].lower, 110, accuracy: 1e-9)
        XCTAssertEqual(zs.zones[0].lowerPct, 0.55, accuracy: 1e-9)
        XCTAssertEqual(zs.zones[4].upper, 200, accuracy: 1e-9)
        XCTAssertEqual(zs.zones[4].upperPct, 1.0, accuracy: 1e-9)
        XCTAssertEqual(zs.zoneNumber(forBPM: 110), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 129), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 130), 2)
        XCTAssertEqual(zs.zoneNumber(forBPM: 200), 5)
    }

    // MARK: - Config resolution

    func testAutoConfigMatchesTheUncustomisedZones() {
        let zs = HRZones.zones(config: .auto, maxHR: 187, autoSource: "tanaka")
        XCTAssertEqual(zs.source, "tanaka")
        XCTAssertEqual(zs.zones, HRZones.zones(maxHR: 187).zones)
    }

    func testPercentAndBpmConfigsResolveToTheirOwnBands() {
        let percent = HRZoneConfig(mode: .percent, percentLowerBounds: [0.55, 0.65, 0.75, 0.85, 0.92])
        let pz = HRZones.zones(config: percent, maxHR: 200)
        XCTAssertEqual(pz.source, "custom-percent")
        XCTAssertEqual(pz.zones[0].lower, 110, accuracy: 1e-9)

        let bpm = HRZoneConfig(mode: .bpm, bpmLowerBounds: [100, 120, 140, 160, 180])
        let bz = HRZones.zones(config: bpm, maxHR: 200)
        XCTAssertEqual(bz.source, "custom-bpm")
        XCTAssertEqual(bz.zones[0].lower, 100, accuracy: 1e-9)
    }

    /// The two modes hold different quantities: percent bounds follow HRmax, bpm bounds stay put. That
    /// difference is the entire reason both exist, so it gets pinned.
    func testPercentBandsFollowHrMaxWhileBpmBandsStayPut() {
        let percent = HRZoneConfig(mode: .percent, percentLowerBounds: [0.55, 0.65, 0.75, 0.85, 0.92])
        let bpm = HRZoneConfig(mode: .bpm, bpmLowerBounds: [110, 130, 150, 170, 184])

        XCTAssertEqual(HRZones.zones(config: percent, maxHR: 200).zones[0].lower, 110, accuracy: 1e-9)
        XCTAssertEqual(HRZones.zones(config: percent, maxHR: 190).zones[0].lower, 104.5, accuracy: 1e-9)

        XCTAssertEqual(HRZones.zones(config: bpm, maxHR: 200).zones[0].lower, 110, accuracy: 1e-9)
        XCTAssertEqual(HRZones.zones(config: bpm, maxHR: 190).zones[0].lower, 110, accuracy: 1e-9)
    }

    /// A stored config whose bounds no longer validate must degrade to the conventional bands, not to a
    /// broken partition — and `isCustom` must agree with what the resolver actually did, so the UI can't
    /// claim a customisation the zones don't honour.
    func testInvalidConfigDegradesToAutoAndIsNotReportedAsCustom() {
        let broken = HRZoneConfig(mode: .percent, percentLowerBounds: [0.9, 0.6, 0.7, 0.8, 0.5])
        let zs = HRZones.zones(config: broken, maxHR: 200, autoSource: "tanaka")
        XCTAssertEqual(zs.source, "tanaka")
        XCTAssertEqual(zs.zones[0].lower, 100, accuracy: 1e-9)
        XCTAssertFalse(broken.isCustom(maxHR: 200))

        // A bpm set that is legal on one HRmax and illegal on another is custom only where it holds.
        let bpm = HRZoneConfig(mode: .bpm, bpmLowerBounds: [110, 130, 150, 170, 184])
        XCTAssertTrue(bpm.isCustom(maxHR: 200))
        XCTAssertFalse(bpm.isCustom(maxHR: 180))
        XCTAssertEqual(HRZones.zones(config: bpm, maxHR: 180).source, "manual")
    }

    func testEncodeValuesRoundTripsRawBpmBounds() {
        let raw = HRZoneEdges.encodeValues([110, 130, 150, 170, 184])
        XCTAssertEqual(raw, "110,130,150,170,184")
        XCTAssertEqual(HRZoneEdges.decodeValues(raw), [110, 130, 150, 170, 184])
        XCTAssertEqual(HRZoneEdges.encodeValues([Double]()), "")
        XCTAssertNil(HRZoneEdges.decodeValues(""))
    }
}

import XCTest
@testable import WhoopProtocol

/// Device-family-aware skin-temp raw→°C conversion (#938).
///
/// The historical `skin_temp_raw` register is on DIFFERENT scales per family: a CENTIDEGREE value on the
/// 5/MG v18 (@73) but a RAW ADC on the WHOOP 4.0 v24 (@72). A single family-blind `raw/100` sent every
/// 4.0 night ~8 °C low, below the 28 °C worn gate, so skin temp + the illness signal vanished (issue
/// #938, reporter dpguglielmi's 4.0 capture: worn steady raw ~826, no-contact floor ~510). These tests
/// pin the two scales so a regression that unifies them fails loudly.
final class SkinTempConversionTests: XCTestCase {

    // MARK: - WHOOP 5/MG (unchanged: raw/100 centidegrees)

    /// The proven 5/MG scale: the real Whoop5HistoricalTests captures read worn 3057 = 30.6 °C and
    /// off-wrist 2247 = 22.5 °C — physically right on both ends. This must NOT change.
    func testWhoop5IsUnchangedCentidegrees() {
        XCTAssertEqual(skinTempCelsius(raw: 3057, family: .whoop5), 30.57, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 2247, family: .whoop5), 22.47, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 3400, family: .whoop5), 34.0, accuracy: 1e-9)
    }

    // MARK: - WHOOP 4.0 v24 (raw ADC map)

    /// The reporter's steady WORN 4.0 baseline (raw ~826, worn steady ~830–865) must land in the plausible
    /// worn skin-temp band (28–42 °C) — the whole point of the fix. Under the OLD /100 scale these read
    /// ~8.3 °C and every 4.0 night was dropped.
    func testWhoop4WornBaselineLandsInPlausibleBand() {
        for raw in [826, 830, 845, 859, 865] {
            let c = skinTempCelsius(raw: raw, family: .whoop4)
            XCTAssertGreaterThanOrEqual(c, 28.0, "worn 4.0 raw \(raw) → \(c) °C must clear the 28 °C worn gate")
            XCTAssertLessThanOrEqual(c, 42.0, "worn 4.0 raw \(raw) → \(c) °C must stay under the 42 °C worn ceiling")
        }
        // The anchor itself is the pinned worn skin temperature.
        XCTAssertEqual(skinTempCelsius(raw: 826, family: .whoop4), 33.0, accuracy: 1e-9)
    }

    /// The no-contact floor (raw ~510–520, seen at doff) is NOT a worn value; it must read BELOW the 28 °C
    /// worn gate so it is excluded from the nightly mean rather than poisoning it.
    func testWhoop4NoContactFloorIsBelowWornGate() {
        for raw in [506, 514, 520] {
            XCTAssertLessThan(skinTempCelsius(raw: raw, family: .whoop4), 28.0,
                              "4.0 no-contact floor raw \(raw) must fall below the worn gate")
        }
    }

    /// The 4.0 scale is DIFFERENT from the 5/MG scale for the same register value — a regression that reuses
    /// /100 for a 4.0 would collapse these to equal and fail here.
    func testWhoop4AndWhoop5DifferForTheSameRaw() {
        XCTAssertNotEqual(skinTempCelsius(raw: 826, family: .whoop4),
                          skinTempCelsius(raw: 826, family: .whoop5), accuracy: 1e-6)
    }

    /// The synthetic HistoricalV24Tests fixture banks skin_temp_raw = 900; under the family-aware map it is a
    /// plausible worn reading (was an impossible 9 °C under the old /100).
    func testWhoop4SyntheticFixtureRawIsPlausible() {
        let c = skinTempCelsius(raw: 900, family: .whoop4)
        XCTAssertGreaterThan(c, 28.0)
        XCTAssertLessThan(c, 42.0)
    }

    // MARK: - per-device worn anchor (#938 second capture)
    // The @72 ADC's register offset is per-device: a second real 4.0 strap shares the floor (~509) +
    // saturation (2047) but a worn band ~1100–1600 (nightly mean raw ~1290). The anchor is learned from the
    // device's OWN worn median so the worn band lands in range; the offset cancels in skinTempDevC.

    /// Odd count: the anchor is the middle in-band raw.
    func testDeviceAnchorRawIsMedianOfInBandRaws() throws {
        let raws = Array(1250...1350) // 101 in-band values, median is the middle one (1300)
        XCTAssertEqual(raws.count, 101)
        XCTAssertEqual(try XCTUnwrap(Whoop4SkinTemp.deviceAnchorRaw(raws)), 1300.0, accuracy: 1e-9)
    }

    /// The no-contact floor (509) and 11-bit saturation (2047) are filtered out of the anchor median entirely.
    func testDeviceAnchorRawExcludesFloorAndSaturation() throws {
        let worn = Array(repeating: 1290, count: 100)                       // 100 real worn raws
        let contaminated = worn + Array(repeating: 509, count: 40) + Array(repeating: 2047, count: 40)
        // Only the 100 in-band 1290s survive the band filter → median 1290 (floor/ceiling never enter the sort).
        XCTAssertEqual(try XCTUnwrap(Whoop4SkinTemp.deviceAnchorRaw(contaminated)), 1290.0, accuracy: 1e-9)
    }

    /// Fewer than `minAnchorSamples` in-band raws → nil, so the caller falls back to the global anchor.
    func testDeviceAnchorRawNilBelowMinSamples() throws {
        XCTAssertEqual(Whoop4SkinTemp.minAnchorSamples, 100)
        XCTAssertNil(Whoop4SkinTemp.deviceAnchorRaw(Array(repeating: 1290, count: 99)))           // 99 < 100
        XCTAssertEqual(try XCTUnwrap(Whoop4SkinTemp.deviceAnchorRaw(Array(repeating: 1290, count: 100))),
                       1290.0, accuracy: 1e-9)                                                     // exactly 100
    }

    /// Even count: the anchor averages the two middle in-band raws.
    func testDeviceAnchorRawEvenCountAveragesMiddleTwo() throws {
        let raws = Array(1201...1300) // 100 values, middle two are 1250 and 1251
        XCTAssertEqual(raws.count, 100)
        XCTAssertEqual(try XCTUnwrap(Whoop4SkinTemp.deviceAnchorRaw(raws)), 1250.5, accuracy: 1e-9)
    }

    /// The learned per-device anchor raw maps to 33.0 °C, and +20 raw above it is +1.0 °C (slope 0.05); the
    /// anchor is ignored on `.whoop5`.
    func testWhoop4PerDeviceAnchorMapsToAnchorCelsius() {
        XCTAssertEqual(skinTempCelsius(raw: 1290, family: .whoop4, anchorRaw: 1290.0), 33.0, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 1310, family: .whoop4, anchorRaw: 1290.0), 34.0, accuracy: 1e-9)
        XCTAssertEqual(skinTempCelsius(raw: 3400, family: .whoop5, anchorRaw: 1290.0), 34.0, accuracy: 1e-9)
    }

    /// Omitting `anchorRaw` uses the global `anchorRaw` (826) → byte-identical to the pre-per-device behaviour.
    func testWhoop4DefaultAnchorIsGlobal826() {
        XCTAssertEqual(skinTempCelsius(raw: 859, family: .whoop4, anchorRaw: Whoop4SkinTemp.anchorRaw),
                       skinTempCelsius(raw: 859, family: .whoop4), accuracy: 1e-12)
        XCTAssertEqual(skinTempCelsius(raw: 826, family: .whoop4), 33.0, accuracy: 1e-9)
    }
}

import XCTest
import SwiftUI
@testable import StrandDesign

/// `ChargeBand` is the ONE definition of what a Charge score means. Before it, the codebase carried
/// three competing answers (the gradient stop locations, the state-word thresholds, and WHOOP's 33/66),
/// so a value-coloured ring and the word beside it could disagree about the same number.
///
/// These pin the THRESHOLDS, never the colour: a SwiftUI `Color` wraps a dynamic catalog colour in a
/// fresh provider per access, so two reads of one palette token are not `==` and an assertion on the
/// colour would compare identities instead of the banding it means to check. That lesson is already
/// written down at `ChargeSyncIndicator.chargeBand(_:)`; this follows it.
final class ChargeBandTests: XCTestCase {

    /// The bands must stay on the values that SHIPPED (25 / 50 / 70 / 88). Moving them to WHOOP's
    /// 33/66 would silently change what the already-translated DEPLETED…PEAK words, and the Charge
    /// explanation that quotes them, actually mean.
    func testShippedThresholdsAreUnchanged() {
        XCTAssertEqual(ChargeBand.of(score: 0), .depleted)
        XCTAssertEqual(ChargeBand.of(score: 24.9), .depleted)
        XCTAssertEqual(ChargeBand.of(score: 30), .low)
        XCTAssertEqual(ChargeBand.of(score: 49.9), .low)
        XCTAssertEqual(ChargeBand.of(score: 62), .moderate)
        XCTAssertEqual(ChargeBand.of(score: 69.9), .moderate)
        XCTAssertEqual(ChargeBand.of(score: 71), .primed)
        XCTAssertEqual(ChargeBand.of(score: 87.9), .primed)
        XCTAssertEqual(ChargeBand.of(score: 91), .peak)
        XCTAssertEqual(ChargeBand.of(score: 100), .peak)
    }

    /// A boundary belongs to the band ABOVE it, matching the `..<` cases the state words shipped with.
    /// Pinned explicitly because this is exactly the kind of off-by-one that silently reclassifies a
    /// score when someone later "tidies" the switch.
    func testBoundaryValuesBelongToTheHigherBand() {
        XCTAssertEqual(ChargeBand.of(score: 25), .low)
        XCTAssertEqual(ChargeBand.of(score: 50), .moderate)
        XCTAssertEqual(ChargeBand.of(score: 70), .primed)
        XCTAssertEqual(ChargeBand.of(score: 88), .peak)
    }

    /// Out-of-range input must still land somewhere sane rather than trapping — the score is a computed
    /// value and nothing upstream guarantees it is clamped.
    func testOutOfRangeScoresStillResolve() {
        XCTAssertEqual(ChargeBand.of(score: -12), .depleted)
        XCTAssertEqual(ChargeBand.of(score: 140), .peak)
    }

    /// The bands are ordered as the score rises, and every case is reachable from a real score — a
    /// `CaseIterable` sweep so a band added later cannot sit unreachable behind a threshold gap.
    func testEveryBandIsReachableAndOrdered() {
        let reached = stride(from: 0.0, through: 100.0, by: 0.5).map { ChargeBand.of(score: $0) }
        XCTAssertEqual(Set(reached).count, ChargeBand.allCases.count,
                       "every band must be reachable from some score in 0...100")
        // The sequence must only ever step FORWARD through the ladder as the score rises.
        let ladder = ChargeBand.allCases
        var index = 0
        for band in reached {
            guard let at = ladder.firstIndex(of: band) else { return XCTFail("unknown band \(band)") }
            XCTAssertGreaterThanOrEqual(at, index, "bands must not go backwards as the score rises")
            index = at
        }
    }

    /// `recoveryState(_:)` is now a thin forwarder onto the band, so the ring's colour, its word and any
    /// later tone can never drift apart. This pins that it still answers exactly as before.
    func testRecoveryStateForwardsToTheBandWord() {
        for score in stride(from: 0.0, through: 100.0, by: 0.5) {
            XCTAssertEqual(StrandPalette.recoveryState(score), ChargeBand.of(score: score).word)
        }
    }

    /// Each band has its own distinct word — a duplicate would make two different states read the same
    /// on a ring that has only the word and the colour to tell them apart.
    func testBandWordsAreDistinct() {
        let words = ChargeBand.allCases.map(\.word)
        XCTAssertEqual(Set(words).count, words.count, "band words must be distinct: \(words)")
    }
}

// MARK: - Discrete band colour (flat-filled rings, never a ramp blend)

/// `chargeRingColor` used to sample the CONTINUOUS `recoveryStops` ramp, whose stop locations
/// (0/.30/.55/.78/1.00) were never reconciled with `ChargeBand`'s own thresholds (25/50/70/88). A score
/// of 51 read "MODERATE" in text but rendered a colour blended BETWEEN the ramp's orange and yellow
/// stops — not any style's real system colour, and not the colour the word named. These pin the fix:
/// every score in a band renders EXACTLY that band's named swatch, never an in-between.
final class ChargeBandColorTests: XCTestCase {

    override func tearDown() {
        StrandPalette.chartStyle = .titanium
        super.tearDown()
    }

    private func rgba(_ c: Color) -> (r: Double, g: Double, b: Double, a: Double) { c.rgbaComponents }

    /// The actual bug: 51 must render the SAME swatch as 60 (both `moderate`), not a blend that leans
    /// toward whichever neighbour is nearer.
    func testScoresInTheSameBandAreIdenticalNotBlended() {
        StrandPalette.chartStyle = .health
        let low = rgba(StrandPalette.chargeRingColor(51))
        let mid = rgba(StrandPalette.chargeRingColor(60))
        let high = rgba(StrandPalette.chargeRingColor(69.9))
        XCTAssertEqual(low.r, mid.r, accuracy: 0.001)
        XCTAssertEqual(low.g, mid.g, accuracy: 0.001)
        XCTAssertEqual(low.b, mid.b, accuracy: 0.001)
        XCTAssertEqual(mid.r, high.r, accuracy: 0.001)
        XCTAssertEqual(mid.g, high.g, accuracy: 0.001)
        XCTAssertEqual(mid.b, high.b, accuracy: 0.001)
    }

    /// The ring colour must exactly match the SAME named swatch the band word implies — under every
    /// style, not only Apple Health.
    func testBandColorMatchesTheNamedSwatchForEveryStyle() {
        // `chartStyle` must be set BEFORE `chargeRingColor` is called — Swift evaluates an array
        // literal's elements eagerly, so building a `[(style, band, chargeRingColor(score))]` table up
        // front would call every `chargeRingColor` under whatever style happened to be active at that
        // moment, not the style each row claims to test. Score → style → band, computed inline instead.
        let cases: [(ChartStyle, Double, ChargeBand)] = [
            (.health, 10, .depleted),
            (.health, 60, .moderate),
            (.health, 95, .peak),
            (.classic, 35, .low),
            (.titanium, 80, .primed),
        ]
        for (style, score, band) in cases {
            StrandPalette.chartStyle = style
            let expected = rgba(StrandPalette.chargeBandColor(band))
            let got = rgba(StrandPalette.chargeRingColor(score))
            XCTAssertEqual(got.r, expected.r, accuracy: 0.001, "\(style)/\(band)")
            XCTAssertEqual(got.g, expected.g, accuracy: 0.001, "\(style)/\(band)")
            XCTAssertEqual(got.b, expected.b, accuracy: 0.001, "\(style)/\(band)")
        }
    }

    /// The five bands must resolve to five VISUALLY DISTINCT swatches under Apple Health — collapsing
    /// two bands onto the same colour would silently make one of the five words meaningless.
    func testAllFiveBandsAreDistinctUnderHealth() {
        StrandPalette.chartStyle = .health
        let swatches = ChargeBand.allCases.map { rgba(StrandPalette.chargeBandColor($0)) }
        for i in 0..<swatches.count {
            for j in (i + 1)..<swatches.count {
                let a = swatches[i], b = swatches[j]
                let collides = abs(a.r - b.r) < 0.02 && abs(a.g - b.g) < 0.02 && abs(a.b - b.b) < 0.02
                XCTAssertFalse(collides, "\(ChargeBand.allCases[i]) and \(ChargeBand.allCases[j]) collide")
            }
        }
    }

    /// Every chart style must resolve every band to SOME real colour — no style silently falls through
    /// to a default that was never given its own five swatches.
    func testEveryStyleResolvesEveryBand() {
        for style in ChartStyle.allCases {
            StrandPalette.chartStyle = style
            for band in ChargeBand.allCases {
                _ = StrandPalette.chargeBandColor(band).rgbaComponents  // must not trap
            }
        }
    }
}

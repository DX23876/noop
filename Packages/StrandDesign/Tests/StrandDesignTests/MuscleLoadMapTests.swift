import XCTest
@testable import StrandDesign

/// Pins the load banding.
///
/// The BAND is what is asserted, never the colour. A SwiftUI `Color` wraps a dynamic catalog colour in
/// a fresh provider per access, so two reads of one palette token are not `==` and a colour assertion
/// would compare identities rather than the banding it means to check — the same lesson `ChargeBand`
/// records.
final class MuscleLoadMapTests: XCTestCase {

    func testBandsFollowTheWearersOwnUsual() {
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 0), .none)
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 0.2), .light)
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 0.7), .building)
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 1.0), .usual, "1.0 IS the wearer's usual")
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 2.0), .wellAbove)
    }

    /// A muscle with no work is `.none`, not a faint version of `.light`. "A little work" and "no work"
    /// must not look alike.
    func testAnUntrainedMuscleIsItsOwnBandNotAFaintOne() {
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 0), .none)
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 0.0005), .none,
                       "a rounding crumb is still nothing")
        XCTAssertEqual(MuscleLoadMap.Level.of(load: 0.01), .light)
    }

    /// The ramp has to run one way. It previously did not: built from `statusWarning` and
    /// `metricAmber` in that order it ran backwards in the default palette, because those tokens are
    /// yellow and orange respectively — and in four other chart styles they are the same colour, which
    /// collapsed two of the four steps. Sampling the recovery gradient fixes both, and this pins that
    /// the bands stay ordered so a future edit cannot reintroduce either.
    func testTheBandsAreOrderedByHowMuchLoadTheyMean() {
        let ascending = [0.1, 0.6, 1.0, 2.5].map { MuscleLoadMap.Level.of(load: $0) }
        XCTAssertEqual(ascending, [.light, .building, .usual, .wellAbove])
        XCTAssertEqual(ascending.map(\.rawValue).sorted(), ascending.map(\.rawValue),
                       "raw values ascend with load, so ordering comparisons stay meaningful")
    }

    /// Every band says what it means in words. The colour alone is read as a verdict.
    func testEveryBandCarriesALabel() {
        for level in MuscleLoadMap.Level.allCases {
            XCTAssertFalse(level.label.isEmpty, "\(level) has no label")
        }
    }

    /// Every region the map can be asked to shade has artwork, on at least one face — a region with no
    /// outline would silently draw nothing for work that was done. Obliques and shins are drawn on the
    /// front, from shapes the source artwork always had but that used to be filed as plain silhouette.
    func testEveryRegionHasArtwork() {
        var drawn = Set<MuscleLoadMap.Region>()
        for face in MuscleLoadMap.Face.allCases {
            drawn.formUnion(MuscleMapArt.shared[face].regions.map(\.region))
        }
        XCTAssertEqual(drawn, Set(MuscleLoadMap.Region.allCases))
        let front = MuscleMapArt.shared[.front].regions.map(\.region)
        XCTAssertEqual(front.filter { $0 == .obliques }.count, 16)
        XCTAssertEqual(front.filter { $0 == .shins }.count, 2)
    }
}

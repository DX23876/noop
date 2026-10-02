import XCTest
@testable import StrandDesign

final class NoopCardChromeTests: XCTestCase {
    private func chrome(_ kind: NoopCardKind, light: Bool = true, transparent: Bool = false,
                        contrast: Bool = false, quiet: Bool = true) -> NoopCardChrome {
        NoopCardChrome.resolve(kind: kind, isLight: light, isTransparent: transparent,
                               increasedContrast: contrast, quietEdges: quiet)
    }

    func testLightSolidDataCardHasNoRimButAShadow() {
        XCTAssertEqual(chrome(.data), NoopCardChrome(rim: .none, shadow: true))
        XCTAssertEqual(chrome(.hero), NoopCardChrome(rim: .none, shadow: true))
    }

    func testLightSolidNavigationCardHasNeitherRimNorShadow() {
        XCTAssertEqual(chrome(.navigation), NoopCardChrome(rim: .none, shadow: false))
    }

    func testDarkKeepsItsHairlineAndStaysFlat() {
        for kind in [NoopCardKind.data, .hero] {
            XCTAssertEqual(chrome(kind, light: false), NoopCardChrome(rim: .hairline, shadow: false))
        }
        XCTAssertEqual(chrome(.navigation, light: false), NoopCardChrome(rim: .none, shadow: false))
    }

    func testTransparentLightCardsGetAHairlineSoTheEdgeSurvives() {
        XCTAssertEqual(chrome(.data, transparent: true).rim, .hairline)
        XCTAssertEqual(chrome(.hero, transparent: true).rim, .hairline)
        XCTAssertEqual(chrome(.navigation, transparent: true).rim, .hairline)
    }

    func testIncreasedContrastStrengthensTheEdgeOfEveryNeutralKind() {
        for light in [true, false] {
            for kind in [NoopCardKind.navigation, .data, .hero] {
                XCTAssertEqual(chrome(kind, light: light, contrast: true),
                               NoopCardChrome(rim: .strong, shadow: false))
            }
        }
    }

    func testStateCardsAlwaysCarryATintedRimAndNoShadow() {
        for light in [true, false] {
            for transparent in [true, false] {
                XCTAssertEqual(chrome(.state, light: light, transparent: transparent),
                               NoopCardChrome(rim: .tinted, shadow: false))
            }
            XCTAssertEqual(chrome(.state, light: light, contrast: true),
                           NoopCardChrome(rim: .tintedStrong, shadow: false))
        }
    }

    func testOtherPlatformsKeepTheOriginalHairlineAndLightShadowExceptNavigation() {
        XCTAssertEqual(chrome(.navigation, quiet: false), NoopCardChrome(rim: .none, shadow: false))
        for kind in NoopCardKind.allCases where kind != .navigation {
            XCTAssertEqual(chrome(kind, light: true, quiet: false), NoopCardChrome(rim: .hairline, shadow: true))
            XCTAssertEqual(chrome(kind, light: false, quiet: false), NoopCardChrome(rim: .hairline, shadow: false))
        }
    }

    func testNoNeutralKindEverGetsATintedRim() {
        for kind in [NoopCardKind.navigation, .data, .hero] {
            for light in [true, false] {
                for transparent in [true, false] {
                    for contrast in [true, false] {
                        let rim = chrome(kind, light: light, transparent: transparent, contrast: contrast).rim
                        XCTAssertFalse(rim == .tinted || rim == .tintedStrong)
                    }
                }
            }
        }
    }

    func testQuietRimsDropOnlyTheRestingHairlineOfOpaqueCards() {
        func chrome(_ kind: NoopCardKind, light: Bool = false, transparent: Bool = false,
                    contrast: Bool = false, quiet: Bool = true) -> NoopCardChrome {
            NoopCardChrome.resolve(kind: kind, isLight: light, isTransparent: transparent,
                                   increasedContrast: contrast, quietEdges: true, quietRims: quiet)
        }
        XCTAssertEqual(chrome(.data, quiet: false).rim, .hairline, "the default is unchanged")
        XCTAssertEqual(chrome(.data).rim, .none)
        XCTAssertEqual(chrome(.hero).rim, .none)
        XCTAssertEqual(chrome(.data, transparent: true).rim, .hairline, "a see-through card keeps its edge")
        XCTAssertEqual(chrome(.data, contrast: true).rim, .strong, "Increase Contrast keeps every edge")
        XCTAssertEqual(chrome(.state).rim, .tinted, "a state card keeps its signal")
        XCTAssertEqual(chrome(.data, light: true).shadow, true, "light cards keep their lift")
    }
}

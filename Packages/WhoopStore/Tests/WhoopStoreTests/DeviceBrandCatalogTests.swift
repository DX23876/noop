import XCTest
@testable import WhoopStore

/// Pins the pure brand catalog: recognition, ordering, and the byte-parity facts (sourceKind / idPrefix /
/// capability / tier). The Kotlin twin `DeviceBrandCatalogTest` must assert the SAME cases so the two
/// platforms recognise a device identically.
final class DeviceBrandCatalogTests: XCTestCase {

    func testRecognisesEachBrandFromAdvertisedName() {
        let cases: [(String, String)] = [
            ("Amazfit Helio Ring", "Amazfit"),
            ("Zepp E", "Amazfit"),
            ("Mi Smart Band 8", "Mi Band"),
            ("Xiaomi Band 9", "Mi Band"),
            ("Garmin Forerunner 265", "Garmin"),
            ("fēnix 7", "Garmin"),                 // diacritic-folded to "fenix"
            ("HRM-Pro", "Garmin"),
            ("Oura Ring", "Oura"),
            ("Polar H10", "Polar"),
            ("Wahoo TICKR", "Wahoo"),
            ("COOSPO HW9", "Coospo"),
            ("Scosche Rhythm+", "Scosche"),
            ("Magene H64", "Magene"),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(DeviceBrandCatalog.spec(forAdvertisedName: name)?.brand, expected, "name=\(name)")
        }
    }

    func testUnknownNameIsNil() {
        XCTAssertNil(DeviceBrandCatalog.spec(forAdvertisedName: "Acme HR 3000"))
        XCTAssertNil(DeviceBrandCatalog.spec(forAdvertisedName: ""))
    }

    /// Mi Band is a Huami sub-brand: its tokens must win over the broader Amazfit family so a "Smart Band"
    /// never mis-labels as Amazfit. Order in `all` guarantees this.
    func testMiBandWinsOverAmazfit() {
        XCTAssertEqual(DeviceBrandCatalog.spec(forAdvertisedName: "Mi Band")?.brand, "Mi Band")
        XCTAssertEqual(DeviceBrandCatalog.spec(forAdvertisedName: "Smart Band 10")?.brand, "Mi Band")
    }

    func testRoutingAndTierFacts() {
        func spec(_ brand: String) -> DeviceBrandSpec {
            guard let s = DeviceBrandCatalog.spec(forBrand: brand) else {
                XCTFail("missing catalog row for \(brand)"); return DeviceBrandCatalog.all[0]
            }
            return s
        }
        // Experimental custom-protocol sources route to their own driver kinds.
        XCTAssertEqual(spec("Amazfit").sourceKind, .huami)
        XCTAssertEqual(spec("Mi Band").sourceKind, .huami)
        XCTAssertEqual(spec("Oura").sourceKind, .oura)
        // Garmin + generic straps are standard 0x180D live-BLE (no proprietary protocol).
        XCTAssertEqual(spec("Garmin").sourceKind, .liveBLE)
        XCTAssertEqual(spec("Polar").sourceKind, .liveBLE)
        // id prefixes match the wizard's registration.
        XCTAssertEqual(spec("Amazfit").idPrefix, "huami")
        XCTAssertEqual(spec("Oura").idPrefix, "oura")
        XCTAssertEqual(spec("Garmin").idPrefix, "garmin")
        XCTAssertEqual(spec("Polar").idPrefix, "strap")
        // Honest capability: Oura has no open live stream; everyone else here does.
        XCTAssertFalse(spec("Oura").canStreamLiveHR)
        XCTAssertTrue(spec("Amazfit").canStreamLiveHR)
        XCTAssertTrue(spec("Garmin").canStreamLiveHR)
        XCTAssertTrue(spec("Polar").canStreamLiveHR)
        // Tier: the four experimental brands are the opt-in tier; generic straps are not.
        for b in ["Amazfit", "Mi Band", "Garmin", "Oura"] { XCTAssertTrue(spec(b).isExperimentalTier, b) }
        for b in ["Polar", "Wahoo", "Coospo", "Scosche", "Magene"] { XCTAssertFalse(spec(b).isExperimentalTier, b) }
    }

    /// Brand strings are unique (the reverse lookup `spec(forBrand:)` and the `ExperimentalBrand` bridge
    /// both assume it).
    func testBrandStringsUnique() {
        let brands = DeviceBrandCatalog.all.map(\.brand)
        XCTAssertEqual(Set(brands).count, brands.count)
    }
}

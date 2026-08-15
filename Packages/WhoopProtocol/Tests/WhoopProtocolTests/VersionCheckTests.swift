import XCTest
@testable import WhoopProtocol

/// Pins the version comparison behind "Check for updates" — headline being the string-compare trap
/// (`1.40` > `1.39`, `1.10` > `1.9`), plus the demo suffix and a leading "v".
final class VersionCheckTests: XCTestCase {

    func testNewer() {
        XCTAssertTrue(VersionCheck.isNewer("1.40", than: "1.39"))   // the trap: "1.40" < "1.39" as strings
        XCTAssertTrue(VersionCheck.isNewer("1.10", than: "1.9"))    // and "1.10" < "1.9" as strings
        XCTAssertTrue(VersionCheck.isNewer("2.0", than: "1.39"))
        XCTAssertTrue(VersionCheck.isNewer("1.39.1", than: "1.39"))
        XCTAssertTrue(VersionCheck.isNewer("v1.40", than: "1.39"))
    }

    func testNotNewer() {
        XCTAssertFalse(VersionCheck.isNewer("1.39", than: "1.39"))      // equal
        XCTAssertFalse(VersionCheck.isNewer("1.38", than: "1.39"))
        XCTAssertFalse(VersionCheck.isNewer("1.9", than: "1.10"))
        XCTAssertFalse(VersionCheck.isNewer("1.39-demo", than: "1.39"))
        XCTAssertFalse(VersionCheck.isNewer("garbage", than: "1.39"))   // unparseable → no false alarm
    }

    /// What the update sheet PRINTS. The fork's release tags carry a `-dx` marker so they cannot collide
    /// with upstream's `vX.Y.Z` in the tag namespace this repo fetches from; it is a fact about the tag,
    /// and showing it made the app look like a side flavour of itself ("10.1.0-dx-beta is available").
    func testDisplayVersionKeepsOnlyTheNumericCore() {
        XCTAssertEqual(VersionCheck.displayVersion("v10.1.0-dx"), "10.1.0")
        XCTAssertEqual(VersionCheck.displayVersion("v9.3.3-dx-beta"), "9.3.3")
        XCTAssertEqual(VersionCheck.displayVersion("10.1.0"), "10.1.0")
        XCTAssertEqual(VersionCheck.displayVersion("V10.1"), "10.1")
    }

    /// A trailing separator is not part of a version number, and an unexpected tag still shows something
    /// rather than an empty string beside "is available".
    func testDisplayVersionDegradesGracefully() {
        XCTAssertEqual(VersionCheck.displayVersion("v10.-rc1"), "10")
        XCTAssertEqual(VersionCheck.displayVersion("vnightly"), "nightly")
        XCTAssertEqual(VersionCheck.displayVersion("  v10.1.0-dx  "), "10.1.0")
    }

    /// The printed string and the comparison must never disagree: a tag that shows as "10.1.0" has to
    /// compare as 10.1.0 too.
    func testDisplayVersionAgreesWithTheComparison() {
        let tag = "v10.1.0-dx"
        XCTAssertTrue(VersionCheck.isNewer(tag, than: "10.0.0"))
        XCTAssertTrue(VersionCheck.isNewer(VersionCheck.displayVersion(tag), than: "10.0.0"))
        XCTAssertFalse(VersionCheck.isNewer(tag, than: VersionCheck.displayVersion(tag)))
    }
}

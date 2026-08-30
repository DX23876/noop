import XCTest
@testable import WhoopStore

/// The REFUSALS matter more than the composition: adoption migrates every device-scoped row onto the id
/// this returns, so a junk serial must yield nil and leave the strap on its existing id rather than move a
/// history onto a garbage key (#1303). Kotlin twin: `WhoopSerialIdentityTest`.
final class WhoopSerialIdentityTests: XCTestCase {

    func testComposesTheSerialId() {
        XCTAssertEqual(WhoopSerialIdentity.adoptedId(serial: "5AG12345678"), "whoop-5AG12345678")
    }

    func testUpperCasesSoOneStrapCannotBecomeTwoIds() {
        XCTAssertEqual(WhoopSerialIdentity.adoptedId(serial: "5ag12345678"),
                       WhoopSerialIdentity.adoptedId(serial: "5AG12345678"))
    }

    func testTrimsSurroundingWhitespaceFromTheGattString() {
        XCTAssertEqual(WhoopSerialIdentity.adoptedId(serial: "  5AG12345678\n"), "whoop-5AG12345678")
    }

    func testRefusesBlankOrMissing() {
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: nil))
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: ""))
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "   \n "))
    }

    func testRefusesATruncatedRead() {
        // A partial GATT response must not become an id: it would collide across straps.
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "5AG"))
    }

    func testRefusesADescriptiveStringThatIsNotASerial() {
        // Some peripherals answer DIS with prose. Never let that become a device id.
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "Not Available"))
        XCTAssertNil(WhoopSerialIdentity.adoptedId(serial: "serial#1234"))
    }

    func testAlreadyAdoptedIsTheReconnectEarlyOut() {
        XCTAssertTrue(WhoopSerialIdentity.isAlreadyAdopted(id: "whoop-5AG12345678", serial: "5AG12345678"))
        XCTAssertFalse(WhoopSerialIdentity.isAlreadyAdopted(id: "whoop-ABCDEF-0123", serial: "5AG12345678"))
        // An unusable serial is never "already adopted" — otherwise a junk read would silently suppress a
        // later good one.
        XCTAssertFalse(WhoopSerialIdentity.isAlreadyAdopted(id: "whoop-5AG12345678", serial: "  "))
    }

    /// The guard that makes this safe to ship before #1304. Every existing single-WHOOP install is on the
    /// legacy `my-whoop` seed, ~47 code paths read that literal directly, and `WhoopBleClient` never
    /// reassigns its deviceId on the single-WHOOP path — so adopting it would migrate the history onto
    /// `whoop-<serial>` while new samples kept landing under `my-whoop`. A split history reads as data loss.
    func testRefusesToAdoptTheLegacySingleWhoopSeed() {
        XCTAssertFalse(WhoopSerialIdentity.mayAdopt(currentId: "my-whoop"))
        // A provisional pairing id IS adoptable — that is the multi-strap case this ships for.
        XCTAssertTrue(WhoopSerialIdentity.mayAdopt(currentId: "whoop-6B9F2C11-0000-4000-8000-0000000000AA"))
        // An already-adopted serial id stays adoptable; the equality check upstream stops the re-migration.
        XCTAssertTrue(WhoopSerialIdentity.mayAdopt(currentId: "whoop-5AG12345678"))
        // Another brand's id is never touched by the WHOOP path.
        XCTAssertFalse(WhoopSerialIdentity.mayAdopt(currentId: "oura-2H3B2405003655"))
    }

    func testLogSafeNeverLeaksTheFullSerial() {
        XCTAssertEqual(WhoopSerialIdentity.logSafe(serial: "5AG12345678"), "5AG…")
        XCTAssertEqual(WhoopSerialIdentity.logSafe(serial: nil), "?")
        XCTAssertFalse(WhoopSerialIdentity.logSafe(serial: "5AG12345678").contains("12345678"))
    }
}

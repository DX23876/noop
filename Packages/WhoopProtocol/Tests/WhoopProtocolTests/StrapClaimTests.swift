import XCTest
@testable import WhoopProtocol

/// Which strap a scan may take before the wearer has named one. The rule exists because the first
/// connect stamps the strap's address onto the WHOOP entry for good, so taking the first advertisement
/// in a two-strap household hands the entry to whichever strap spoke first.
final class StrapClaimTests: XCTestCase {

    private func strap(_ address: String, _ name: String? = nil, _ rssi: Int = -60) -> HeardStrap {
        HeardStrap(address: address, name: name, rssi: rssi)
    }

    func testOneStrapConnectsWithoutAsking() {
        let choice = StrapClaim.choose(heard: [strap("AA:11", "WHOOP 4C15")], claimed: nil)
        XCTAssertEqual(choice.verdict, .connect)
        XCTAssertEqual(choice.address, "AA:11")
        XCTAssertTrue(choice.choices.isEmpty)
    }

    func testTheSameStrapHeardSeveralTimesIsStillOneStrap() {
        let choice = StrapClaim.choose(
            heard: [strap("AA:11", nil, -70), strap("aa:11", "WHOOP 4C15", -55), strap("AA:11", nil, -80)],
            claimed: nil)
        XCTAssertEqual(choice.verdict, .connect)
        XCTAssertEqual(choice.address, "AA:11")
    }

    func testTwoStrapsAreHandedToTheWearer() {
        let choice = StrapClaim.choose(
            heard: [strap("AA:11", "WHOOP 4C15", -78), strap("BB:22", "WHOOP 9F01", -42)], claimed: nil)
        XCTAssertEqual(choice.verdict, .ask)
        XCTAssertNil(choice.address)
        // Strongest signal first: the strap on this wrist is almost always the louder one, so the
        // likeliest answer is the first row, without the list claiming to know.
        XCTAssertEqual(choice.choices.map(\.address), ["BB:22", "AA:11"])
    }

    func testNothingHeardKeepsLooking() {
        XCTAssertEqual(StrapClaim.choose(heard: [], claimed: nil).verdict, .keepLooking)
    }

    func testANamedStrapIsNeverAChoice() {
        // The entry already names BB:22. Its own neighbour being louder must not reopen the question.
        let choice = StrapClaim.choose(
            heard: [strap("AA:11", "WHOOP 4C15", -40), strap("BB:22", "WHOOP 9F01", -85)], claimed: "bb:22")
        XCTAssertEqual(choice.verdict, .connect)
        XCTAssertEqual(choice.address, "BB:22")
        XCTAssertTrue(choice.choices.isEmpty)
    }

    func testANamedStrapThatIsNotThereKeepsLooking() {
        let choice = StrapClaim.choose(heard: [strap("AA:11")], claimed: "BB:22")
        XCTAssertEqual(choice.verdict, .keepLooking)
    }

    func testTheLaterNameOfAStrapIsKept() {
        // Android reports the address on every scan record but the local name only on some of them.
        let straps = StrapClaim.distinct([strap("AA:11", nil, -50), strap("AA:11", "WHOOP 4C15", -66)])
        XCTAssertEqual(straps.count, 1)
        XCTAssertEqual(straps[0].name, "WHOOP 4C15")
        XCTAssertEqual(straps[0].rssi, -50)
    }
}

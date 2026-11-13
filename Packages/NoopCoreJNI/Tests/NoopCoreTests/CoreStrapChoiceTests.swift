import XCTest
@testable import NoopCore

/// Which strap a scan may take while the WHOOP entry names none. Android asks over this bridge what the
/// Apple app calls directly, so the two cannot drift into choosing different straps from the same air.
/// The rule itself is tested in `WhoopProtocol` (`StrapClaimTests`); this is about the wire.
final class CoreStrapChoiceTests: XCTestCase {

    private func answer(_ args: [String: Any]) async throws -> [String: Any] {
        let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let out = await CoreCall.run("ble.strapChoice", json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func testOneStrapComesBackAsAConnect() async throws {
        let settled = try await answer(["heard": [["address": "AA:11", "name": "WHOOP 4C15", "rssi": -60]]])
        XCTAssertEqual(settled["verdict"] as? String, "connect")
        XCTAssertEqual(settled["address"] as? String, "AA:11")
        XCTAssertEqual((settled["choices"] as? [[String: Any]])?.count, 0)
    }

    func testTwoStrapsComeBackAsAQuestionStrongestFirst() async throws {
        let settled = try await answer(["heard": [
            ["address": "AA:11", "name": "WHOOP 4C15", "rssi": -78],
            ["address": "BB:22", "name": "WHOOP 9F01", "rssi": -42],
        ]])
        XCTAssertEqual(settled["verdict"] as? String, "ask")
        XCTAssertNil(settled["address"] as? String)
        let choices = try XCTUnwrap(settled["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.map { $0["address"] as? String }, ["BB:22", "AA:11"])
        XCTAssertEqual(choices.first?["name"] as? String, "WHOOP 9F01")
    }

    func testAStrapTheEntryAlreadyNamesIsNotAQuestion() async throws {
        let settled = try await answer(["claimed": "bb:22", "heard": [
            ["address": "AA:11", "rssi": -40],
            ["address": "BB:22", "rssi": -85],
        ]])
        XCTAssertEqual(settled["verdict"] as? String, "connect")
        XCTAssertEqual(settled["address"] as? String, "BB:22")
    }

    func testNothingHeardKeepsLooking() async throws {
        let settled = try await answer(["heard": [[String: Any]]()])
        XCTAssertEqual(settled["verdict"] as? String, "keepLooking")
    }

    /// A scan record without a usable address is dropped rather than turned into an unconnectable choice.
    func testAnAddresslessSightingIsIgnored() async throws {
        let settled = try await answer(["heard": [
            ["address": "", "name": "WHOOP 4C15", "rssi": -50],
            ["address": "AA:11", "rssi": -60],
        ]])
        XCTAssertEqual(settled["verdict"] as? String, "connect")
        XCTAssertEqual(settled["address"] as? String, "AA:11")
    }
}

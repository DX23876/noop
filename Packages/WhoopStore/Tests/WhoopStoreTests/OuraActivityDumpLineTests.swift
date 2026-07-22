import XCTest
@testable import WhoopStore

/// The Tier-B activity research-corpus JSONL line encoder. The line is asserted verbatim so the format is
/// pinned (any downstream reader can rely on the exact shape + key order).
final class OuraActivityDumpLineTests: XCTestCase {

    func testEncodesFixedShapeVerbatim() {
        let line = OuraActivityDumpLine.encode(
            deviceId: "oura-5C4C0BF8", ringTs: 5_691_839, utc: 1_783_400_728,
            iso: "2026-07-14T09:05:28Z", state: 23, secPerSample: 60,
            met: [2.2, 1.5, 1.4])
        XCTAssertEqual(line,
            "{\"schema\":1,\"deviceId\":\"oura-5C4C0BF8\",\"ringTs\":5691839," +
            "\"utc\":1783400728,\"iso\":\"2026-07-14T09:05:28Z\",\"state\":23," +
            "\"secPerSample\":60,\"met\":[2.2,1.5,1.4]}")
    }

    func testEmptyMetIsEmptyArray() {
        let line = OuraActivityDumpLine.encode(
            deviceId: "d", ringTs: 1, utc: 2, iso: "x", state: 0, secPerSample: 60, met: [])
        XCTAssertTrue(line.hasSuffix("\"met\":[]}"))
    }

    func testEachLineIsValidJSON() throws {
        let line = OuraActivityDumpLine.encode(
            deviceId: "oura-ring", ringTs: 100, utc: 200, iso: "2026-07-14T00:00:00Z",
            state: 148, secPerSample: 60, met: [3.0, 4.3, 12.8])
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["state"] as? Int, 148)
        XCTAssertEqual((obj?["met"] as? [Double])?.count, 3)
        XCTAssertEqual(obj?["schema"] as? Int, OuraActivityDumpLine.schema)
    }
}

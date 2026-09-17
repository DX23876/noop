import XCTest
@testable import WhoopProtocol

final class Whoop5RRTests: XCTestCase {
    private struct Oracle: Decodable {
        struct Case: Decodable { let ticks: UInt16; let milliseconds: Int }
        struct Policy: Decodable { let model: String?; let brand: String?; let tagged: Bool; let strict: Bool }
        struct Wire: Decodable { let name: String; let hex: String; let raw: [Int]; let ms: [Int]; let channel: Int }
        let cases: [Case]
        let policy_cases: [Policy]
        let wire_cases: [Wire]
        let milliseconds_u16le_fnv1a64: String
    }
    private func oracle() throws -> Oracle {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "whoop5_rr_oracle", withExtension: "json"))
        return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: url))
    }

    func testAllUnsignedWordsMatchExecutedSwiftOracle() throws {
        let expected = try oracle()
        var hash: UInt64 = 14695981039346656037
        for ticks in UInt16.min...UInt16.max {
            let ms = Whoop5RR.milliseconds(ticks: ticks)
            for byte in [ms & 255, ms >> 8] { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        }
        XCTAssertEqual(String(format: "%016llx", hash), expected.milliseconds_u16le_fnv1a64)
        for c in expected.cases { XCTAssertEqual(Whoop5RR.milliseconds(ticks: c.ticks), c.milliseconds) }
        for c in expected.policy_cases {
            XCTAssertEqual(Whoop5RR.usesCanonicalSource(model: c.model, brand: c.brand,
                                                       hasTaggedIntervals: c.tagged), c.strict)
        }
    }

    func testWireBoundsRawUnitsAndExtractedProvenance() throws {
        for c in try oracle().wire_cases {
            let chars = Array(c.hex)
            let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
            let f = parseFrame(bytes, family: .whoop5)
            XCTAssertTrue(f.ok, c.name)
            XCTAssertEqual(f.crcOK, true, c.name)
            XCTAssertEqual(f.parsed["rr_raw_ticks"]?.intArrayValue, c.raw, c.name)
            XCTAssertEqual(f.parsed["rr_intervals"]?.intArrayValue, c.ms, c.name)
            XCTAssertEqual(f.parsed["rr_source_channel"]?.intValue, c.channel, c.name)
            let streams = c.channel == 5
                ? extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
                : extractStreams([f], deviceClockRef: 0, wallClockRef: 0)
            XCTAssertEqual(streams.rr.map(\.rrMs), c.ms, c.name)
            XCTAssertEqual(streams.rr.compactMap { $0.srcChannel?.rawValue }, c.ms.map { _ in c.channel }, c.name)
        }
    }

    func testTransportCodes() {
        XCTAssertEqual(RRSourceChannel.allCases.map(\.rawValue), Array(1...7))
    }
}

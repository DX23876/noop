import XCTest
@testable import WhoopProtocol

final class HistoricalStreamsParityTests: XCTestCase {
    private let deviceClockRef = 31_538_447
    private let wallClockRef = 1_736_365_593

    private struct FrameEntry: Decodable { let hex: String }
    private struct HRGold: Decodable, Equatable { let ts: Int; let bpm: Int }
    private struct RRGold: Decodable, Equatable { let ts: Int; let rr_ms: Int }
    private struct HistGold: Decodable { let hr: [HRGold]; let rr: [RRGold] }

    private func resourceURL(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext),
                      "missing \(name).\(ext) — run scripts/gen_golden.py (Phase F3)")
    }
    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }
    func testSwiftHistoricalMatchesPythonGolden() throws {
        let frames = try JSONDecoder().decode(
            [FrameEntry].self, from: Data(contentsOf: resourceURL("historical_frames", "json")))
        let gold = try JSONDecoder().decode(
            HistGold.self, from: Data(contentsOf: resourceURL("historical_golden", "json")))
        let parsed = frames.map { parseFrame(bytes($0.hex)) }
        let streams = extractHistoricalStreams(parsed,
                        deviceClockRef: deviceClockRef, wallClockRef: wallClockRef)
        XCTAssertEqual(streams.hr, gold.hr.map { HRSample(ts: $0.ts, bpm: $0.bpm) })
        XCTAssertEqual(streams.rr, gold.rr.map {
            RRInterval(ts: $0.ts, rrMs: $0.rr_ms, transport: .whoopHistorical)
        })
        XCTAssertGreaterThan(streams.hr.count, 0)
    }
}

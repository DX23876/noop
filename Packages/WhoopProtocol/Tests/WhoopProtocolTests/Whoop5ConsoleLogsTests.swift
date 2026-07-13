import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") CONSOLE_LOGS (type 50) decode, verified against real captured frames.
///
/// The strap streams its firmware console as fixed-size text chunks: record header (`record_index`
/// u16@9, `unix` u32@12, `subsec` u16@16, chunk_len u16@18, channel u8@20), then the raw text at @21
/// with NUL padding up to the CRC32 trailer. One log line routinely spans several frames — the two
/// consecutive fixtures below split "…start response a" / "ck, start burst" mid-word — so consumers
/// reassemble by `record_index` before reading. All fixtures are real frames from a 2026-07-12
/// history sync (the strap narrating its own transfer); they carry no device name / serial / token.
final class Whoop5ConsoleLogsTests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return out
    }

    /// Real console chunk: a full log line plus the continuation space, NUL-terminated.
    private let sendHistoricalHex =
        "aa014400010030b132ac020052b4526a33733400013134363535323131393a20424c455f434d443a2043" +
        "6f6d6d616e642053656e6420486973746f726963616c20446174610a200018d8fbf6"

    func testConsoleChunkDecodesHeaderAndText() {
        let f = parseFrame(bytes(sendHistoricalHex), family: .whoop5)
        XCTAssertEqual(f.typeName, "CONSOLE_LOGS")
        XCTAssertEqual(f.crcOK, true)
        XCTAssertEqual(f.parsed["record_index"]?.intValue, 684)
        XCTAssertEqual(f.parsed["unix"]?.intValue, 1783805010)
        XCTAssertEqual(f.parsed["subsec"]?.intValue, 29491)
        XCTAssertEqual(f.parsed["log"]?.stringValue,
                       "146552119: BLE_CMD: Command Send Historical Data\n ")
    }

    /// The next two chunks of the same stream: one log line split mid-word ("…response a" | "ck,
    /// start burst…") across consecutive record_index values — the reassembly contract.
    private let splitLineAHex =
        "aa014400010030b132ad020052b4526a337334000131392c203134363535323131393a20424c453a2068" +
        "697374207472616e7366657220737461727420726573706f6e7365206100324a7906"
    private let splitLineBHex =
        "aa014400010030b132ae020052b4526a3373340001636b2c2073746172742062757273740a2031392c20" +
        "3134363535343633303a20424c453a20486973746f727920627572737400e67d611f"

    func testConsecutiveChunksCarryContiguousIndices() {
        let a = parseFrame(bytes(splitLineAHex), family: .whoop5)
        let b = parseFrame(bytes(splitLineBHex), family: .whoop5)
        XCTAssertEqual(a.crcOK, true)
        XCTAssertEqual(b.crcOK, true)
        XCTAssertEqual(a.parsed["record_index"]?.intValue, 685)
        XCTAssertEqual(b.parsed["record_index"]?.intValue, 686)
        XCTAssertEqual(a.parsed["log"]?.stringValue,
                       "19, 146552119: BLE: hist transfer start response a")
        XCTAssertEqual(b.parsed["log"]?.stringValue,
                       "ck, start burst\n 19, 146554630: BLE: History burst")
    }

    /// A truncated frame (header only, no text region) must not decode a log — and must not crash.
    func testHeaderOnlyFrameYieldsNoLog() {
        let full = bytes(sendHistoricalHex)
        let truncated = Array(full[0..<20])
        let f = parseFrame(truncated, family: .whoop5)
        XCTAssertNil(f.parsed["log"])
    }
}

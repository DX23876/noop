import XCTest
@testable import Strand

/// Pins `PuffinDeepBufferLog.isDeepBuffer` — the pure predicate behind the durable high-rate deep-buffer
/// log (#423). A reassembled WHOOP 5/MG frame carries its inner-record type at offset 8; the R22 deep
/// packets are type 0x2F (47). The 1 Hz historical rollup is the SAME type but small, so the log keeps
/// only the big (≥ 1 KB) high-rate buffers. BLE delivery can't be unit-tested, but this offset-8 +
/// size gate CAN be, so a frame-shape change can't silently stop the research log filling. Mirrors
/// `PuffinEventLogTests`.
final class PuffinDeepBufferLogTests: XCTestCase {

    func testAcceptsBigType2FAtOffset8() {
        var f = [UInt8](repeating: 0, count: 2140) // the 2140-B high-rate buffer
        f[8] = 0x2F
        XCTAssertTrue(PuffinDeepBufferLog.isDeepBuffer(f))
        var g = [UInt8](repeating: 0, count: 1244) // the 1244-B high-rate buffer
        g[8] = 0x2F
        XCTAssertTrue(PuffinDeepBufferLog.isDeepBuffer(g))
    }

    func testRejectsSmallType2FRecord() {
        // The ~124-B type-0x2F frame is the 1 Hz rollup NOOP already decodes — below the size gate,
        // it must NOT be logged as a high-rate buffer.
        var f = [UInt8](repeating: 0, count: 124)
        f[8] = 0x2F
        XCTAssertFalse(PuffinDeepBufferLog.isDeepBuffer(f))
    }

    func testRejectsOtherTypesEvenWhenBig() {
        // Big frames of other inner types (REALTIME 0x28, COMMAND_RESPONSE 0x24, EVENT 0x30,
        // METADATA 0x31) must never be treated as a deep buffer.
        for t: UInt8 in [0x28, 0x24, 0x30, 0x31, 0x32, 47 &+ 1] {
            var f = [UInt8](repeating: 0, count: 2140)
            f[8] = t
            XCTAssertFalse(PuffinDeepBufferLog.isDeepBuffer(f), "type \(t) must not be a deep buffer")
        }
    }

    func testRejectsTooShortToIndexOffset8() {
        for n in 0...8 {
            XCTAssertFalse(PuffinDeepBufferLog.isDeepBuffer([UInt8](repeating: 0x2F, count: n)))
        }
    }
}

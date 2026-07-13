import XCTest
@testable import Strand

/// Pins `PuffinEventLog.isEventFrame` — the pure predicate behind the durable EVENT-frame log
/// (#103/#346). A reassembled WHOOP 5/MG frame carries its inner-record type at offset 8, and EVENT is
/// type 48 (0x30); the log keys on exactly that. BLE delivery can't be unit-tested, but this offset-8
/// magic number CAN be, so a future frame-shape change can't silently stop the research log filling.
/// Twin of the Android `Whoop5EventFramePredicateTest`.
final class PuffinEventLogTests: XCTestCase {

    func testAcceptsEventTypeAtOffset8() {
        var f = [UInt8](repeating: 0, count: 12)
        f[8] = 0x30 // EVENT (type 48)
        XCTAssertTrue(PuffinEventLog.isEventFrame(f))
    }

    func testRejectsNonEventTypes() {
        // Live REALTIME(0x28) and the offload record types (47/49/50, PUFFIN_METADATA 56) plus the
        // R22-telemetry types (0x24/0x2F) must never be logged as EVENT.
        let nonEventTypes: [UInt8] = [0x28, 47, 49, 50, 56, 0x2F, 0x24]
        for t in nonEventTypes {
            var f = [UInt8](repeating: 0, count: 12)
            f[8] = t
            XCTAssertFalse(PuffinEventLog.isEventFrame(f), "type \(t) must not be treated as EVENT")
        }
    }

    func testRejectsFramesTooShortToIndexOffset8() {
        // size <= 8 has no byte at offset 8; the predicate must guard the index (no crash, no match).
        for n in 0...8 {
            XCTAssertFalse(PuffinEventLog.isEventFrame([UInt8](repeating: 0x30, count: n)),
                           "size \(n) is too short to be an EVENT frame")
        }
    }

    func testBoundaryExactlyNineBytesWithEventTypeIsAccepted() {
        // Smallest frame that can carry the offset-8 type byte: size 9 (indices 0...8).
        var f = [UInt8](repeating: 0, count: 9)
        f[8] = 0x30
        XCTAssertTrue(PuffinEventLog.isEventFrame(f))
        XCTAssertFalse(PuffinEventLog.isEventFrame([UInt8](repeating: 0, count: 8)))
    }
}

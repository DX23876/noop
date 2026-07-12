import XCTest
@testable import OuraProtocol

/// Framing tests: outer command/response frames, the 0x2F secure-session sub-frame, and the TLV
/// inner-record parse — open_oura's ONE-packet-per-notification model (lenient `len`, no buffering,
/// no multi-record loop, no byte-drop resync).
final class FramingTests: XCTestCase {
    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    // MARK: - Outer frame

    func testParseOuterFrame() {
        // 0d 06 <6 body bytes> (a battery response shape).
        let f = OuraFraming.parseOuterFrame(bytes("0d06570000003c0f"))
        XCTAssertEqual(f?.op, 0x0D)
        XCTAssertEqual(f?.body, bytes("570000003c0f"))
        XCTAssertEqual(f?.totalLength, 8)
    }

    func testParseOuterFrameShortReturnsNil() {
        // Declares 6 body bytes but only 2 present -> nil (wait for more).
        XCTAssertNil(OuraFraming.parseOuterFrame(bytes("0d065700")))
    }

    func testMultipleOuterFramesInOneValue() {
        // 25 01 00  (SetAuthKey resp)  then  1d 01 00 (SetNotification resp).
        let frames = OuraFraming.parseOuterFrames(bytes("2501001d0100"))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].op, 0x25)
        XCTAssertEqual(frames[0].body, [0x00])
        XCTAssertEqual(frames[1].op, 0x1D)
        XCTAssertEqual(frames[1].body, [0x00])
    }

    // MARK: - GetBattery response (0x0D, s6.10)

    func testBatteryResponseOpIsRecognisedAsAnOuterFrame() {
        // 0d 06 <percent=57=87> <charging=00> <flag=00> <3 unknown> - the live path routes this op to the
        // battery decoder, never to the TLV record decoder (op 0x0D is below the event-tag range).
        let frames = OuraFraming.parseOuterFrames(bytes("0d06570000003c0f"))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].op, OuraFraming.batteryResponseOp)
        let battery = OuraDecoders.decodeBattery(frames[0].body)
        XCTAssertEqual(battery?.percent, 0x57)   // 87%
    }

    // MARK: - GetEvents response (0x11, s5.2)

    func testParseGetEventsResponseMoreDataWhileBytesLeft() {
        // REAL on-device capture (2026-07-11 07:04, full-pull first summary):
        // 11 08 <events=ff> <progress=00> <bytes_left:4LE = a6 a1 1a 00 = 1,745,318> <pad 03 00>.
        let outer = OuraFraming.parseOuterFrame(bytes("1108ff00a6a11a000300"))
        XCTAssertEqual(outer?.op, OuraFraming.getEventsResponseOp)
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.eventsReceived, 0xFF)
        XCTAssertEqual(summary?.bytesLeft, 1_745_318)
        XCTAssertEqual(summary?.moreData, true)
    }

    func testParseGetEventsResponseCompleteAtZeroBytesLeft() {
        // REAL on-device capture (final summary of a completed drain): bytes_left == 0 -> caught up.
        let outer = OuraFraming.parseOuterFrame(bytes("11080000000000000300"))
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.eventsReceived, 0)
        XCTAssertEqual(summary?.bytesLeft, 0)
        XCTAssertEqual(summary?.moreData, false)
    }

    func testParseGetEventsResponseZeroEventsButBytesLeftIsMoreData() {
        // THE #91 regression case, byte-for-byte from the 2026-07-11 18:53 log: events_received == 0 but
        // bytes_left = e9 1d 06 00 = 400,873. The old parse read body[0] as a status and STOPPED here,
        // abandoning the newest 400 KB of the log (the previous night's hypnogram). moreData must be true.
        let outer = OuraFraming.parseOuterFrame(bytes("11080000e91d06000300"))
        let summary = OuraFraming.parseGetEventsResponse(outer!.body)
        XCTAssertEqual(summary?.eventsReceived, 0)
        XCTAssertEqual(summary?.bytesLeft, 400_873)
        XCTAssertEqual(summary?.moreData, true, "bytes_left > 0 means the drain MUST continue")
    }

    func testParseGetEventsResponseShortBodyReturnsNil() {
        XCTAssertNil(OuraFraming.parseGetEventsResponse(bytes("ff0012")))
    }

    // MARK: - Secure-session sub-frame (0x2F)

    func testSecureFrameNonceResponse() {
        // Wire: 2f 10 2c <nonce:15>. Outer: op 0x2F, len 0x10 (16), body = 2c + 15 nonce bytes.
        let wire = bytes("2f102c0102030405060708090a0b0c0d0e0f")
        guard let outer = OuraFraming.parseOuterFrame(wire) else { return XCTFail("outer parse") }
        XCTAssertEqual(outer.op, 0x2F)
        guard let secure = OuraFraming.parseSecureFrame(outer) else { return XCTFail("secure parse") }
        XCTAssertEqual(secure.subop, 0x2C)
        XCTAssertEqual(secure.subBody, bytes("0102030405060708090a0b0c0d0e0f"))
        // And the auth layer pulls the 15-byte nonce straight out.
        XCTAssertEqual(OuraAuth.nonce(from: secure), bytes("0102030405060708090a0b0c0d0e0f"))
    }

    func testSecureFrameAuthStatus() {
        // 2f 02 2e 00 -> success.
        let wire = bytes("2f022e00")
        guard let outer = OuraFraming.parseOuterFrame(wire),
              let secure = OuraFraming.parseSecureFrame(outer) else { return XCTFail("parse") }
        XCTAssertEqual(secure.subop, 0x2E)
        XCTAssertEqual(OuraAuth.authStatus(from: secure), .success)
    }

    func testNonSecureFrameReturnsNilSecure() {
        let outer = OuraOuterFrame(op: 0x0D, body: [0x01])
        XCTAssertNil(OuraFraming.parseSecureFrame(outer))
    }

    // MARK: - TLV record parsing

    func testParseTLVRecord() {
        // 7b 06 <rt:4 LE 02000100> 03 ca  -> type 0x7B, rt 0x00010002, payload 03 ca.
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))
        XCTAssertEqual(rec?.type, 0x7B)
        XCTAssertEqual(rec?.ringTimestamp, 0x0001_0002)
        XCTAssertEqual(rec?.counter, 0x0002)
        XCTAssertEqual(rec?.session, 0x0001)
        XCTAssertEqual(rec?.payload, bytes("03ca"))
        XCTAssertEqual(rec?.totalLength, 8)
    }

    func testTLVLenBelowFourIsRejected() {
        // len must be >= 4 to cover the 4 timestamp bytes; len=3 -> nil (honest, no guess).
        XCTAssertNil(OuraFraming.parseRecord([0x7B, 0x03, 0x00, 0x01, 0x02]))
    }

    func testTLVBelowSixBytesIsRejected() {
        // A record floor is 6 bytes (2 header + 4 timestamp). Fewer than that cannot yield a ring time.
        XCTAssertNil(OuraFraming.parseRecord([0x7B, 0x06, 0x02, 0x00, 0x01]))   // only 5 bytes
    }

    // MARK: - Lenient parse (open_oura Packet::parse): len need not equal notification length

    func testParseRecordIgnoresTrailingBytesBeyondLen() {
        // A notification carrying a complete record PLUS trailing bytes (BLE padding, or a following
        // packet the ring did not pack for us) yields exactly ONE record whose payload is the declared
        // `len - 4` bytes; the trailing bytes are ignored, never minted into a phantom record.
        let rec = OuraFraming.parseRecord(bytes("7b060200010003ca" + "ffeeddcc"))
        XCTAssertEqual(rec?.type, 0x7B)
        XCTAssertEqual(rec?.ringTimestamp, 0x0001_0002)
        XCTAssertEqual(rec?.payload, bytes("03ca"), "payload is exactly len-4; trailing bytes dropped")
    }

    func testParseRecordTooBigLenUsesWhatArrived() {
        // `len` claims a longer payload than the notification carries. open_oura tolerates the
        // disagreement and uses the bytes present, rather than waiting for (and swallowing) the next
        // notification. Here len=0x0A (payload 6) but only 2 payload bytes arrived.
        let rec = OuraFraming.parseRecord(bytes("7b0a0200010003ca"))
        XCTAssertEqual(rec?.type, 0x7B)
        XCTAssertEqual(rec?.ringTimestamp, 0x0001_0002)
        XCTAssertEqual(rec?.payload, bytes("03ca"), "uses the 2 payload bytes present, no wait")
    }

    // MARK: - One packet per notification (no buffering, no multi-record loop, no resync)

    func testFeedReturnsAtMostOneRecordPerNotification() {
        // What LOOKS like two packed records is treated as ONE lenient packet: the first record only,
        // trailing bytes ignored. The ring never packs several events into one notification (it streams
        // one event per notification + a 0x11 summary), so this is the honest interpretation.
        let r = OuraReassembler()
        let recs = r.feed(bytes("7b060200010003ca" + "4e0602000100006c"))
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].type, 0x7B)
        XCTAssertEqual(recs[0].payload, bytes("03ca"))
    }

    func testFeedNeverBuffersAcrossNotifications() {
        // A too-short notification is dropped whole (no leftover bytes carried); the NEXT notification is
        // parsed independently. This is the property the old buffering reassembler lacked — a leftover
        // partial used to corrupt the following notification into the phantom-record storm.
        let r = OuraReassembler()
        XCTAssertTrue(r.feed(bytes("7b0602")).isEmpty, "3-byte fragment is below the record floor")
        XCTAssertEqual(r.bufferedByteCount, 0, "nothing is retained between notifications")
        let recs = r.feed(bytes("4e0602000100006c"))
        XCTAssertEqual(recs.map { $0.type }, [0x4E], "next notification parses cleanly on its own")
    }

    func testFeedDropsUnusableNotificationWholeNoResync() {
        // A notification whose len is < 4 is not walked byte-by-byte looking for a later record (there is
        // no start-of-frame marker to realign to, and byte-walking is exactly what minted phantoms). It
        // is dropped whole: no record, no buffered tail.
        let r = OuraReassembler()
        let recs = r.feed([0x00, 0x01, 0x02, 0x03, 0x01, 0x02])   // len byte 0x01 < 4
        XCTAssertTrue(recs.isEmpty)
        XCTAssertEqual(r.bufferedByteCount, 0)
    }

    func testResetIsANoOpWithNoBufferedState() {
        let r = OuraReassembler()
        _ = r.feed(bytes("7b0602"))            // below floor, nothing retained
        XCTAssertEqual(r.bufferedByteCount, 0)
        r.reset()
        XCTAssertEqual(r.bufferedByteCount, 0)
    }
}

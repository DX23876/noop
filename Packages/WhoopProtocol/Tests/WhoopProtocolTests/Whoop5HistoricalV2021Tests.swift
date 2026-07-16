import XCTest
@testable import WhoopProtocol

/// WHOOP 5.0 ("puffin") HISTORICAL_DATA (type 47) **version 20 / 21** decode — the bulk multi-channel
/// sensor stream the strap serves alongside the v18 per-second summary (issue #344). Earlier builds fell
/// back to "unmapped layout" and stored nothing.
///
/// Both versions reuse the v18 record header (layout version @9, marker @10, record index u32 @11, unix
/// u32 @15). v21 (1244 B) carries six 100-sample i16 IMU channels — accelerometer @28/@228/@428 and
/// gyroscope @640/@840/@1040 (#493); v20 (2140 B) carries five blocks of two 50-sample i32 channels, each
/// block gated by a presence byte (0x19 = active, 0x00 = empty). The layout was established from captured
/// v20/v21 frames; these tests exercise the decode mechanics on frames assembled with valid header-CRC16
/// and trailer-CRC32 envelopes — plus one real captured v21 buffer for the gravity-shell identity check.
final class Whoop5HistoricalV2021Tests: XCTestCase {

    /// Assemble a valid WHOOP 5.0 type-47 frame of the given total length and layout version.
    /// Envelope: [0]=0xAA [1]=0x01 [2-3]=declaredLength(=total-8) [4-5]=01 00 [6-7]=CRC16-Modbus(hdr)
    /// [8]=type 47 [9]=version … [total-4 ..]=CRC32(payload). The closure fills the body.
    private func makeFrame(total: Int, version: UInt8, _ build: (inout [UInt8]) -> Void) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: total)
        f[0] = 0xAA; f[1] = 0x01
        let declared = total - 8
        f[2] = UInt8(declared & 0xff); f[3] = UInt8((declared >> 8) & 0xff)
        f[4] = 0x01; f[5] = 0x00
        f[8] = 0x2f          // packet type 47 (HISTORICAL_DATA)
        f[9] = version
        build(&f)
        let h = crc16Modbus(Array(f[0..<6]))
        f[6] = UInt8(h & 0xff); f[7] = UInt8((h >> 8) & 0xff)
        let payloadEnd = total - 4
        let c = crc32(Array(f[8..<payloadEnd]))
        f[payloadEnd] = UInt8(c & 0xff); f[payloadEnd + 1] = UInt8((c >> 8) & 0xff)
        f[payloadEnd + 2] = UInt8((c >> 16) & 0xff); f[payloadEnd + 3] = UInt8((c >> 24) & 0xff)
        return f
    }

    private func putU32(_ f: inout [UInt8], _ off: Int, _ v: UInt32) {
        f[off] = UInt8(v & 0xff); f[off + 1] = UInt8((v >> 8) & 0xff)
        f[off + 2] = UInt8((v >> 16) & 0xff); f[off + 3] = UInt8((v >> 24) & 0xff)
    }
    private func putI16(_ f: inout [UInt8], _ off: Int, _ v: Int16) {
        let u = UInt16(bitPattern: v); f[off] = UInt8(u & 0xff); f[off + 1] = UInt8((u >> 8) & 0xff)
    }
    private func putI32(_ f: inout [UInt8], _ off: Int, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        f[off] = UInt8(u & 0xff); f[off + 1] = UInt8((u >> 8) & 0xff)
        f[off + 2] = UInt8((u >> 16) & 0xff); f[off + 3] = UInt8((u >> 24) & 0xff)
    }

    func testV21HeaderAndSixImuChannels() {
        let unix: UInt32 = 1781556371, idx: UInt32 = 0x01A8CF25
        let frame = makeFrame(total: 1244, version: 21) { f in
            f[10] = 0x80                     // marker
            putU32(&f, 11, idx)              // record index
            putU32(&f, 15, unix)             // unix
            for i in 0..<100 { putI16(&f, 28 + i * 2, Int16(1800 + (i % 7))) }    // accel_x
            for i in 0..<100 { putI16(&f, 228 + i * 2, Int16(700 + (i % 5))) }    // accel_y
            for i in 0..<100 { putI16(&f, 428 + i * 2, Int16(3600 + (i % 3))) }   // accel_z
            for i in 0..<100 { putI16(&f, 640 + i * 2, Int16(10 + (i % 4))) }     // gyro_x (the block v21 used to drop)
            for i in 0..<100 { putI16(&f, 840 + i * 2, Int16(-20 + (i % 3))) }    // gyro_y
            for i in 0..<100 { putI16(&f, 1040 + i * 2, Int16(5 + (i % 2))) }     // gyro_z
        }
        let p = parseFrame(frame, family: .whoop5)
        XCTAssertTrue(p.ok); XCTAssertEqual(p.typeName, "HISTORICAL_DATA"); XCTAssertEqual(p.crcOK, true)
        XCTAssertEqual(p.parsed["hist_version"]?.intValue, 21)
        XCTAssertEqual(p.parsed["layout_marker"]?.intValue, 0x80)
        XCTAssertEqual(p.parsed["record_index"]?.intValue, Int(idx))
        XCTAssertEqual(p.parsed["unix"]?.intValue, Int(unix))
        XCTAssertEqual(p.parsed["sensor_channel_samples"]?.intValue, 100)
        // Accelerometer block: renamed off the old optical_ch* labels (#493).
        let ax = p.parsed["accel_x"]?.intArrayValue ?? []
        XCTAssertEqual(ax.count, 100)
        XCTAssertEqual(ax.first, 1800); XCTAssertEqual(ax[3], 1803)
        XCTAssertEqual(p.parsed["accel_z"]?.intArrayValue?.first, 3600)
        // Gyroscope block: previously dropped entirely — now decoded.
        let gx = p.parsed["gyro_x"]?.intArrayValue ?? []
        XCTAssertEqual(gx.count, 100); XCTAssertEqual(gx.first, 10)
        XCTAssertEqual(p.parsed["gyro_z"]?.intArrayValue?.first, 5)
        // The old optical labels must be gone.
        XCTAssertNil(p.parsed["optical_ch0"])
    }

    /// Real captured v21 buffer (shared with `Whoop5RawImuTests`): the accelerometer channels the historical
    /// decoder emits must form a ~1 g gravity shell — the physical assertion a synthetic frame cannot make,
    /// and the one that pins the accel (not optical) identity so a future re-mislabel fails loudly (#493).
    func testV21RealFrameAccelIsGravityShell() {
        let f = Whoop5RawImuTests.realFrameBytes
        let p = parseFrame(f, family: .whoop5)
        XCTAssertEqual(p.parsed["hist_version"]?.intValue, 21)
        guard let ax = p.parsed["accel_x"]?.intArrayValue,
              let ay = p.parsed["accel_y"]?.intArrayValue,
              let az = p.parsed["accel_z"]?.intArrayValue,
              ax.count == 100, ay.count == 100, az.count == 100 else {
            return XCTFail("real v21 frame did not decode three 100-sample accel channels")
        }
        let scale = 1.0 / 4096.0   // g per LSB, per Whoop5RawImu
        let mags = (0..<100).map { i -> Double in
            let x = Double(ax[i]) * scale, y = Double(ay[i]) * scale, z = Double(az[i]) * scale
            return (x * x + y * y + z * z).squareRoot()
        }
        let sorted = mags.sorted(); let median = sorted[sorted.count / 2]
        XCTAssertEqual(median, 1.0, accuracy: 0.15, "median |accel| should be ~1 g, not an optical waveform")
        let inShell = mags.filter { $0 > 0.85 && $0 < 1.15 }.count
        XCTAssertGreaterThanOrEqual(inShell, 95, "≥95/100 accel samples should sit in the gravity shell")
        // The gyro block must be present too (the historical path used to discard it).
        XCTAssertEqual(p.parsed["gyro_x"]?.intArrayValue?.count, 100)
    }

    func testV20HeaderActiveAndEmptyBlocks() {
        let unix: UInt32 = 1781556372, idx: UInt32 = 0x01A8CF26
        let frame = makeFrame(total: 2140, version: 20) { f in
            f[10] = 0x81
            putU32(&f, 11, idx)
            putU32(&f, 15, unix)
            // Block 0 active: presence byte + two i32 channels.
            f[0x1a] = 0x19
            for i in 0..<50 { putI32(&f, 0x2f + i * 4, Int32(100000 + i)) }   // ch b0_0
            for i in 0..<50 { putI32(&f, 0xf7 + i * 4, Int32(200000 - i)) }   // ch b0_1
            // Block 1 empty: presence byte stays 0x00, channel slots stay zero.
            f[0x1c0] = 0x00
            // Block 3 active (gated tail block): presence + one channel.
            f[0x50c] = 0x19
            for i in 0..<50 { putI32(&f, 0x521 + i * 4, Int32(140 + i)) }
            for i in 0..<50 { putI32(&f, 0x5e9 + i * 4, Int32(130 + i)) }
        }
        let p = parseFrame(frame, family: .whoop5)
        XCTAssertTrue(p.ok); XCTAssertEqual(p.crcOK, true)
        XCTAssertEqual(p.parsed["hist_version"]?.intValue, 20)
        XCTAssertEqual(p.parsed["layout_marker"]?.intValue, 0x81)
        XCTAssertEqual(p.parsed["record_index"]?.intValue, Int(idx))
        XCTAssertEqual(p.parsed["unix"]?.intValue, Int(unix))
        XCTAssertEqual(p.parsed["sensor_channel_samples"]?.intValue, 50)
        // Active blocks 0 and 3 -> 4 channels; empty block 1 contributes none.
        XCTAssertEqual(p.parsed["sensor_channels_present"]?.intValue, 4)
        let b00 = p.parsed["channel_b0_0"]?.intArrayValue ?? []
        XCTAssertEqual(b00.count, 50); XCTAssertEqual(b00.first, 100000); XCTAssertEqual(b00.last, 100049)
        XCTAssertEqual(p.parsed["channel_b0_1"]?.intArrayValue?.first, 200000)
        XCTAssertEqual(p.parsed["channel_b3_0"]?.intArrayValue?.first, 140)
        // Empty block 1 produced no channel.
        XCTAssertNil(p.parsed["channel_b1_0"])
    }
}

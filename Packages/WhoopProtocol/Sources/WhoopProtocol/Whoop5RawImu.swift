import Foundation

// Whoop5RawImu.swift — decoder for the WHOOP 5.0/MG raw 6-axis IMU offload buffer (#423).
//
// The 5/MG ships a 1244-byte buffer during the connect-time offload burst that carries a full second
// of raw inertial data: 100 accelerometer samples + 100 gyroscope samples, stored COLUMNAR (all ax,
// then all ay, then all az; likewise the gyro), i16 little-endian. This is the SAME shape the WHOOP
// app captures (documented in Asherlc/dofek `docs/whoop-ble-protocol.md` as the type-0x2B raw packet)
// and the same columnar convention as the 4.0's 1917 REALTIME_RAW_DATA variant.
//
// IMPORTANT: the 5/MG's *live* raw-IMU stream is firmware-refused (TOGGLE_IMU_MODE / cmd 106 acks but
// never streams), but the OFFLOAD buffer carries full accel AND gyro — so 100 Hz 6-axis IMU IS
// obtainable on the 5.0 via the historical path.
//
// Frame layout (the reassembled BLE frame = 8-byte puffin envelope + payload; offsets are FRAME-absolute):
//   @15  u32 LE   strap unix seconds for this 1-second frame
//   @24  u16 LE   countA (accelerometer sample count, = 100)
//   @28  100×i16  ax   @228 100×i16 ay   @428 100×i16 az     scale 1/4096 g/LSB
//   @630 u16 LE   countB (gyroscope sample count, = 100)
//   @640 100×i16  gx   @840 100×i16 gy   @1040 100×i16 gz    scale 2000/32768 (°/s)/LSB (±2000 dps)
//
// VALIDATED on 1423 buffers from a real 5.0 (fw 50.40.1.0): accel magnitude is a 1.01 g gravity shell
// (100 % of samples within ±15 % of the median; 4117 ± 11 LSB across 200 s), and gyro sits near zero at
// rest, spikes in motion, and correlates 0.79 with accel motion. Pure/deterministic; no I/O, no strap.

/// One raw IMU sample: 3-axis accelerometer (g) + 3-axis gyroscope (°/s).
public struct RawImuSample: Equatable, Codable, Sendable {
    public let ax: Double, ay: Double, az: Double   // g
    public let gx: Double, gy: Double, gz: Double    // deg/s
    public init(ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
        self.ax = ax; self.ay = ay; self.az = az; self.gx = gx; self.gy = gy; self.gz = gz
    }
}

/// One decoded 5/MG raw-IMU buffer: a second of 6-axis samples with the strap's base timestamp.
public struct Whoop5ImuFrame: Equatable, Sendable {
    public let baseTs: Int              // strap unix seconds for the frame
    public let sampleRateHz: Int        // 100
    public let samples: [RawImuSample]
    public init(baseTs: Int, sampleRateHz: Int, samples: [RawImuSample]) {
        self.baseTs = baseTs; self.sampleRateHz = sampleRateHz; self.samples = samples
    }
    /// Wall-clock unix seconds for sample `i` (samples are evenly spaced across the 1-second frame).
    public func ts(of i: Int) -> Double { Double(baseTs) + Double(i) / Double(max(1, sampleRateHz)) }
}

public enum Whoop5RawImu {

    public static let bufferLength = 1244
    public static let sampleCount = 100
    public static let accelScale = 1.0 / 4096.0            // g per LSB (WHOOP accel scale)
    public static let gyroScale = 2000.0 / 32768.0         // deg/s per LSB (±2000 dps, ≈16.4 LSB/dps)

    // FRAME-absolute offsets (8-byte puffin envelope + payload).
    static let tsOff = 15, countAOff = 24, axOff = 28, ayOff = 228, azOff = 428
    static let countBOff = 630, gxOff = 640, gyOff = 840, gzOff = 1040

    /// Decode a raw-IMU buffer, or nil if it isn't one. Gates on the exact length + the two in-packet
    /// sample counts (=100) rather than the type byte, so it can't misfire on a same-type non-IMU frame.
    public static func decode(_ f: [UInt8]) -> Whoop5ImuFrame? {
        guard f.count == bufferLength,
              u16(f, countAOff) == sampleCount, u16(f, countBOff) == sampleCount,
              gzOff + 2 * sampleCount <= f.count else { return nil }
        let baseTs = Int(u32(f, tsOff))
        var samples = [RawImuSample]()
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let o = 2 * i
            samples.append(RawImuSample(
                ax: Double(i16(f, axOff + o)) * accelScale,
                ay: Double(i16(f, ayOff + o)) * accelScale,
                az: Double(i16(f, azOff + o)) * accelScale,
                gx: Double(i16(f, gxOff + o)) * gyroScale,
                gy: Double(i16(f, gyOff + o)) * gyroScale,
                gz: Double(i16(f, gzOff + o)) * gyroScale))
        }
        return Whoop5ImuFrame(baseTs: baseTs, sampleRateHz: sampleCount, samples: samples)
    }

    /// The raw i16 columns exactly as they sit on the wire — [ax×100, ay×100, az×100, gx×100, gy×100,
    /// gz×100] — for faithful, compact storage (#423). Same length + sample-count gate and offsets as
    /// `decode`; nil if `f` isn't a valid IMU buffer. Scales stay documented constants applied at read
    /// time, so nothing lossy is baked into the stored bytes. Twin of Kotlin `Whoop5RawImu.rawColumns`.
    public static func rawColumns(_ f: [UInt8]) -> [Int16]? {
        guard f.count == bufferLength,
              u16(f, countAOff) == sampleCount, u16(f, countBOff) == sampleCount,
              gzOff + 2 * sampleCount <= f.count else { return nil }
        let cols = [axOff, ayOff, azOff, gxOff, gyOff, gzOff]
        var out = [Int16](repeating: 0, count: 6 * sampleCount)
        for c in 0..<6 {
            for i in 0..<sampleCount { out[c * sampleCount + i] = Int16(truncatingIfNeeded: i16(f, cols[c] + 2 * i)) }
        }
        return out
    }

    /// The strap unix-second stamp of this 1-second buffer (frame offset 15), or nil if too short. Public
    /// so the capture seam can key a stored row without re-reading internal offsets (#423).
    public static func baseTs(_ f: [UInt8]) -> Int? {
        guard f.count > tsOff + 3 else { return nil }
        return Int(u32(f, tsOff))
    }

    // MARK: - Little-endian readers (frame-absolute)
    static func u16(_ f: [UInt8], _ o: Int) -> Int { Int(f[o]) | (Int(f[o + 1]) << 8) }
    static func u32(_ f: [UInt8], _ o: Int) -> UInt32 {
        UInt32(f[o]) | (UInt32(f[o + 1]) << 8) | (UInt32(f[o + 2]) << 16) | (UInt32(f[o + 3]) << 24)
    }
    static func i16(_ f: [UInt8], _ o: Int) -> Int { let v = u16(f, o); return v >= 32768 ? v - 65536 : v }
}

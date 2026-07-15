import XCTest
@testable import WhoopProtocol

/// Pins `Whoop5RawImu.decode` — the WHOOP 5/MG raw 6-axis IMU offload buffer (#423). A synthetic frame
/// checks the exact columnar offsets + scales; a REAL captured buffer (fw 50.40.1.0) checks the decode
/// against hardware by asserting the accelerometer forms a ~1 g gravity shell and the gyro is sane.
final class Whoop5RawImuTests: XCTestCase {

    /// Build a minimal valid frame: counts = 100, and one known accel + gyro sample at index `i`.
    private func syntheticFrame(i: Int, axLSB: Int, gxLSB: Int) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: Whoop5RawImu.bufferLength)
        f[8] = 0x2F
        func putU16(_ o: Int, _ v: Int) { f[o] = UInt8(v & 0xFF); f[o + 1] = UInt8((v >> 8) & 0xFF) }
        func putI16(_ o: Int, _ v: Int) { putU16(o, v < 0 ? v + 65536 : v) }
        putU16(24, 100)                         // countA
        putU16(630, 100)                        // countB
        putU16(15, 0x0000_0064); f[16] = 0; f[17] = 0; f[18] = 0  // baseTs low byte only, = 100
        putI16(28 + 2 * i, axLSB)               // ax[i]
        putI16(640 + 2 * i, gxLSB)              // gx[i]
        return f
    }

    func testDecodesKnownSampleWithCorrectScales() {
        // ax = 4096 LSB → 1.0 g; gx = 328 LSB → 328 * 2000/32768 = 20.02 °/s.
        let f = syntheticFrame(i: 3, axLSB: 4096, gxLSB: 328)
        let frame = Whoop5RawImu.decode(f)
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.samples.count, 100)
        XCTAssertEqual(frame?.sampleRateHz, 100)
        XCTAssertEqual(frame!.samples[3].ax, 1.0, accuracy: 1e-9)
        XCTAssertEqual(frame!.samples[3].ay, 0.0, accuracy: 1e-9)
        XCTAssertEqual(frame!.samples[3].gx, 328.0 * 2000.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(frame!.samples[0].ax, 0.0, accuracy: 1e-9)   // other indices untouched
    }

    func testRejectsWrongLengthOrCounts() {
        XCTAssertNil(Whoop5RawImu.decode([UInt8](repeating: 0, count: 500)))   // too short
        var f = syntheticFrame(i: 0, axLSB: 0, gxLSB: 0)
        f[24] = 0; f[25] = 0                                                    // countA != 100
        XCTAssertNil(Whoop5RawImu.decode(f))
    }

    func testDecodesRealBufferAsGravityShell() {
        let f = Self.realFrameBytes
        XCTAssertEqual(f.count, Whoop5RawImu.bufferLength)
        guard let frame = Whoop5RawImu.decode(f) else { return XCTFail("real buffer did not decode") }
        XCTAssertEqual(frame.samples.count, 100)
        XCTAssertEqual(frame.baseTs, 1_784_037_165)   // strap ts @15

        // Accel: every sample must sit in a ~1 g gravity shell (the defining accel signature).
        let mags = frame.samples.map { ($0.ax * $0.ax + $0.ay * $0.ay + $0.az * $0.az).squareRoot() }
        let sorted = mags.sorted(); let median = sorted[sorted.count / 2]
        XCTAssertEqual(median, 1.0, accuracy: 0.15, "median |accel| should be ~1 g")
        let inShell = mags.filter { $0 > 0.7 * median && $0 < 1.3 * median }.count
        XCTAssertGreaterThanOrEqual(inShell, 95, "≥95/100 accel samples should be in the gravity shell")

        // Gyro: at (near) rest the mean magnitude is small — far below the ±2000 dps full scale.
        let gyroMean = frame.samples.map { ($0.gx * $0.gx + $0.gy * $0.gy + $0.gz * $0.gz).squareRoot() }
            .reduce(0, +) / 100.0
        XCTAssertLessThan(gyroMean, 200.0, "resting gyro magnitude should be small")
    }

    /// One real 1244-byte type-0x2F IMU buffer captured off a WHOOP 5.0 (fw 50.40.1.0), #423.
    static let realFrameBytes: [UInt8] = {
        let hex = "aa01d40401005c702f1580e520af002d3f566a002004640064000300d308cc08c408c908c208cd08b708c208cc08c908cc08e108d608e408d208c508bd08d708c508d208cc08c908bc08b508a908c008cc08cb08d308e108dc08d408d108c108c208c208b708ce08c608e008c308d208bd08c908bb08b708be08c208cc08ce08c608cf08c408c808ca08cb08cf08cb08d508c708c908cc08bf08c308c408cc08cc08cc08c508c708d108c108c608c808c108c408c308c608cf08c808c608cf08ce08c808d008c008d008c608bb08cb08d208c008cb08c708c008c508c208c608cf08d008d3ffcaffc1ffc8ffcaffc5ffccffd4ffd3ffdeffddffd8ffdbffd6ffc7ffc7ffd0ffd5ffd6ffe2ffd4ffceffd6ffd2ffe2ffdbffdbffc7ffc6ffc9ffc1ffb1ffb7ffb7ffc9ffceffe4ffe7ffe4ffeaffe7ffdbffd7ffe0ffd7ffc4ffccffcdffbbffc2ffbeffb9ffccffd4ffd4ffc6ffcaffd3ffc8ffd6ffceffd7ffdaffdfffddffdaffd6ffddffdaffd3ffe1ffd0ffc9ffcdffd1ffcaffd3ffcfffd3ffd6ffcfffcaffc9ffc7ffcaffd7ffd5ffd0ffdaffd4ffddffd6ffd8ffdcffd8ffd4ffcaffe5ffceffccff690d840d810d760d7f0d7a0d730d7a0d800d8a0d820d8c0d800d750d740d740d620d690d800d7a0d7d0d6e0d710d780d790d890d770d810d7d0d760d7d0d7b0d7a0d890d810d830d7a0d6d0d6c0d6f0d690d6d0d790d6d0d730d760d770d850d790d810d760d7d0d750d720d760d740d720d820d750d890d840d830d7d0d7b0d770d7b0d820d6f0d830d6f0d770d6e0d7b0d820d700d760d7f0d6a0d780d790d7c0d830d780d7a0d840d780d6f0d7f0d740d800d7b0d860d7f0d7a0d840d7d0d820d770d810d7c0d6400640005020000000000000900090004000500060007000a000c000b000d000e000c000d000d000c000b00090008000c000d000d0011000e000c000c000b000b000e000f00130011001100100010000e000e000e000e000c000b000c000c000b000e000d0010000e000e000d000d000c000b000c000a000b000c000c000e000b000b000c000c000d000a000b000b000a000b000c000c000c000d000e000f000b000d000b000b000e000d000c000c000b000b000c000c000c000b000b000a000a000b000b000d000f000d000d000b000b000a00fcfffbfffbfffdfff9fffbfffcfffdfffdfffdfffcfffcfffffffcfffcfffdfffffffdfffcffffff01000000fefffdfffdfffefffeffffff0000ffff0200feffffffffff000000000100fefffffffdfffdfffefffdfffefffbfffdffffff0100fefffefffdfffdfffdfffefffdfffffffefffeff0000fefffdfffffffefffdff0000fefffefffefffdfffefffefffefffefffffffffffffffffffdff00000000fefffdfffffffefffdfffefffdfffdfffffffffffdfffefffffffcfffdfffefffdfffdfffefffdfffbfff9fff9fff8fffcfff9fff8fff9fff7fff7fffafffcfffbfffdfffbfffafffcfffcfffbfff9fff8fffcfff9fff8fffbfff9fff9fffcfffcfffcfffffffbfffcfffafff8fff7fff8fff7fff6fff9fff9fffafffcfffbfffdfffdfffcfffcfffcfffcfffbfffbfffafff9fffcfffafff7fffafffbfff9fffbfffafff8fff7fff8fffafff8fff8fffafffafffafffbfffcfffcfffafffafffbfffcfffafffafff9fffafffafff9fff8fff8fff9fff9fffbfff8fffafffafffafffbfffbfff9fffafffafffafff9ff7ae96eb8"
        return stride(from: 0, to: hex.count, by: 2).map {
            let s = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[s...hex.index(after: s)], radix: 16)!
        }
    }()
}

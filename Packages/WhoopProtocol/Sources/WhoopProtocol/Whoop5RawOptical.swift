import Foundation

// WHOOP 5.0/MG historical layout-v20 ("R20", 2,140-byte) optical-buffer decoder.
//
// The record body is five repeated 422-byte blocks beginning at frame offset 26, then a 4-byte CRC32:
//
//   [ 26-byte header ][ 5 x 422-byte block ][ 4-byte CRC32 ]
//      0...25            26 448 870 1292 1714     2136...2139
//
// 26 + 5*422 = 2136. Each block is:
//
//   21-byte head | 200-byte reading slot A | 200-byte reading slot B | 1 reserved byte
//
// The 21-byte head is fully accounted for by eleven fields (1+1+2+1+2+1+4+2+1+4+2 = 21) with no
// residue. Both detector groups are 7 bytes with the identical internal shape `select:1, range:4,
// offset:2`, which is what makes the 7-byte stride visible in a raw hex dump of block 0 (both `range`
// fields there read 32).
//
// PROVENANCE. Every offset, width, endianness and value set below was measured from NOOP's own BLE
// captures: 29,203 records of this type recorded by the #454 deep-buffer recorder from a WHOOP 5.0/MG
// on fw 50.40.1.0. A validator runs 54 structural assertions over all 29,203 and accounts for
// 2140/2140 bytes with none left over. The full derivation, the negative controls and the refuted
// alternatives are published at issue #423. The field names here are exactly the neutral names used in
// that public write-up: they describe what each field is observed to DO in the capture and assert
// nothing about registers, silicon, units, or emitted wavelength. Rename freely.
//
// WHAT IS *NOT* CLAIMED. `drive*` is named only because a block with both drive fields at zero
// produces a dark measurement with no pulse (block 3, the corpus's built-in negative control); its
// units are not established. `source*` values {1,2,3,4} select something, but what each selects is
// unknown, and NOTHING in the corpus identifies an emission band. The two slots under one head belong
// to ONE shared measurement configuration and must not be labelled as two wavelengths.
//
// Baseline configuration over the 29,203-record corpus (constant unless marked *varies*):
//
//   |                     | blk0     | blk1  | blk2 | blk3 | blk4 |
//   | sampleCount         | 25       | 0     | 0    | 25   | 25   |
//   | sourceA             | 1        | 3     | 2    | 2    | 2    |
//   | driveA              | *varies* | 12750 | 6650 | 0    | 200  |   {1150,1400,1750,2200,2750,3350}
//   | sourceB             | 4        | 4     | 4    | 4    | 4    |
//   | driveB              | 2*driveA | 0     | 0    | 0    | 0    |
//   | detectorASelect     | 3        | 1     | 1    | 3    | 3    |
//   | rangeA              | 32       | 16    | 32   | 32   | 32   |
//   | offsetA             | *varies* | 0     | 1600 | 0    | 0    |   {0,800,1600,2400}
//   | detectorBSelect     | 4        | 2     | 2    | 4    | 1    |
//   | rangeB              | 32       | 16    | 32   | 32   | 32   |
//   | offsetB             | *varies* | 0     | 2400 | 0    | 0    |   {0,800,1600,2400}
//
// The `drive` family (steps of 250/350/450/550/600) and the `offset` family (steps of 800) are
// DIFFERENT fields at different offsets; they were conflated in earlier notes on this thread.

/// The eleven fields of a block's 21-byte head, in wire order.
///
/// Names match the public write-up in issue #423 one-for-one, so code and published record agree:
/// `sample_count, source_a, drive_a, source_b, drive_b, detector_a_select, range_a, offset_a,
/// detector_b_select, range_b, offset_b`.
public struct Whoop5OpticalBlockConfig: Equatable, Codable, Sendable {
    /// rel 0, u8. Readings populated in EACH slot; 0...50. `[25, 0, 0, 25, 25]` across the corpus.
    public let sampleCount: Int
    /// rel 1, u8. Emitter selector for the block's first drive field. Meaning of {1,2,3,4} unknown.
    public let sourceA: UInt8
    /// rel 2:3, u16 LE. Six values in 29,203/29,203 block-0 records: {1150,1400,1750,2200,2750,3350}.
    public let driveA: UInt16
    /// rel 4, u8. Emitter selector for the second drive field; 4 in every block of every record.
    public let sourceB: UInt8
    /// rel 5:6, u16 LE. `driveB == 2 * driveA` in 29,203/29,203 block-0 records; 0 in blocks 1...4.
    public let driveB: UInt16
    /// rel 7, u8. Detector routing for slot A. Differs from `detectorBSelect` in every block.
    public let detectorASelect: UInt8
    /// rel 8:11, u32 LE. 32, or 16 in block 1. The three high bytes are zero in every record, so the
    /// u32 width holds. Units unknown.
    public let rangeA: UInt32
    /// rel 12:13, i16 LE. Always a multiple of 800, from {0, 800, 1600, 2400}. Units unknown.
    public let offsetA: Int16
    /// rel 14, u8. Detector routing for slot B.
    public let detectorBSelect: UInt8
    /// rel 15:18, u32 LE. Mirrors `rangeA`'s domain.
    public let rangeB: UInt32
    /// rel 19:20, i16 LE. Mirrors `offsetA`'s domain.
    public let offsetB: Int16

    public init(sampleCount: Int, sourceA: UInt8, driveA: UInt16, sourceB: UInt8, driveB: UInt16,
                detectorASelect: UInt8, rangeA: UInt32, offsetA: Int16,
                detectorBSelect: UInt8, rangeB: UInt32, offsetB: Int16) {
        self.sampleCount = sampleCount
        self.sourceA = sourceA
        self.driveA = driveA
        self.sourceB = sourceB
        self.driveB = driveB
        self.detectorASelect = detectorASelect
        self.rangeA = rangeA
        self.offsetA = offsetA
        self.detectorBSelect = detectorBSelect
        self.rangeB = rangeB
        self.offsetB = offsetB
    }
}

public struct RawOpticalChannel: Equatable, Codable, Sendable {
    /// Seven raw per-channel header bytes, retained so the 21-byte head round-trips losslessly.
    /// The named reading of these bytes is on the block's `config`.
    public let metadata: [UInt8]
    /// Signed ADC containers, limited by the block's sample-count byte.
    public let samples: [Int32]

    public init(metadata: [UInt8], samples: [Int32]) {
        self.metadata = metadata
        self.samples = samples
    }
}

public struct Whoop5OpticalBlock: Equatable, Codable, Sendable {
    public let index: Int
    public let sampleCount: Int
    /// Header bytes 1...6, shared by both reading slots. Named reading on `config`.
    public let sharedMetadata: [UInt8]
    /// Always two physical slots, even when `sampleCount == 0`.
    public let channels: [RawOpticalChannel]
    /// The final byte of the 422-byte block; zero in 29,203/29,203 records of every block.
    public let reserved: UInt8
    /// The named reading of the 21 head bytes. Derived from exactly the bytes above — `rawHeader`
    /// stays the authoritative lossless view; this is the interpretation of it.
    public let config: Whoop5OpticalBlockConfig

    public init(index: Int, sampleCount: Int, sharedMetadata: [UInt8],
                channels: [RawOpticalChannel], reserved: UInt8,
                config: Whoop5OpticalBlockConfig) {
        self.index = index
        self.sampleCount = sampleCount
        self.sharedMetadata = sharedMetadata
        self.channels = channels
        self.reserved = reserved
        self.config = config
    }

    /// The complete 21-byte header reconstructed losslessly.
    public var rawHeader: [UInt8] {
        [UInt8(sampleCount)] + sharedMetadata + channels.flatMap(\.metadata)
    }

    /// Slot A readings — `readings_a` in the #423 write-up. Empty when `sampleCount == 0`.
    public var readingsA: [Int32] { channels.first?.samples ?? [] }
    /// Slot B readings — `readings_b` in the #423 write-up. Empty when `sampleCount == 0`.
    public var readingsB: [Int32] { channels.count > 1 ? channels[1].samples : [] }
}

public struct Whoop5OpticalFrame: Equatable, Codable, Sendable {
    /// u32 LE @11. Advances +1 per record; the corpus's 1 Hz clock.
    public let recordIndex: Int
    /// u32 LE @15. Equals the recorder's own `strap_ts` in 29,203/29,203 records.
    public let baseTs: Int
    public let blocks: [Whoop5OpticalBlock]
    /// u8 @9. 20 for this record type (21 is the IMU record, 18 the older frame).
    public let layoutVersion: UInt8
    /// u32 LE @2136 — the frame's CRC32 trailer, verified before any field above was read.
    public let checksum: UInt32

    public init(recordIndex: Int, baseTs: Int, blocks: [Whoop5OpticalBlock],
                layoutVersion: UInt8 = Whoop5RawOptical.layoutVersion, checksum: UInt32 = 0) {
        self.recordIndex = recordIndex
        self.baseTs = baseTs
        self.blocks = blocks
        self.layoutVersion = layoutVersion
        self.checksum = checksum
    }
}

public enum Whoop5RawOptical {
    public static let bufferLength = 2140
    public static let blockCount = 5
    public static let blockStart = 26
    public static let blockLength = 422
    public static let headerLength = 21
    public static let channelSlotLength = 200
    public static let channelCapacity = 50
    /// u8 @9 identifying this record layout.
    public static let layoutVersion: UInt8 = 20
    /// u8 @8. Shared by the v18, v20 and v21 record types; also where the CRC32 input starts.
    public static let recordClass: UInt8 = 0x2F
    /// Offset of the u32 LE CRC32 trailer. Also the end of the block tiling: 26 + 5*422.
    public static let checksumOffset = 2136

    /// Observed ADC domain: signed 20-bit. The maximum over all 730,075 block-0 slot-A samples in the
    /// corpus is EXACTLY 2^19-1, reached in 1.57% of them and never exceeded — a hardware saturation
    /// rail. Nothing ever goes below -2^19 (deepest observed: -148,044).
    public static let sampleMax: Int32 = 524_287    // 2^19 - 1
    public static let sampleMin: Int32 = -524_288   // -2^19

    /// Decode a complete layout-v20 historical record, or nil.
    ///
    /// CRC-GATED. Bad bytes never become data: the frame's envelope and BOTH checksums are verified
    /// before a single payload field is read, and a frame that fails is rejected outright rather than
    /// decoded "best effort".
    ///
    /// The checksum rule for this record is the ordinary WHOOP 5.0 envelope rule the repo already
    /// implements — there is no v20-specific CRC:
    ///
    ///   crc16Modbus(frame[0..<6])   == u16 LE @6     (29,203/29,203)
    ///   crc32(frame[8..<2136])      == u32 LE @2136  (29,203/29,203)
    ///
    /// `verifyFrame(_:family:.whoop5)` computes exactly that, because @2:3 declares 2132 and the
    /// envelope's payload span is `[8, declaredLength+8-4)` = `[8, 2136)`.
    ///
    /// CORRECTION TO THE PUBLISHED RECORD: an earlier note in issue #423 gave the CRC32 input as
    /// `[26:2136]`. That is wrong. It is `[8:2136]` — from the record-class byte, not from the start of
    /// the block tiling. Corroborated independently at a different frame size by @digitalerdude's v26
    /// result (CRC-32 over bytes 8..83 for all 1,080 of their records), so byte 8 is the frame-family
    /// rule rather than a v20 quirk. Anything built against `[26:2136]` rejects every real record.
    public static func decode(_ frame: [UInt8]) -> Whoop5OpticalFrame? {
        guard frame.count == bufferLength,
              frame[0] == 0xAA,
              verifyFrame(frame, family: .whoop5).ok,
              frame[8] == recordClass,
              frame[9] == layoutVersion else { return nil }

        var blocks: [Whoop5OpticalBlock] = []
        blocks.reserveCapacity(blockCount)

        for index in 0..<blockCount {
            let start = blockStart + index * blockLength
            let sampleCount = Int(frame[start])
            guard sampleCount <= channelCapacity else { return nil }

            let sharedMetadata = Array(frame[(start + 1)..<(start + 7)])
            var channels: [RawOpticalChannel] = []
            channels.reserveCapacity(2)
            for channelIndex in 0..<2 {
                let metadataStart = start + 7 + channelIndex * 7
                let metadata = Array(frame[metadataStart..<(metadataStart + 7)])
                let sampleStart = start + headerLength + channelIndex * channelSlotLength
                var samples: [Int32] = []
                samples.reserveCapacity(sampleCount)
                for sampleIndex in 0..<sampleCount {
                    samples.append(i32(frame, sampleStart + sampleIndex * 4))
                }
                channels.append(RawOpticalChannel(metadata: metadata, samples: samples))
            }

            blocks.append(Whoop5OpticalBlock(
                index: index,
                sampleCount: sampleCount,
                sharedMetadata: sharedMetadata,
                channels: channels,
                reserved: frame[start + blockLength - 1],
                config: Whoop5OpticalBlockConfig(
                    sampleCount: sampleCount,
                    sourceA: frame[start + 1],
                    driveA: u16(frame, start + 2),
                    sourceB: frame[start + 4],
                    driveB: u16(frame, start + 5),
                    detectorASelect: frame[start + 7],
                    rangeA: u32(frame, start + 8),
                    offsetA: i16(frame, start + 12),
                    detectorBSelect: frame[start + 14],
                    rangeB: u32(frame, start + 15),
                    offsetB: i16(frame, start + 19))))
        }

        return Whoop5OpticalFrame(
            recordIndex: Int(u32(frame, 11)),
            baseTs: Int(u32(frame, 15)),
            blocks: blocks,
            layoutVersion: frame[9],
            checksum: u32(frame, checksumOffset))
    }

    @inline(__always) private static func u16(_ frame: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(frame[offset]) | (UInt16(frame[offset + 1]) << 8)
    }

    @inline(__always) private static func i16(_ frame: [UInt8], _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(frame, offset))
    }

    @inline(__always) private static func u32(_ frame: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(frame[offset]) | (UInt32(frame[offset + 1]) << 8)
            | (UInt32(frame[offset + 2]) << 16) | (UInt32(frame[offset + 3]) << 24)
    }

    /// Readings are signed 20-bit values already SIGN-EXTENDED into a 4-byte little-endian container,
    /// so a plain signed 32-bit read is the whole decode — no masking, no manual sign extension.
    ///
    /// This is measured, not assumed: across all 4,380,450 populated containers in the corpus the
    /// fourth byte is only ever 0x00 (4,057,474) or 0xFF (322,976), never anything else, and the
    /// decoded values span [-148,044, 524,287] — inside the signed 20-bit domain with the positive rail
    /// exactly on 2^19-1.
    ///
    /// The trap: masking to 20 bits and zero-extending, or reading the container unsigned, turns the
    /// real sample `-22,101` (wire `ab a9 ff ff`) into `1,048,491` or `4,294,945,195`. Both are wrong,
    /// and neither is obviously wrong from the numbers alone.
    @inline(__always) private static func i32(_ frame: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: u32(frame, offset))
    }
}

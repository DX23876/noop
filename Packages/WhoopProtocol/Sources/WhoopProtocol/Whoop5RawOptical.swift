import Foundation

// WHOOP 5.0/MG historical layout-v20 (2,140-byte) optical-buffer decoder.
//
// The record body is five repeated 422-byte blocks beginning at frame offset 26. Each block is:
//
//   21-byte header | 200-byte channel slot 0 | 200-byte channel slot 1 | 1 reserved byte
//
// Header byte 0 is the sample count for both channel slots (0...50). The remaining 20 header bytes
// split consistently into six block-level bytes and seven bytes per channel. That split is exposed as
// raw metadata: its register meanings and the LED wavelength assigned to each block are not yet proven.
//
// RE notes (issue #423, NOT authoritative — no labelled/moving v20 capture exists): the record's config
// header carries an LED-current field @28 and per-photodiode offset DACs @38/@45. Under the split above
// those land as ONE drive current in a block's shared bytes (@27...32 for block 0) and ONE offset DAC in
// each of its two 7-byte channel descriptors (@33...39 and @40...46) — i.e. one LED per block, one detector
// per channel. That aligns with the "two readout channels share one measurement config" model, and is a
// line of evidence for treating the slots as a paired detector/readout rather than two wavelengths.
//
// In the 29,203-record corpus used to establish this layout, block counts are always [25, 0, 0, 25,
// 25]. Active channels contain 25 signed 20-bit readings in sign-extended i32 containers; slots 25...49
// are zero padding. Two channels in the same block therefore belong to one shared measurement/config,
// and must not be labelled as two different wavelengths merely because their amplitudes differ.

public struct RawOpticalChannel: Equatable, Codable, Sendable {
    /// Seven raw per-channel header bytes. Semantics are intentionally not asserted.
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
    /// Header bytes 1...6, shared by both channel slots. Semantics are intentionally not asserted.
    public let sharedMetadata: [UInt8]
    /// Always two physical slots, even when `sampleCount == 0`.
    public let channels: [RawOpticalChannel]
    /// The final byte of the 422-byte block; zero throughout the current corpus.
    public let reserved: UInt8

    public init(index: Int, sampleCount: Int, sharedMetadata: [UInt8],
                channels: [RawOpticalChannel], reserved: UInt8) {
        self.index = index
        self.sampleCount = sampleCount
        self.sharedMetadata = sharedMetadata
        self.channels = channels
        self.reserved = reserved
    }

    /// The complete 21-byte header reconstructed losslessly.
    public var rawHeader: [UInt8] {
        [UInt8(sampleCount)] + sharedMetadata + channels.flatMap(\.metadata)
    }
}

public struct Whoop5OpticalFrame: Equatable, Codable, Sendable {
    public let recordIndex: Int
    public let baseTs: Int
    public let blocks: [Whoop5OpticalBlock]

    public init(recordIndex: Int, baseTs: Int, blocks: [Whoop5OpticalBlock]) {
        self.recordIndex = recordIndex
        self.baseTs = baseTs
        self.blocks = blocks
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

    /// Decode a complete layout-v20 historical record. This performs strict structural gating; callers
    /// receiving bytes from the wire should also use the normal envelope CRC verification path.
    public static func decode(_ frame: [UInt8]) -> Whoop5OpticalFrame? {
        guard frame.count == bufferLength,
              frame[0] == 0xAA,
              frame[8] == 0x2F,
              frame[9] == 20 else { return nil }

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
                reserved: frame[start + blockLength - 1]))
        }

        return Whoop5OpticalFrame(
            recordIndex: Int(u32(frame, 11)),
            baseTs: Int(u32(frame, 15)),
            blocks: blocks)
    }

    @inline(__always) private static func u32(_ frame: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(frame[offset]) | (UInt32(frame[offset + 1]) << 8)
            | (UInt32(frame[offset + 2]) << 16) | (UInt32(frame[offset + 3]) << 24)
    }

    @inline(__always) private static func i32(_ frame: [UInt8], _ offset: Int) -> Int32 {
        Int32(bitPattern: u32(frame, offset))
    }
}

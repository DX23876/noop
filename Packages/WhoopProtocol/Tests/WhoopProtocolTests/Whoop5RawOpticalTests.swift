import XCTest
@testable import WhoopProtocol

final class Whoop5RawOpticalTests: XCTestCase {
    func testRealFramePreservesFiveBlockStructure() throws {
        let raw = Whoop5HistoricalV2021Tests.realFrameV20Bytes
        let decoded = try XCTUnwrap(Whoop5RawOptical.decode(raw))

        XCTAssertEqual(decoded.recordIndex, 11_494_060)
        XCTAssertEqual(decoded.baseTs, 1_784_054_004)
        XCTAssertEqual(decoded.blocks.map(\.sampleCount), [25, 0, 0, 25, 25])
        XCTAssertTrue(decoded.blocks.allSatisfy { $0.channels.count == 2 })
        XCTAssertTrue(decoded.blocks.allSatisfy { $0.rawHeader.count == 21 })
        XCTAssertTrue(decoded.blocks.allSatisfy { $0.reserved == 0 })

        XCTAssertEqual(decoded.blocks[0].rawHeader, [
            0x19, 0x01, 0x16, 0x0d, 0x04, 0x2c, 0x1a,
            0x03, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x04, 0x20, 0x00, 0x00, 0x00, 0x20, 0x03,
        ])
        XCTAssertEqual(decoded.blocks[4].sharedMetadata, [0x02, 0xc8, 0x00, 0x04, 0x00, 0x00])
        XCTAssertEqual(decoded.blocks[4].channels[0].metadata, [0x03, 0x20, 0, 0, 0, 0, 0])
        XCTAssertEqual(decoded.blocks[4].channels[1].metadata, [0x01, 0x20, 0, 0, 0, 0, 0])
        XCTAssertEqual(decoded.blocks[4].channels[0].samples.count, 25)
        XCTAssertEqual(decoded.blocks[4].channels[1].samples.count, 25)
        XCTAssertEqual(decoded.blocks[4].channels[1].samples.last, 11_318)
    }

    func testInterpreterExposesHeadersWithoutWavelengthLabels() {
        let parsed = parseFrame(Whoop5HistoricalV2021Tests.realFrameV20Bytes, family: .whoop5).parsed
        XCTAssertEqual(parsed["sensor_block_count"]?.intValue, 5)
        XCTAssertEqual(parsed["block_b0_sample_count"]?.intValue, 25)
        XCTAssertEqual(parsed["block_b1_sample_count"]?.intValue, 0)
        XCTAssertEqual(parsed["block_b4_header"]?.intArrayValue?.count, 21)
        XCTAssertEqual(parsed["channel_b4_0"]?.intArrayValue?.count, 25)
        XCTAssertEqual(parsed["channel_b4_1"]?.intArrayValue?.count, 25)
        XCTAssertNil(parsed["red"])
        XCTAssertNil(parsed["ir"])
    }

    func testStrictShapeAndCountGates() {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA
        frame[8] = 0x2F
        frame[9] = 20
        XCTAssertNotNil(Whoop5RawOptical.decode(frame))

        frame[Whoop5RawOptical.blockStart] = UInt8(Whoop5RawOptical.channelCapacity + 1)
        XCTAssertNil(Whoop5RawOptical.decode(frame))
        frame[Whoop5RawOptical.blockStart] = 0
        frame.append(0)
        XCTAssertNil(Whoop5RawOptical.decode(frame))
    }
}

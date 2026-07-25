import XCTest
@testable import OuraProtocol

/// #772: generation detection must NOT come from stray digits in the advertised name (a factory-reset ring
/// advertises its serial there), and the authoritative generation comes from the GetProductInfo hardware id.
final class RingGenProductInfoTests: XCTestCase {

    // MARK: recognise(advertisedName:) — explicit gen token only, never a serial digit

    func testRecogniseExplicitGenToken() {
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Ring Gen3"), .gen3)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Ring 4"), .gen4)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "OURA RING GEN5"), .gen5)
        XCTAssertEqual(OuraRingGen.recognise(advertisedName: "Oura Horizon"), .gen3)
    }

    func testRecogniseSerialNameYieldsNil() {
        // The exact on-device Gen3 serial name whose "5" was mis-read as gen5 (#772).
        XCTAssertNil(OuraRingGen.recognise(advertisedName: "Oura 2H3B2405003655"))
        // A bare serial with no gen/ring token at all.
        XCTAssertNil(OuraRingGen.recognise(advertisedName: "Oura 9F5A"))
    }

    func testRecogniseNonOuraNameYieldsNil() {
        XCTAssertNil(OuraRingGen.recognise(advertisedName: "WHOOP 5.0"))
        XCTAssertNil(OuraRingGen.recognise(advertisedName: nil))
    }

    // MARK: from(hardwareId:) — authoritative, "_NN" suffix

    func testFromHardwareIdKnownGen3() {
        XCTAssertEqual(OuraRingGen.from(hardwareId: "BLB_03"), .gen3)   // validated on-device
    }

    func testFromHardwareIdSuffixMapping() {
        XCTAssertEqual(OuraRingGen.from(hardwareId: "BLB_04"), .gen4)
        XCTAssertEqual(OuraRingGen.from(hardwareId: "BLB_05"), .gen5)
    }

    func testFromHardwareIdUnrecognisedYieldsNil() {
        XCTAssertNil(OuraRingGen.from(hardwareId: "2H3B2405003655"))   // a serial, no "_NN" gen marker
        XCTAssertNil(OuraRingGen.from(hardwareId: "BLB_09"))           // unknown generation, never a guess
        XCTAssertNil(OuraRingGen.from(hardwareId: "BLB_"))
        XCTAssertNil(OuraRingGen.from(hardwareId: ""))
    }

    // MARK: productInfoString — status byte + NUL-terminated ASCII

    func testProductInfoStringDecodesSerial() {
        // Exact captured serial reply body (op 0x19): 00 + "2H3B2405003655" + 00 00.
        let body: [UInt8] = [0x00, 0x32, 0x48, 0x33, 0x42, 0x32, 0x34, 0x30, 0x35, 0x30, 0x30, 0x33, 0x36, 0x35, 0x35, 0x00, 0x00]
        XCTAssertEqual(OuraDecoders.productInfoString(body), "2H3B2405003655")
    }

    func testProductInfoStringDecodesHardware() {
        // Exact captured hardware reply body: 00 + "BLB_03" + NUL pad.
        let body: [UInt8] = [0x00, 0x42, 0x4c, 0x42, 0x5f, 0x30, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertEqual(OuraDecoders.productInfoString(body), "BLB_03")
    }

    func testProductInfoStringEmptyOrStatusOnly() {
        XCTAssertNil(OuraDecoders.productInfoString([]))
        XCTAssertNil(OuraDecoders.productInfoString([0x00]))        // status byte only
        XCTAssertNil(OuraDecoders.productInfoString([0x00, 0x00]))  // no printable content
    }

    /// End-to-end: the captured hardware reply decodes to a gen; the serial reply does not (so the live
    /// source can tell them apart even though both arrive under op 0x19).
    func testHardwareReplyResolvesGenSerialDoesNot() {
        let hw: [UInt8] = [0x00, 0x42, 0x4c, 0x42, 0x5f, 0x30, 0x33, 0x00]
        let serial: [UInt8] = [0x00, 0x32, 0x48, 0x33, 0x42, 0x32, 0x34, 0x30, 0x35, 0x30, 0x30, 0x33, 0x36, 0x35, 0x35]
        XCTAssertEqual(OuraDecoders.productInfoString(hw).flatMap(OuraRingGen.from(hardwareId:)), .gen3)
        XCTAssertNil(OuraDecoders.productInfoString(serial).flatMap(OuraRingGen.from(hardwareId:)))
    }
}

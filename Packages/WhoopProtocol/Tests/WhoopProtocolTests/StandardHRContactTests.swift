import XCTest
@testable import WhoopProtocol

/// The BLE Heart Rate Measurement flags decode must live on the protocol type so Swift and Kotlin
/// stay aligned: bit 2 = supported, bit 1 = detected, unsupported whenever bit 2 is clear.
final class StandardHRContactTests: XCTestCase {
    func testFromMeasurementFlagsCoversAllCombinations() {
        let cases: [(flags: UInt8, expected: StandardHRContact)] = [
            (0x00, .unsupported),
            (0x02, .unsupported),
            (0x04, .supportedNotDetected),
            (0x06, .supportedDetected),
        ]
        for test in cases {
            XCTAssertEqual(
                StandardHRContact.fromMeasurementFlags(test.flags),
                test.expected,
                "flags 0x\(String(test.flags, radix: 16))"
            )
        }
    }
}

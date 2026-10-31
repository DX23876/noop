import XCTest
@testable import WhoopProtocol

/// SET_CLOCK (cmd 10) 8-byte body with real subseconds.
///
/// The strap counts sub-seconds in 1/32768 s, the same unit as the EVENT header u16 at frame 16 and the
/// alarm body. Sending 0 there floors the phone time to the whole second, so the strap starts up to a
/// second behind before any radio latency; a 2026-10-31 MG capture (fw 50.41.1.0) sat 1.3 to 2.1 s behind
/// after each set while its RTC itself drifted less than 3 ppm.
final class SetClockPayloadTests: XCTestCase {

    func testHalfSecondEncodesAsHalfOf32768() {
        // 1780000000 = 0x6A18A500; 500 ms → 16384 = 0x4000 in the low u16, the high u16 stays 0.
        XCTAssertEqual(SetClockPayload.withSubseconds(epochMs: 1_780_000_000_500),
                       [0x00, 0xA5, 0x18, 0x6A, 0x00, 0x40, 0x00, 0x00])
    }

    func testLastMillisecondStaysBelowOneSecond() {
        // 999 ms → 32735 (0x7FDF), never 32768: the fraction must not spill into a whole second.
        XCTAssertEqual(SetClockPayload.withSubseconds(epochMs: 1_780_000_000_999),
                       [0x00, 0xA5, 0x18, 0x6A, 0xDF, 0x7F, 0x00, 0x00])
    }

    func testWholeSecondMatchesTheOldZeroSubsecondForm() {
        XCTAssertEqual(SetClockPayload.withSubseconds(epochMs: 1_780_000_000_000),
                       [0x00, 0xA5, 0x18, 0x6A, 0x00, 0x00, 0x00, 0x00])
    }

    func testNegativeInstantClampsInsteadOfTrapping() {
        XCTAssertEqual(SetClockPayload.withSubseconds(epochMs: -1), [0, 0, 0, 0, 0, 0, 0, 0])
    }
}

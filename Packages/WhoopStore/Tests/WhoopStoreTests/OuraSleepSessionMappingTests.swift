import XCTest
import OuraProtocol
@testable import WhoopStore

/// The ring-PROVIDED hypnogram → `CachedSleepSession` reshaper. Value-for-value twin of the Kotlin
/// `OuraSleepSessionMappingTest`; the `stagesJSON` byte string is asserted verbatim so both platforms
/// stay on the cross-platform stored-value contract.
final class OuraSleepSessionMappingTests: XCTestCase {

    // A tiny anchored sequence: deep,deep,light,rem,awake at 30 s epochs from t0.
    private func codes(from t0: Int) -> [(ts: Int, stage: OuraSleepStage)] {
        [(t0, .deep), (t0 + 30, .deep), (t0 + 60, .light), (t0 + 90, .rem), (t0 + 120, .awake)]
    }

    func testEmptySequenceYieldsNoSession() {
        XCTAssertNil(OuraSleepSessionMapping.session(fromCodes: []))
    }

    func testBoundsAreFirstTsToLastTsPlusEpoch() {
        let t0 = 1_700_000_000
        let s = OuraSleepSessionMapping.session(fromCodes: codes(from: t0))
        XCTAssertEqual(s?.startTs, t0)
        XCTAssertEqual(s?.endTs, t0 + 150)   // last code ts (t0+120) + one 30 s epoch
    }

    func testAdjacentEqualStagesMergeIntoOneSegment() {
        let t0 = 1_700_000_000
        let s = OuraSleepSessionMapping.session(fromCodes: codes(from: t0))
        // deep merges the first two codes into [t0, t0+60]; the rest are single 30 s segments.
        let expected = "[" +
            "{\"start\":\(t0),\"end\":\(t0 + 60),\"stage\":\"deep\"}," +
            "{\"start\":\(t0 + 60),\"end\":\(t0 + 90),\"stage\":\"light\"}," +
            "{\"start\":\(t0 + 90),\"end\":\(t0 + 120),\"stage\":\"rem\"}," +
            "{\"start\":\(t0 + 120),\"end\":\(t0 + 150),\"stage\":\"wake\"}" +
        "]"
        XCTAssertEqual(s?.stagesJSON, expected)
    }

    func testEfficiencyIsAsleepOverInBed() {
        let t0 = 1_700_000_000
        let s = OuraSleepSessionMapping.session(fromCodes: codes(from: t0))
        // 4 asleep epochs (deep,deep,light,rem) + 1 awake → 4/5.
        XCTAssertEqual(s?.efficiency ?? 0, 0.8, accuracy: 1e-9)
    }

    func testAllAwakeIsZeroEfficiencyNotNil() {
        let t0 = 1_700_000_000
        let s = OuraSleepSessionMapping.session(fromCodes: [(t0, .awake), (t0 + 30, .awake)])
        XCTAssertEqual(s?.efficiency ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(s?.stagesJSON, "[{\"start\":\(t0),\"end\":\(t0 + 60),\"stage\":\"wake\"}]")
    }

    func testStageTokensMatchOnDeviceStagerConvention() {
        XCTAssertEqual(OuraSleepSessionMapping.token(.deep), "deep")
        XCTAssertEqual(OuraSleepSessionMapping.token(.light), "light")
        XCTAssertEqual(OuraSleepSessionMapping.token(.rem), "rem")
        XCTAssertEqual(OuraSleepSessionMapping.token(.awake), "wake")   // awake persists as "wake"
    }
}
